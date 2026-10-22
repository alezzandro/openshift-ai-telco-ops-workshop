#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests/operators"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Configuring GPU support ==="
echo ""

echo "1. Enabling user-workload monitoring (DCGM scrape)..."
if oc get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null; then
  oc get configmap cluster-monitoring-config -n openshift-monitoring -o json | python3 -c '
import json, re, sys
cm = json.load(sys.stdin)
data = cm.setdefault("data", {})
cfg = data.get("config.yaml") or ""
if re.search(r"enableUserWorkload:\s*\S+", cfg):
    cfg = re.sub(r"enableUserWorkload:\s*\S+", "enableUserWorkload: true", cfg, count=1)
elif cfg.strip():
    cfg = cfg.rstrip() + "\nenableUserWorkload: true\n"
else:
    cfg = "enableUserWorkload: true\n"
data["config.yaml"] = cfg
doc = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {"name": "cluster-monitoring-config", "namespace": "openshift-monitoring"},
    "data": data,
}
print(json.dumps(doc, indent=2))
' | oc apply -f -
  echo "  [OK] Merged enableUserWorkload: true into existing cluster-monitoring-config"
else
  oc apply -f "${MANIFESTS_DIR}/user-workload-monitoring.yaml"
fi
echo ""

echo "2. Creating NodeFeatureDiscovery instance..."
OCP_MM="$(ocp_major_minor)"
TMP_NFD="$(mktemp)"
sed "s|NFD_IMAGE_TAG|v${OCP_MM}|g" "${MANIFESTS_DIR}/nfd-instance.yaml" > "${TMP_NFD}"
echo "  NFD operand image tag: v${OCP_MM}"
oc apply -f "${TMP_NFD}"
rm -f "${TMP_NFD}"
echo ""

echo "3. Waiting for NFD worker pods..."
for i in $(seq 1 60); do
  NFD_READY=$(oc get pods -n openshift-nfd -l 'app in (nfd-worker),app.kubernetes.io/component=worker' \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "${NFD_READY}" -eq 0 ]; then
    NFD_READY=$(oc get pods -n openshift-nfd -l app=nfd-worker \
      --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  fi
  if [ "${NFD_READY}" -gt 0 ]; then
    echo "  [OK] NFD worker pods running: ${NFD_READY}"
    break
  fi
  echo "  Attempt ${i}/60 — waiting..."
  sleep 5
done
echo ""

echo "4. Creating GPU ClusterPolicy..."
oc apply -f "${MANIFESTS_DIR}/gpu-cluster-policy.yaml"
echo ""

echo "5. DCGM ServiceMonitor (Observe & monitor GPU consumption)..."
oc label ns nvidia-gpu-operator openshift.io/cluster-monitoring=true --overwrite >/dev/null
oc apply -f "${MANIFESTS_DIR}/dcgm-servicemonitor.yaml"
echo ""

echo "6. Waiting for allocatable GPUs on pools that have replicas > 0..."
pool_ok() {
  local selector="$1"
  local needed="$2"
  local found=0
  local all_ok=1
  while read -r node; do
    [ -n "${node}" ] || continue
    found=1
    local alloc
    alloc=$(oc get node "${node}" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
    echo "  ${node}: nvidia.com/gpu allocatable=${alloc:-0} (want ${needed})"
    if [ "${alloc:-0}" != "${needed}" ]; then
      all_ok=0
    fi
  done < <(oc get nodes -l "${selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  [ "${found}" -eq 1 ] && [ "${all_ok}" -eq 1 ]
}

want_pool() {
  local info
  info="$(find_gpu_machineset "$1")"
  local r="${info##*|}"
  [ -n "${r}" ] && [ "${r}" -gt 0 ]
}

NEED4=0
NEED2=0
want_pool 4l4 && NEED4=1
want_pool 2l4 && NEED2=1
if [ "${NEED4}" -eq 0 ] && [ "${NEED2}" -eq 0 ]; then
  echo "  [OK] no GPU MachineSet with replicas > 0; skipping driver wait"
else
OK=0
for i in $(seq 1 120); do
  GPU_MACHINE_RC=0
  if [ $((i % 6)) -eq 1 ]; then
    report_gpu_machines || GPU_MACHINE_RC=$?
  else
    report_gpu_machines >/dev/null || GPU_MACHINE_RC=$?
  fi
  if [ "${GPU_MACHINE_RC}" -eq 1 ]; then
    echo "  [WARN] GPU Machine already Failed — stopping the driver wait. Fix quota/capacity, then re-run this script."
    report_gpu_machines || true
    break
  fi
  OK4=1
  OK2=1
  if [ "${NEED4}" -eq 1 ]; then
    pool_ok "workshop.opendatahub.io/l4-count=${GPU_4L4_COUNT}" "${GPU_4L4_COUNT}" || OK4=0
  fi
  if [ "${NEED2}" -eq 1 ]; then
    pool_ok "workshop.opendatahub.io/l4-count=${GPU_2L4_COUNT}" "${GPU_2L4_COUNT}" || OK2=0
  fi
  if [ "${OK4}" -eq 1 ] && [ "${OK2}" -eq 1 ]; then
    echo "  [OK] GPU allocatable counts match live MachineSet replicas"
    oc get nodes -l node-role.kubernetes.io/worker-gpu
    OK=1
    break
  fi
  echo "  Attempt ${i}/120 — waiting for GPU detection / driver..."
  sleep 10
done

if [ "${OK}" -ne 1 ]; then
  echo "  [WARN] GPU allocatable capacity not ready yet. Driver may still be installing."
  echo "         Re-run this script or ./setup/health-check.sh later."
fi
fi

echo ""
echo "7. Waiting for Prometheus to scrape DCGM_FI_DEV_GPU_UTIL..."
prometheus_has_dcgm() {
  oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
    wget -qO- 'http://127.0.0.1:9090/api/v1/query?query=count(DCGM_FI_DEV_GPU_UTIL)' 2>/dev/null \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
rows = (data.get("data") or {}).get("result") or []
if not rows:
    sys.exit(1)
sys.exit(0 if float(rows[0]["value"][1]) >= 1 else 1)
'
}
DCGM_OK=0
for i in $(seq 1 24); do
  if prometheus_has_dcgm; then
    echo "  [OK] cluster Prometheus has DCGM_FI_DEV_GPU_UTIL"
    DCGM_OK=1
    break
  fi
  echo "  Attempt ${i}/24 — waiting for DCGM scrape"
  sleep 10
done
if [ "${DCGM_OK}" -ne 1 ]; then
  echo "  [WARN] DCGM_FI_DEV_GPU_UTIL not in Prometheus yet. Observe & monitor GPU charts stay empty until scrape starts."
fi

echo ""
echo "=== GPU configuration complete ==="
