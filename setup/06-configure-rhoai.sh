#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RHOAI_DIR="${REPO_ROOT}/manifests/rhoai"
KUEUE_DIR="${REPO_ROOT}/manifests/kueue"
PROJ_DIR="${REPO_ROOT}/manifests/projects"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Configuring Red Hat OpenShift AI ==="
echo ""

dsc_has_component() {
  oc explain "datasciencecluster.spec.components.${1}" &>/dev/null
}

ensure_dsc_component() {
  local key="$1"
  local state="$2"
  if dsc_has_component "${key}"; then
    echo "  DSC component ${key}: ${state}"
    oc patch datasciencecluster default-dsc --type merge \
      -p "{\"spec\":{\"components\":{\"${key}\":{\"managementState\":\"${state}\"}}}}"
  else
    echo "  Skipping DSC component ${key} (not on this CRD)"
  fi
}

echo "1. Applying DSCInitialization..."
oc apply -f "${RHOAI_DIR}/dscinitialization.yaml"
echo "   Waiting for DSCI metrics stack (Observe & monitor)..."
METRICS_OK=0
for i in $(seq 1 36); do
  MS=$(oc get dscinitialization default-dsci -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")].status}' 2>/dev/null || echo "")
  if [ "${MS}" = "True" ]; then
    echo "  [OK] DSCI MonitoringStackAvailable"
    METRICS_OK=1
    break
  fi
  echo "  Attempt ${i}/36 — MonitoringStackAvailable=${MS:-?} (needs Cluster Observability Operator + metrics.storage)"
  sleep 10
done
if [ "${METRICS_OK}" -ne 1 ]; then
  echo "  [WARN] Monitoring stack not Ready yet. Observe & monitor GPU consumption stays empty until COO installs and DSCI reconciles."
fi
echo ""

echo "2. Applying DataScienceCluster..."
if oc apply -f "${RHOAI_DIR}/datasciencecluster.yaml"; then
  echo "  Applied datasciencecluster.yaml"
else
  echo "  [WARN] DSC apply failed (unknown fields?). Patching known components."
fi

ensure_dsc_component dashboard Managed
ensure_dsc_component kserve Managed
ensure_dsc_component workbenches Managed
ensure_dsc_component modelregistry Managed
ensure_dsc_component mcplifecycleoperator Managed
ensure_dsc_component kueue Unmanaged
ensure_dsc_component ray Removed
ensure_dsc_component trainingoperator Removed
ensure_dsc_component aipipelines Removed
ensure_dsc_component trustyai Removed
ensure_dsc_component feastoperator Removed
ensure_dsc_component llamastackoperator Removed
ensure_dsc_component ogx Managed
ensure_dsc_component aigateway Removed
echo ""

echo "3. Waiting for DataScienceCluster to be Ready..."
for i in $(seq 1 120); do
  READY=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  PHASE=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "${READY}" = "True" ]; then
    echo "  [OK] DataScienceCluster is Ready"
    break
  fi
  echo "  Attempt ${i}/120 — Ready=${READY:-?} phase=${PHASE:-Pending}"
  sleep 10
done
# Gen AI Studio → Playground nav is gated on status.components.ogx.managementState
# being Managed/Unmanaged. The operator can leave that status at Removed even
# when spec.ogx is Managed and OGXReady=True.
OGX_STATUS="$(oc get datasciencecluster default-dsc -o jsonpath='{.status.components.ogx.managementState}' 2>/dev/null || true)"
if [ "${OGX_STATUS}" != "Managed" ] && [ "${OGX_STATUS}" != "Unmanaged" ]; then
  echo "  DSC status.components.ogx=${OGX_STATUS:-empty} (Playground nav hidden). Patching status to Managed..."
  oc patch datasciencecluster default-dsc --subresource=status --type merge \
    -p '{"status":{"components":{"ogx":{"managementState":"Managed"}}}}' \
    && echo "  [OK] status.components.ogx=Managed" \
    || echo "  [WARN] Could not patch DSC ogx status"
fi
echo ""

echo "4. Enabling Model Catalog, MCP Catalog/Registry, HardwareProfiles, and Kueue in the dashboard..."
for i in $(seq 1 30); do
  if oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications &>/dev/null; then
    break
  fi
  sleep 5
done
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  --type merge -p '{"spec":{"dashboardConfig":{"disableModelCatalog":false,"disableModelRegistry":false,"genAiStudio":true,"aiAssetCustomEndpoints":true,"mcpCatalog":true,"mcpRegistry":true}}}' \
  2>/dev/null && echo "  [OK] Model Catalog + Model Registry + MCP Catalog/Registry + Gen AI Studio Playground" \
  || echo "  [WARN] Could not patch OdhDashboardConfig catalog flags"
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  --type merge -p '{"spec":{"dashboardConfig":{"disableKueue":false}}}' \
  2>/dev/null && echo "  [OK] Kueue visible in dashboard" \
  || echo "  [WARN] disableKueue field not on this OdhDashboardConfig"
echo ""

echo "5. Creating Data Science Projects..."
oc apply -f "${PROJ_DIR}/namespaces.yaml"
oc apply -f "${PROJ_DIR}/resourcequotas.yaml"
oc apply -f "${PROJ_DIR}/rbac.yaml"
oc apply -f "${PROJ_DIR}/inference-auth.yaml"
oc apply -f "${PROJ_DIR}/networkpolicies.yaml"
oc apply -f "${PROJ_DIR}/kserve-vllm-prometheusrule.yaml"
echo ""

echo "5b. NemoGuardrails list API for Gen AI Playground (TrustyAI stays Removed)..."
# Playground BFF lists NemoGuardrails on every chat. Missing API group → HTTP 500.
if oc get crd nemoguardrails.trustyai.opendatahub.io &>/dev/null \
   && ! oc get crd nemoguardrails.trustyai.opendatahub.io \
        -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null \
        | grep -q telco-ops-workshop; then
  echo "  [OK] NemoGuardrails CRD already present (not workshop-owned); skipping stub"
else
  oc apply -f "${RHOAI_DIR}/nemoguardrails-crd.yaml"
  oc wait --for=condition=Established crd/nemoguardrails.trustyai.opendatahub.io --timeout=60s \
    && echo "  [OK] nemoguardrails.trustyai.opendatahub.io Established" \
    || echo "  [WARN] NemoGuardrails CRD not Established yet"
fi
echo ""

echo "6. Creating Kueue instance, ResourceFlavor, ClusterQueue, LocalQueues..."
if oc apply -f "${KUEUE_DIR}/kueue-instance.yaml"; then
  echo "  [OK] Kueue CR applied"
else
  echo "  [WARN] Kueue CR apply failed (operator CRD may use a different group). Continuing."
fi
oc apply -f "${KUEUE_DIR}/resource-flavor.yaml" || echo "  [WARN] ResourceFlavor apply failed"
oc apply -f "${KUEUE_DIR}/cluster-queue.yaml" || echo "  [WARN] ClusterQueue apply failed"
oc apply -f "${KUEUE_DIR}/local-queues.yaml" || echo "  [WARN] LocalQueue apply failed"
# Drop the AWS-era single-pool objects if they are still on the cluster.
oc delete clusterqueue gpu-pool --ignore-not-found
oc delete resourceflavor l4-gpu --ignore-not-found
LIVE4="$(find_gpu_machineset 4l4)"; LIVE4="${LIVE4##*|}"
LIVE2="$(find_gpu_machineset 2l4)"; LIVE2="${LIVE2##*|}"
sync_kueue_gpu_quotas "${LIVE4:-0}" "${LIVE2:-0}" || true
echo ""

echo "7. Creating HardwareProfiles..."
apply_hp() {
  local queue_file="$1"
  local fallback_file="$2"
  if oc apply -f "${queue_file}"; then
    echo "  [OK] $(basename "${queue_file}")"
    return 0
  fi
  echo "  [WARN] Queue-backed profile rejected; applying Node fallback $(basename "${fallback_file}")"
  oc apply -f "${fallback_file}"
}

apply_hp "${RHOAI_DIR}/hardware-profile-l4-1.yaml" "${RHOAI_DIR}/hardware-profile-l4-1-node-fallback.yaml"
apply_hp "${RHOAI_DIR}/hardware-profile-l4-2-tp.yaml" "${RHOAI_DIR}/hardware-profile-l4-2-tp-node-fallback.yaml"
apply_hp "${RHOAI_DIR}/hardware-profile-l4-4-tp.yaml" "${RHOAI_DIR}/hardware-profile-l4-4-tp-node-fallback.yaml"
oc apply -f "${RHOAI_DIR}/hardware-profile-cpu.yaml"
echo ""

echo "8. Creating vLLM NVIDIA GPU ServingRuntime in each project..."
VLLM_IMAGE="$(detect_vllm_image)"
echo "  vLLM image: ${VLLM_IMAGE}"
VLLM_TEMPLATE_NAME=$(oc get template -n redhat-ods-applications -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -i 'vllm.*cuda' | head -1 || true)
TEMPLATE_DISPLAY="vLLM NVIDIA GPU ServingRuntime for KServe"
if [ -n "${VLLM_TEMPLATE_NAME}" ]; then
  echo "  Platform template: ${VLLM_TEMPLATE_NAME}"
  TEMPLATE_DISPLAY=$(oc get template "${VLLM_TEMPLATE_NAME}" -n redhat-ods-applications \
    -o jsonpath='{.objects[0].metadata.annotations.openshift\.io/display-name}' 2>/dev/null || echo "${TEMPLATE_DISPLAY}")
fi

for ns in ${DS_PROJECTS}; do
  TMP_SR="$(mktemp)"
  sed \
    -e "s|namespace: telco-ops-demo|namespace: ${ns}|" \
    -e "s|image: registry.redhat.io/rhaiis/vllm-cuda-rhel9:3.3.0|image: ${VLLM_IMAGE}|" \
    -e "s|opendatahub.io/template-name:.*|opendatahub.io/template-name: ${VLLM_TEMPLATE_NAME:-vllm-cuda-runtime-template}|" \
    -e "s|opendatahub.io/template-display-name:.*|opendatahub.io/template-display-name: ${TEMPLATE_DISPLAY}|" \
    "${RHOAI_DIR}/vllm-serving-runtime.yaml" > "${TMP_SR}"
  oc apply -f "${TMP_SR}"
  rm -f "${TMP_SR}"
  echo "  [OK] ServingRuntime in ${ns}"
done

echo ""
echo "9. Catalog OCI connections (shared registry.redhat.io pull host)..."
ensure_redhat_catalog_oci_connections
echo ""
echo "10. In-cluster registry OCI connections (ImageStream ModelCars)..."
ensure_incluster_registry_oci_connections
echo ""

echo "=== OpenShift AI configuration complete ==="
echo "  No InferenceService was created. Register models in Model Registry, then deploy from the dashboard."
