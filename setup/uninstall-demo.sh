#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "============================================================"
echo "  Uninstall workshop applications"
echo "============================================================"
echo "Removes Data Science Projects, Open WebUI, lab guide, pre-pull,"
echo "HardwareProfiles, Kueue queues, the workshop Model Registry, and"
echo "the OpenShift MCP server. Scales GPU MachineSets to 0."
echo "Keeps operators and the GPU MachineSet objects."
echo ""
if [ -t 0 ]; then
  read -rp "Continue? [y/N] " REPLY
  [[ "${REPLY}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi
echo ""

echo "1. Workshop namespaces..."
for ns in ${DS_PROJECTS} ${WORKBENCH_PROJECT} open-webui lab-guide workshop-prepull s4; do
  oc delete namespace "${ns}" --wait=false 2>/dev/null && echo "  [OK] ${ns}" || echo "  [SKIP] ${ns}"
done
echo ""

echo "2. HardwareProfiles..."
for hp in gpu-l4-1 gpu-l4-2-tp gpu-l4-4-tp cpu-only; do
  oc delete hardwareprofile "${hp}" -n redhat-ods-applications --ignore-not-found
done
echo ""

echo "3. Kueue ClusterQueue / ResourceFlavor / Kueue CR..."
oc delete localqueue --all -n telco-ops-demo --ignore-not-found 2>/dev/null || true
oc delete localqueue --all -n telco-ran-ai --ignore-not-found 2>/dev/null || true
oc delete localqueue --all -n telco-core-ai --ignore-not-found 2>/dev/null || true
oc delete clusterqueue gpu-pool gpu-pool-2l4 gpu-pool-4l4 --ignore-not-found
oc delete resourceflavor l4-gpu l4-gpu-2 l4-gpu-4 --ignore-not-found
oc delete kueue cluster -n openshift-kueue-operator --ignore-not-found 2>/dev/null || true
echo ""

echo "4. Model Registry instance (namespace kept — operator-owned)..."
oc delete modelregistry.modelregistry.opendatahub.io "${MODEL_REGISTRY_NAME}" -n "${MODEL_REGISTRY_NS}" --ignore-not-found
oc delete mcpserver workshop-custom-mcp -n "${PRESENTER_PROJECT}" --ignore-not-found
# Keep the operator-owned ConfigMap; drop workshop catalog keys only.
oc patch cm mcp-catalog-sources -n "${MODEL_REGISTRY_NS}" --type json -p '[{"op":"replace","path":"/data/sources.yaml","value":"mcp_catalogs: []\n"}]' 2>/dev/null || true
oc patch cm mcp-catalog-sources -n "${MODEL_REGISTRY_NS}" --type json -p '[{"op":"remove","path":"/data/workshop-mcp-catalog.yaml"}]' 2>/dev/null || true
oc delete cm gen-ai-aa-mcp-servers -n redhat-ods-applications --ignore-not-found
oc delete clusterrolebinding workshop-nemoguardrails-gen-ai-ui --ignore-not-found
oc delete clusterrole workshop-nemoguardrails-viewer --ignore-not-found
if oc get crd nemoguardrails.trustyai.opendatahub.io \
     -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null \
     | grep -q telco-ops-workshop; then
  oc delete crd nemoguardrails.trustyai.opendatahub.io --ignore-not-found
fi
oc delete rolebinding -n "${MODEL_REGISTRY_NS}" -l workshop.opendatahub.io/component=model-registry --ignore-not-found
oc delete rolebinding workshop-registry-users -n "${MODEL_REGISTRY_NS}" --ignore-not-found
echo ""

echo "5. ClusterRole..."
oc delete clusterrole workshop-ds-user --ignore-not-found
oc delete clusterrolebinding open-webui-anyuid workbench-clone-anyuid workshop-openshift-mcp-viewer workshop-openshift-mcp-node-reader workshop-s4-anyuid --ignore-not-found
oc delete clusterrole workshop-mcp-node-reader --ignore-not-found
echo ""

echo "6. GPU MachineSets → 0 (objects kept)..."
if [ -x "${SCRIPT_DIR}/scale-gpu.sh" ]; then
  bash "${SCRIPT_DIR}/scale-gpu.sh" --4l4 0 --2l4 0 --no-persist || true
else
  echo "  [SKIP] scale-gpu.sh missing"
fi
echo ""

echo "DataScienceCluster is left in place. Operators are not uninstalled."
echo "Done."
