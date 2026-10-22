#!/bin/bash
# Evening: drop GPU VMs, pause Machine API, stop remaining GCP VMs.
# RHPDS GCP open environments do not autostop.
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

RESET=0
FORCE=0
usage() {
  cat <<EOF
Usage: $0 [--reset] [--force]

Stops workshop InferenceServices, scales GPU pools to 0, pauses Machine API,
then stops remaining GCP VMs. Model Registry entries stay.

  --reset  also run reset-demo.sh (delete leftover PVCs in Data Science Projects)
  --force  issue deletes but do not wait for InferenceServices to go away

Do not stop GPU VMs out-of-band while a GPU MachineSet still has replicas > 0.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --reset) RESET=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

load_gcp_credentials
gcp_activate

if [ "${RESET}" -eq 1 ]; then
  bash "${SCRIPT_DIR}/reset-demo.sh"
fi

echo "=== Overnight stop ==="
echo "1. Stopping InferenceServices so GPU nodes can drain..."
if [ "${FORCE}" -eq 1 ]; then
  stop_inference_services 0
else
  stop_inference_services 180
fi
relax_ogx_missing_token_refs
echo ""

save_pool_last() {
  local pool="$1"
  local key="$2"
  local info replicas
  info="$(find_gpu_machineset "${pool}")"
  replicas="${info##*|}"
  if [ -n "${replicas}" ] && [ "${replicas}" -gt 0 ]; then
    set_cred "${key}" "${replicas}"
    echo "  Saved ${key}=${replicas}"
  else
    echo "  ${key} unchanged ($(get_cred "${key}" || echo unset))"
  fi
}

echo "2. Remember GPU replica counts, then scale both pools to 0..."
save_pool_last 4l4 GPU_4L4_LAST_REPLICAS
save_pool_last 2l4 GPU_2L4_LAST_REPLICAS
bash "${SCRIPT_DIR}/scale-gpu.sh" --4l4 0 --2l4 0 --no-persist
wait_gpu_machines_gone 900 || true
echo ""

echo "3. Pause Machine API (stopped VMs are replaced unless this is 0)..."
MAC_REPLICAS="$(oc get deploy machine-api-controllers -n openshift-machine-api \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)"
MAC_REPLICAS="${MAC_REPLICAS:-1}"
set_cred MACHINE_API_LAST_REPLICAS "${MAC_REPLICAS}"
oc scale deploy/machine-api-controllers -n openshift-machine-api --replicas=0
for i in $(seq 1 36); do
  READY="$(oc get deploy machine-api-controllers -n openshift-machine-api \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  READY="${READY:-0}"
  if [ "${READY}" = "0" ]; then
    break
  fi
  sleep 5
done
echo "  [OK] machine-api-controllers replicas=0 (was ${MAC_REPLICAS})"
echo ""

echo "4. Stop remaining cluster VMs (masters + general workers)..."
INFRA="$(cluster_infra_id)"
if [ -z "${INFRA}" ]; then
  echo "  ERROR: could not determine installer infra ID." >&2
  exit 1
fi
echo "  infraID: ${INFRA}"
STOPPED=0
SKIPPED=0
while IFS=$'\t' read -r name zone status mtype; do
  [ -n "${name}" ] || continue
  lname="${name,,}"
  if [[ "${lname}" == *bootstrap* ]] || [[ "${lname}" == *gpu* ]]; then
    echo "  skip ${name} (${status})"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  if [ "${status}" = "TERMINATED" ]; then
    echo "  already stopped ${name}"
    continue
  fi
  echo "  stopping ${name} in ${zone} (${mtype})..."
  gcloud compute instances stop "${name}" --zone="${zone}" --project="${GCP_PROJECT}" --quiet
  STOPPED=$((STOPPED + 1))
done < <(gcp_list_cluster_instances "${INFRA}")
echo "  stopped=${STOPPED} skipped=${SKIPPED}"
echo ""

LAST4="$(get_cred GPU_4L4_LAST_REPLICAS || echo 0)"
LAST2="$(get_cred GPU_2L4_LAST_REPLICAS || echo 0)"
echo "=== Cluster VMs stopped ==="
echo "  GPU LAST_REPLICAS saved: 4l4=${LAST4}  2l4=${LAST2}"
echo "  Morning: ./setup/overnight-start.sh"
echo "           ./setup/overnight-start.sh --4l4 1"
echo "           ./setup/overnight-start.sh --students"
