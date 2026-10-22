#!/bin/bash
# Independent GPU pools: --4l4 (presenter g2-standard-48) and --2l4 (student g2-standard-24).
# This is NOT multi-node model sharding.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=lib-gcp.sh
source "${SCRIPT_DIR}/lib-gcp.sh"

R4=""
R2=""
PERSIST=1
usage() {
  cat <<EOF
Usage: $0 --4l4 N [--2l4 N]
       $0 --2l4 N [--4l4 N]

  --4l4         presenter node (g2-standard-48). Only 0 or ${GPU_4L4_MAX}.
  --2l4         student nodes (g2-standard-24). 0–${GPU_2L4_MAX}.
  --no-persist  do not overwrite GPU_*_LAST_REPLICAS (overnight-stop)

Examples:
  $0 --4l4 1
  $0 --4l4 0
  $0 --2l4 3
  $0 --2l4 0
  $0 --4l4 0 --2l4 0
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --4l4)
      R4="${2:-}"
      shift 2
      ;;
    --2l4)
      R2="${2:-}"
      shift 2
      ;;
    --no-persist)
      PERSIST=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "${R4}" ] && [ -z "${R2}" ]; then
  usage >&2
  exit 1
fi

current_replicas() {
  local pool="$1"
  local info
  info="$(find_gpu_machineset "${pool}")"
  if [ -z "${info}" ]; then
    echo 0
    return 0
  fi
  echo "${info##*|}"
}

scale_pool() {
  local pool="$1"
  local replicas="$2"
  local max="$3"
  local per_node="$4"
  if ! [[ "${replicas}" =~ ^[0-9]+$ ]]; then
    echo "${pool} replicas must be an integer" >&2
    return 1
  fi
  if [ "${replicas}" -gt "${max}" ]; then
    echo "Refusing ${pool} replicas=${replicas} (max ${max})." >&2
    return 1
  fi
  local info name current
  info="$(find_gpu_machineset "${pool}")"
  if [ -z "${info}" ]; then
    echo "No ${pool} GPU MachineSet found. Run ./setup/03-prereqs.sh first." >&2
    return 1
  fi
  name="${info%%|*}"
  current="${info##*|}"
  echo "${pool} MachineSet: ${name}"
  echo "  current=${current}  target=${replicas}  (${per_node} L4 each)"
  oc scale machineset "${name}" -n openshift-machine-api --replicas="${replicas}"
  if [ "${replicas}" -eq 0 ]; then
    echo "  Scaled ${pool} to 0. GPU VMs will terminate. MachineSet kept."
    return 0
  fi
  if ! wait_for_ready_nodes "workshop.opendatahub.io/l4-count=${per_node}" "${replicas}" "${pool}" 900; then
    report_gpu_machines || true
    echo "  If the event is ZONE_RESOURCE_POOL_EXHAUSTED: ./setup/switch-gpu-az.sh --list"
    return 1
  fi
}

need_quota=0
if [ -n "${R4}" ]; then
  cur4="$(current_replicas 4l4)"
  if [ "${R4}" -gt "${cur4}" ]; then
    need_quota=$((need_quota + (R4 - cur4) * GPU_4L4_COUNT))
  fi
fi
if [ -n "${R2}" ]; then
  cur2="$(current_replicas 2l4)"
  if [ "${R2}" -gt "${cur2}" ]; then
    need_quota=$((need_quota + (R2 - cur2) * GPU_2L4_COUNT))
  fi
fi
if [ "${need_quota}" -gt 0 ]; then
  load_gcp_credentials
  gcp_activate
  echo "Preflight L4 quota for +${need_quota} GPUs..."
  preflight_l4_quota "${need_quota}" || exit 1
fi

[ -n "${R4}" ] && scale_pool 4l4 "${R4}" "${GPU_4L4_MAX}" "${GPU_4L4_COUNT}"
[ -n "${R2}" ] && scale_pool 2l4 "${R2}" "${GPU_2L4_MAX}" "${GPU_2L4_COUNT}"

if [ "${PERSIST}" -eq 1 ]; then
  [ -n "${R4}" ] && set_cred GPU_4L4_LAST_REPLICAS "${R4}"
  [ -n "${R2}" ] && set_cred GPU_2L4_LAST_REPLICAS "${R2}"
fi

live4="$(find_gpu_machineset 4l4)"; live4="${live4##*|}"
live2="$(find_gpu_machineset 2l4)"; live2="${live2##*|}"
if [ "${live4:-0}" = "0" ] && [ "${live2:-0}" = "0" ]; then
  force_delete_failed_predictors
fi
sync_kueue_gpu_quotas "${live4:-0}" "${live2:-0}"

if oc get ds prepull-gpu -n workshop-prepull &>/dev/null; then
  echo "Pre-pull DaemonSet will land on new GPU nodes. Wait until it is Ready before heavy deploys."
fi
echo "Done."
