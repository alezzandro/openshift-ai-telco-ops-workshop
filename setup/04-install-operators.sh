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

echo "=== Installing operators ==="
echo ""

echo "1. Node Feature Discovery..."
oc apply -f "${MANIFESTS_DIR}/nfd-subscription.yaml"
echo ""

echo "2. NVIDIA GPU Operator (certified catalog)..."
oc apply -f "${MANIFESTS_DIR}/gpu-operator-subscription.yaml"
echo ""

echo "3. Red Hat OpenShift AI (stable-3.x)..."
oc apply -f "${MANIFESTS_DIR}/rhoai-subscription.yaml"
echo ""

echo "4. cert-manager Operator for Red Hat OpenShift (Kueue prerequisite)..."
if oc get csv -n cert-manager-operator --no-headers 2>/dev/null \
    | grep 'cert-manager-operator' | awk '{print $NF}' | grep -qx Succeeded; then
  echo "  [OK] cert-manager Operator already Succeeded"
else
  apply_operator_manifest "${MANIFESTS_DIR}/cert-manager-subscription.yaml"
fi
echo ""

echo "5. Cluster Observability Operator (OpenShift AI Observe & monitor)..."
apply_operator_manifest "${MANIFESTS_DIR}/coo-subscription.yaml"
echo ""

echo "6. Red Hat build of OpenTelemetry (DSCI metrics collector)..."
apply_operator_manifest "${MANIFESTS_DIR}/opentelemetry-subscription.yaml"
echo ""

echo "7. Red Hat build of Kueue (channel + CSV pinned in kueue-subscription.yaml)..."
oc apply -f "${MANIFESTS_DIR}/kueue-subscription.yaml"
echo ""

echo "Waiting for CSVs..."
wait_for_csv "openshift-nfd" "nfd" 300 || true
wait_for_csv "nvidia-gpu-operator" "gpu-operator" 300 || true
wait_for_csv "redhat-ods-operator" "rhods-operator" 420 || true
wait_for_csv "cert-manager-operator" "cert-manager" 300 || true
wait_for_csv "openshift-cluster-observability-operator" "cluster-observability-operator" 300 || true
wait_for_csv "openshift-opentelemetry-operator" "opentelemetry-operator" 300 || true
wait_for_csv "openshift-kueue-operator" "kueue-operator" 300 || true

echo ""
echo "=== Operator installation initiated ==="
echo "Run 'oc get csv -A' if a CSV is still installing."
