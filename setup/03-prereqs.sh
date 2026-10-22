#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NODE_WAIT_TIMEOUT=900
ERRORS=0

echo "=== Checking prerequisites ==="
echo ""

check_command() {
  if command -v "$1" &>/dev/null; then
    echo "  [OK] $1 found: $(command -v "$1")"
  else
    echo "  [FAIL] $1 not found. $2"
    ERRORS=$((ERRORS + 1))
  fi
}

echo "1. Checking required CLI tools..."
check_command "oc" "Run ./setup/00-install-tools.sh (or install from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/)"
check_command "python3" "Install Python 3"
check_command "openssl" "Install openssl"
check_command "curl" "Install curl"
echo ""

echo "2. Checking OpenShift cluster access..."
echo "  [OK] Logged in as: $(oc whoami)"
echo "  [OK] Cluster: $(oc whoami --show-server)"
echo ""

echo "3. Checking cluster-admin permissions..."
if oc auth can-i create namespace &>/dev/null; then
  echo "  [OK] User has cluster-admin permissions"
else
  echo "  [FAIL] User does not have cluster-admin permissions"
  ERRORS=$((ERRORS + 1))
fi
echo ""

echo "4. Checking OpenShift version..."
OCP_VER=$(oc version -o json 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('openshiftVersion','unknown'))" \
  2>/dev/null || echo "unknown")
echo "  OpenShift version: ${OCP_VER}"
echo ""

echo "5. Checking storage classes..."
if oc get storageclass --no-headers 2>/dev/null | grep -q .; then
  oc get storageclass --no-headers 2>/dev/null | while read -r line; do
    echo "    ${line}"
  done
  echo "  [OK] StorageClass present"
else
  echo "  [FAIL] No StorageClass found"
  ERRORS=$((ERRORS + 1))
fi
echo ""

if [ "${ERRORS}" -gt 0 ]; then
  echo "=== FAILED: ${ERRORS} prerequisite(s) not met ==="
  exit 1
fi

echo "6. Checking cluster topology..."
CONTROL_NODES=$(oc get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l)
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l)
GPU_WORKER_NODES_ROLE=$(oc get nodes -l node-role.kubernetes.io/worker-gpu --no-headers 2>/dev/null | wc -l) || GPU_WORKER_NODES_ROLE=0

echo "   Node inventory:"
echo "     Control plane nodes:    ${CONTROL_NODES}"
echo "     Worker nodes (total):   ${WORKER_NODES}"
echo "     Worker nodes (GPU):     ${GPU_WORKER_NODES_ROLE}"
echo ""

apply_gpu_pool() {
  local pool="$1"
  local replicas="$2"
  local mtype="$3"
  local l4count="$4"
  local create_az="$5"
  local json name
  json=$(oc get machinesets -n openshift-machine-api -o json \
    | python3 "${SCRIPT_DIR}/gpu_machineset.py" build \
        --az "${create_az}" \
        --replicas "${replicas}" \
        --machine-type "${mtype}" \
        --volume-size "${GPU_VOLUME_SIZE}" \
        --gpu-annotation "${l4count}" \
        --pool "${pool}" \
        --l4-count "${l4count}") || {
    echo "  [FAIL] Could not generate ${pool} GPU MachineSet for zone ${create_az}."
    echo "         If ${mtype} is out of capacity: ./setup/switch-gpu-az.sh --list"
    return 1
  }
  name=$(echo "${json}" | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['name'])")
  echo "  Applying GPU MachineSet: ${name}"
  echo "    Pool:          ${pool}"
  echo "    Machine type:  ${mtype}"
  echo "    Volume size:   ${GPU_VOLUME_SIZE} GB pd-ssd"
  echo "    GPUs/node:     ${l4count}"
  echo "    Replicas:      ${replicas}"
  echo "${json}" | oc apply -f -
}

echo "   6a. Ensuring GPU MachineSets (4-L4 replicas ${GPU_4L4_REPLICAS}, 2-L4 replicas ${GPU_2L4_REPLICAS})..."

PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || echo "unknown")
if [ "${PLATFORM}" != "GCP" ] && [ "${PLATFORM}" != "GoogleCloudPlatform" ]; then
  echo "  [FAIL] Platform is ${PLATFORM} (need GCP)."
  exit 1
fi

if [ -z "${GPU_AZ:-}" ] && [ -f "${SCRIPT_DIR}/../cluster/.gpu-az" ]; then
  GPU_AZ="$(tr -d '[:space:]' < "${SCRIPT_DIR}/../cluster/.gpu-az")"
  echo "  Using GPU_AZ from cluster/.gpu-az: ${GPU_AZ}"
fi
CREATE_AZ="${GPU_AZ:-}"
WORKER_AZS="$(oc get machinesets -n openshift-machine-api -o json \
  | python3 "${SCRIPT_DIR}/gpu_machineset.py" list-azs 2>/dev/null || true)"
if [ -n "${CREATE_AZ}" ] && ! echo "${WORKER_AZS}" | grep -qx "${CREATE_AZ}"; then
  echo "  [WARN] ${CREATE_AZ} has no worker MachineSet; picking a worker zone instead."
  CREATE_AZ=""
fi
if [ -z "${CREATE_AZ}" ]; then
  CREATE_AZ="$(echo "${WORKER_AZS}" | awk 'NF{print; exit}')"
fi
if [ -z "${CREATE_AZ}" ]; then
  echo "  [FAIL] Could not determine a zone from worker MachineSets."
  exit 1
fi

EXISTING_4="$(find_gpu_machineset 4l4 || true)"
EXISTING_2="$(find_gpu_machineset 2l4 || true)"

if [ -n "${EXISTING_4}" ]; then
  echo "  Found 4-L4 MachineSet: ${EXISTING_4%%|*} (replicas=${EXISTING_4##*|})"
  if [ "${EXISTING_4##*|}" -lt "${GPU_4L4_REPLICAS}" ]; then
    oc scale machineset "${EXISTING_4%%|*}" -n openshift-machine-api --replicas="${GPU_4L4_REPLICAS}"
  fi
else
  apply_gpu_pool 4l4 "${GPU_4L4_REPLICAS}" "${GPU_4L4_TYPE}" "${GPU_4L4_COUNT}" "${CREATE_AZ}"
fi

if [ -n "${EXISTING_2}" ]; then
  echo "  Found 2-L4 MachineSet: ${EXISTING_2%%|*} (replicas=${EXISTING_2##*|})"
else
  apply_gpu_pool 2l4 "${GPU_2L4_REPLICAS}" "${GPU_2L4_TYPE}" "${GPU_2L4_COUNT}" "${CREATE_AZ}"
fi

if [ "${GPU_4L4_REPLICAS}" -gt 0 ]; then
  wait_for_gpu_pool "${GPU_4L4_REPLICAS}" "${NODE_WAIT_TIMEOUT}" || true
  set_cred GPU_4L4_LAST_REPLICAS "${GPU_4L4_REPLICAS}"
fi
set_cred GPU_2L4_LAST_REPLICAS "${GPU_2L4_REPLICAS}"
echo ""

GENERAL_WORKERS=$((WORKER_NODES - GPU_WORKER_NODES_ROLE))
echo "   6b. General workers (operators/dashboard; no autoscale in this workshop)..."
if [ "${GENERAL_WORKERS}" -ge 2 ]; then
  echo "  [OK] ${GENERAL_WORKERS} general worker node(s)"
else
  echo "  [WARN] Only ${GENERAL_WORKERS} general worker(s). Two or more are recommended."
fi
echo ""

echo "=== Prerequisites complete ==="
echo "  Rehearsal: 1 × ${GPU_4L4_TYPE} (${GPU_4L4_COUNT} L4). Student 2-L4 nodes stay at replicas 0"
echo "  until ./setup/scale-students.sh."
