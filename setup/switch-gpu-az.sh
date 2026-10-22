#!/bin/bash
# Move GPU MachineSets (replicas > 0) to another GCP zone on STOCKOUT.
# Subnet / networkInterfaces are copied from a worker MachineSet already in the target zone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TARGET_AZ=""
TRY_AZS=""
KEEP_OLD=0
LIST_ONLY=0

usage() {
  cat <<EOF
Usage: $0 --az <zone> [--keep-old]
       $0 --try <zone>[,<zone>...]
       $0 --list

Move whichever GPU MachineSets currently have replicas > 0 when the current
zone is out of G2 capacity (ZONE_RESOURCE_POOL_EXHAUSTED).

  --az         Target zone (must already have a worker MachineSet)
  --try        Try zones in order
  --keep-old   Leave the old GPU MachineSet at replicas=0
  --list       Show GPU MachineSets and worker zones

Examples:
  $0 --list
  $0 --az asia-southeast1-c
  $0 --try asia-southeast1-a,asia-southeast1-b,asia-southeast1-c
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --az) TARGET_AZ="${2:-}"; shift 2 ;;
    --try) TRY_AZS="${2:-}"; shift 2 ;;
    --keep-old) KEEP_OLD=1; shift ;;
    --list) LIST_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

MS_JSON="$(oc get machinesets -n openshift-machine-api -o json)"

if [ "${LIST_ONLY}" -eq 1 ]; then
  echo "${MS_JSON}" | python3 "${SCRIPT_DIR}/gpu_machineset.py" report
  exit 0
fi

AZ_LIST=()
if [ -n "${TARGET_AZ}" ]; then
  AZ_LIST+=("${TARGET_AZ}")
fi
if [ -n "${TRY_AZS}" ]; then
  IFS=',' read -ra _TRY_PARTS <<< "${TRY_AZS}"
  for _az in "${_TRY_PARTS[@]}"; do
    _az="${_az// /}"
    [ -n "${_az}" ] || continue
    AZ_LIST+=("${_az}")
  done
fi

if [ "${#AZ_LIST[@]}" -eq 0 ]; then
  echo "Target zone is required." >&2
  echo "${MS_JSON}" | python3 "${SCRIPT_DIR}/gpu_machineset.py" report >&2
  usage >&2
  exit 1
fi

PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || echo "unknown")
if [ "${PLATFORM}" != "GCP" ] && [ "${PLATFORM}" != "GoogleCloudPlatform" ]; then
  echo "This script retargets GCP IPI MachineSets. Platform is ${PLATFORM}." >&2
  exit 1
fi

wait_machineset_empty() {
  local name="$1"
  local timeout="${2:-300}"
  local elapsed=0
  while [ "${elapsed}" -lt "${timeout}" ]; do
    local n
    n="$(oc get machines -n openshift-machine-api \
      -l "machine.openshift.io/cluster-api-machineset=${name}" \
      --no-headers 2>/dev/null | wc -l)"
    n="${n// /}"
    if [ "${n}" = "0" ]; then
      echo "  [OK] no machines left on ${name}"
      return 0
    fi
    echo "  ... ${n} machine(s) still on ${name} (${elapsed}s)"
    sleep 10
    elapsed=$((elapsed + 10))
  done
  echo "  [WARN] ${name} still has machines after ${timeout}s"
  return 1
}

active_pools() {
  local pool info replicas
  for pool in 4l4 2l4; do
    info="$(find_gpu_machineset "${pool}" || true)"
    [ -n "${info}" ] || continue
    replicas="${info##*|}"
    if [ "${replicas}" -gt 0 ]; then
      echo "${pool}|${info}"
    fi
  done
}

switch_pool_to_az() {
  local pool="$1"
  local target_az="$2"
  local replicas="$3"
  local mtype l4count
  if [ "${pool}" = "4l4" ]; then
    mtype="${GPU_4L4_TYPE}"
    l4count="${GPU_4L4_COUNT}"
  else
    mtype="${GPU_2L4_TYPE}"
    l4count="${GPU_2L4_COUNT}"
  fi
  local ms_json new_json new_name others old
  ms_json="$(oc get machinesets -n openshift-machine-api -o json)"
  new_json="$(echo "${ms_json}" | python3 "${SCRIPT_DIR}/gpu_machineset.py" build \
    --az "${target_az}" \
    --replicas "${replicas}" \
    --machine-type "${mtype}" \
    --volume-size "${GPU_VOLUME_SIZE}" \
    --gpu-annotation "${l4count}" \
    --pool "${pool}" \
    --l4-count "${l4count}")" || return 1
  new_name="$(echo "${new_json}" | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['name'])")"

  others="$(echo "${ms_json}" | python3 "${SCRIPT_DIR}/gpu_machineset.py" others --keep "${new_name}" --pool "${pool}")"
  if [ -n "${others}" ]; then
    while IFS= read -r old; do
      [ -n "${old}" ] || continue
      echo "  Scaling ${old} to 0..."
      oc scale machineset "${old}" -n openshift-machine-api --replicas=0
      wait_machineset_empty "${old}" 300 || {
        oc delete machines -n openshift-machine-api \
          -l "machine.openshift.io/cluster-api-machineset=${old}" --wait=false || true
        wait_machineset_empty "${old}" 180 || return 2
      }
      if [ "${KEEP_OLD}" -eq 0 ]; then
        oc delete machineset "${old}" -n openshift-machine-api --wait=false
      fi
    done <<< "${others}"
  fi
  echo "  Applying ${new_name} in ${target_az} replicas=${replicas}..."
  echo "${new_json}" | oc apply -f -
  oc scale machineset "${new_name}" -n openshift-machine-api --replicas="${replicas}"
  wait_for_ready_nodes "workshop.opendatahub.io/l4-count=${l4count}" "${replicas}" "${pool}" 1200 || return 1
}

POOLS="$(active_pools)"
if [ -z "${POOLS}" ]; then
  echo "No GPU MachineSet with replicas > 0. Nothing to move."
  echo "${MS_JSON}" | python3 "${SCRIPT_DIR}/gpu_machineset.py" report
  exit 0
fi

echo "=== Switch GPU MachineSet zone ==="
echo "  Active pools:"
echo "${POOLS}" | sed 's/^/    /'
echo "  Try zones: ${AZ_LIST[*]}"
echo ""

LAST_RC=1
for TARGET_AZ in "${AZ_LIST[@]}"; do
  echo "---- trying ${TARGET_AZ} ----"
  LAST_RC=0
  while IFS='|' read -r pool name replicas az; do
    [ -n "${pool}" ] || continue
    echo "Moving ${pool} (${name} replicas=${replicas}) -> ${TARGET_AZ}"
    switch_pool_to_az "${pool}" "${TARGET_AZ}" "${replicas}" || LAST_RC=$?
    if [ "${LAST_RC}" -ne 0 ]; then
      break
    fi
  done <<< "$(echo "${POOLS}" | awk -F'|' '{print $1"|"$2"|"$3"|"$4}')"
  if [ "${LAST_RC}" -eq 0 ]; then
    set_cred GPU_AZ "${TARGET_AZ}"
    echo "=== GPU MachineSets are in ${TARGET_AZ} ==="
    oc get machinesets -n openshift-machine-api -o json \
      | python3 "${SCRIPT_DIR}/gpu_machineset.py" report
    exit 0
  fi
  echo "Will try the next zone if one remains."
done

echo "GPU node did not become Ready in: ${AZ_LIST[*]}"
echo "  $0 --list"
echo "  $0 --try asia-southeast1-a,asia-southeast1-b,asia-southeast1-c"
exit 1
