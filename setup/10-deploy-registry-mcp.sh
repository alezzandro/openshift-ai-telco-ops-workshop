#!/bin/bash
# Model Registry instance plus Technology Preview MCP Catalog/Registry and
# the MCP server for Red Hat OpenShift. DSC flags live in 06-configure-rhoai.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RHOAI_DIR="${REPO_ROOT}/manifests/rhoai"
MCP_DIR="${REPO_ROOT}/manifests/mcp"
PROJ_DIR="${REPO_ROOT}/manifests/projects"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

MR_NAME="${MODEL_REGISTRY_NAME}"
MR_NS="${MODEL_REGISTRY_NS}"
MCP_NS="${PRESENTER_PROJECT}"
MCP_NAME="${MCP_SERVER_NAME}"

echo "=== Deploying Model Registry and MCP (Technology Preview catalog/server) ==="
echo ""

echo "1. Confirming OpenShift AI components..."
if ! oc get datasciencecluster default-dsc >/dev/null 2>&1; then
  echo "  [FAIL] DataScienceCluster default-dsc missing. Run ./setup/06-configure-rhoai.sh first."
  exit 1
fi
if ! oc get crd modelregistries.modelregistry.opendatahub.io >/dev/null 2>&1; then
  echo "  [FAIL] ModelRegistry CRD missing. Wait for the OpenShift AI operator, then re-run 06."
  exit 1
fi
if ! oc get crd mcpservers.mcp.x-k8s.io >/dev/null 2>&1; then
  echo "  [FAIL] MCPServer CRD missing. Set DSC mcplifecycleoperator=Managed (06) and wait for Ready."
  exit 1
fi
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  --type merge -p '{"spec":{"dashboardConfig":{"disableModelCatalog":false,"disableModelRegistry":false,"genAiStudio":true,"aiAssetCustomEndpoints":true,"mcpCatalog":true,"mcpRegistry":true}}}' \
  >/dev/null && echo "  [OK] Dashboard Model Catalog, Model Registry, MCP Catalog, MCP Registry, Gen AI Studio" \
  || echo "  [WARN] Could not patch OdhDashboardConfig flags"
echo ""

echo "2. Model Registry ${MR_NS}/${MR_NAME} (operator-generated PostgreSQL — evaluation only)..."
oc apply -f "${RHOAI_DIR}/model-registry.yaml"
READY=0
for i in $(seq 1 60); do
  COND="$(oc get modelregistry.modelregistry.opendatahub.io "${MR_NAME}" -n "${MR_NS}" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}{" "}{end}' 2>/dev/null || true)"
  if echo "${COND}" | grep -q 'Available=True' || echo "${COND}" | grep -q 'Ready=True'; then
    READY=1
    echo "  [OK] ModelRegistry ${MR_NAME} Ready (${COND})"
    break
  fi
  echo "  Attempt ${i}/60 — ${COND:-pending}"
  sleep 10
done
if [ "${READY}" -ne 1 ]; then
  echo "  [WARN] ModelRegistry not Ready yet. Pods:"
  oc get pods -n "${MR_NS}" -o wide || true
  oc describe modelregistry.modelregistry.opendatahub.io "${MR_NAME}" -n "${MR_NS}" | tail -40 || true
fi

echo "  Granting authenticated users and workshop projects the registry-user Role..."
for i in $(seq 1 30); do
  if oc get role "registry-user-${MR_NAME}" -n "${MR_NS}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
if oc get role "registry-user-${MR_NAME}" -n "${MR_NS}" >/dev/null 2>&1; then
  MR_NS="${MR_NS}" MR_NAME="${MR_NAME}" DS_PROJECTS="${DS_PROJECTS}" WORKBENCH_PROJECT="${WORKBENCH_PROJECT}" \
  python3 - <<'PY' | oc apply -f -
import json, os
ns = os.environ["MR_NS"]
role = "registry-user-" + os.environ["MR_NAME"]
projects = os.environ.get("DS_PROJECTS", "").split() + [os.environ.get("WORKBENCH_PROJECT", "")]
docs = []
docs.append({
  "apiVersion": "rbac.authorization.k8s.io/v1",
  "kind": "RoleBinding",
  "metadata": {
    "name": "workshop-registry-users",
    "namespace": ns,
    "labels": {"opendatahub.io/dashboard": "true", "workshop.opendatahub.io/component": "model-registry"},
  },
  "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": role},
  "subjects": [{"apiGroup": "rbac.authorization.k8s.io", "kind": "Group", "name": "system:authenticated"}],
})
for proj in projects:
    if not proj:
        continue
    docs.append({
      "apiVersion": "rbac.authorization.k8s.io/v1",
      "kind": "RoleBinding",
      "metadata": {
        "name": f"workshop-registry-project-{proj}",
        "namespace": ns,
        "labels": {
          "opendatahub.io/dashboard": "true",
          "opendatahub.io/rb-project-shared": "true",
          "workshop.opendatahub.io/component": "model-registry",
        },
      },
      "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": role},
      "subjects": [{"apiGroup": "rbac.authorization.k8s.io", "kind": "Group", "name": f"system:serviceaccounts:{proj}"}],
    })
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": docs}))
PY
  echo "  [OK] RoleBindings for system:authenticated and workshop projects"
else
  echo "  [WARN] Role registry-user-${MR_NAME} not created yet. Grant access from the dashboard later."
fi
echo ""

echo "3. MCP server for Red Hat OpenShift in ${MCP_NS} (read-only, ClusterRole view + node list)..."
oc apply -f "${PROJ_DIR}/rbac.yaml"
oc apply -f "${MCP_DIR}/rbac.yaml"
oc apply -f "${MCP_DIR}/configmap.yaml"
TMP_MCP="$(mktemp)"
OPENSHIFT_MCP_IMAGE="${OPENSHIFT_MCP_IMAGE}" \
MCP_NS="${MCP_NS}" MCP_NAME="${MCP_NAME}" \
TEMPLATE="${MCP_DIR}/mcpserver.yaml" python3 - <<'PY' > "${TMP_MCP}"
import os
text = open(os.environ["TEMPLATE"], encoding="utf-8").read()
text = text.replace("namespace: telco-ops-demo", "namespace: " + os.environ["MCP_NS"], 1)
text = text.replace("name: openshift-mcp-server", "name: " + os.environ["MCP_NAME"], 1)
img = os.environ.get("OPENSHIFT_MCP_IMAGE", "")
if img:
    text = text.replace(
        "ref: registry.redhat.io/openshift-mcp-tech-preview/openshift-mcp-server-rhel9:0.4",
        "ref: " + img,
        1,
    )
print(text, end="")
PY
oc apply -f "${TMP_MCP}"
rm -f "${TMP_MCP}"

MCP_READY=0
for i in $(seq 1 60); do
  LINE="$(oc get mcpserver "${MCP_NAME}" -n "${MCP_NS}" --no-headers 2>/dev/null || true)"
  READY_COL="$(oc get mcpserver "${MCP_NAME}" -n "${MCP_NS}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [ "${READY_COL}" = "True" ]; then
    MCP_READY=1
    echo "  [OK] MCPServer ${MCP_NAME} Ready"
    echo "       ${LINE}"
    break
  fi
  echo "  Attempt ${i}/60 — Ready=${READY_COL:-?} ${LINE}"
  sleep 10
done
if [ "${MCP_READY}" -ne 1 ]; then
  echo "  [WARN] MCPServer not Ready yet."
  oc get mcpserver "${MCP_NAME}" -n "${MCP_NS}" -o yaml | tail -50 || true
  oc get pods -n "${MCP_NS}" -l app=openshift-mcp-server -o wide || true
  oc get pods -n "${MCP_NS}" | grep -i mcp || true
fi

ADDR="$(oc get mcpserver "${MCP_NAME}" -n "${MCP_NS}" -o jsonpath='{.status.address.url}' 2>/dev/null || true)"
if [ -z "${ADDR}" ]; then
  ADDR="$(oc get mcpserver "${MCP_NAME}" -n "${MCP_NS}" -o jsonpath='{.status.address}' 2>/dev/null || true)"
fi

echo ""
echo "4. Custom MCP catalog source (workshop-custom-mcp — stand-in for a customer image)..."
MCP_DIR="${MCP_DIR}" python3 - <<'PY' | oc apply -f -
import json, os, subprocess
catalog = open(os.path.join(os.environ["MCP_DIR"], "workshop-mcp-catalog.yaml"), encoding="utf-8").read()
sources = """mcp_catalogs:
  - name: Workshop custom
    id: workshop_custom_mcp
    type: yaml
    enabled: true
    properties:
      yamlCatalogPath: workshop-mcp-catalog.yaml
    labels:
      - Workshop
labels:
  - name: Workshop
    assetType: mcp_servers
    displayName: Workshop MCP servers
    description: Custom catalog for this workshop — onboard your own MCP server.
"""
labels = {
  "app": "model-catalog",
  "workshop.opendatahub.io/component": "mcp-catalog",
}
data = {}
try:
    existing = json.loads(subprocess.check_output(
        ["oc", "get", "cm", "mcp-catalog-sources", "-n", "rhoai-model-registries", "-o", "json"],
        text=True,
    ))
    labels.update(existing.get("metadata", {}).get("labels") or {})
    data.update(existing.get("data") or {})
except subprocess.CalledProcessError:
    pass
data["sources.yaml"] = sources
data["workshop-mcp-catalog.yaml"] = catalog
print(json.dumps({
  "apiVersion": "v1",
  "kind": "ConfigMap",
  "metadata": {
    "name": "mcp-catalog-sources",
    "namespace": "rhoai-model-registries",
    "labels": labels,
  },
  "data": data,
}))
PY
if oc get deploy model-catalog -n rhoai-model-registries >/dev/null 2>&1; then
  if mcp_catalog_has_workshop_server; then
    echo "  [OK] mcp-catalog-sources includes Workshop custom; card workshop-custom-mcp is in the catalog"
  else
    recover_model_catalog_leader || true
    for i in $(seq 1 24); do
      if mcp_catalog_has_workshop_server; then
        echo "  [OK] Catalog card workshop-custom-mcp is searchable"
        break
      fi
      sleep 5
    done
    if ! mcp_catalog_has_workshop_server; then
      echo "  [WARN] workshop-custom-mcp not in catalog API yet. Search the MCP Catalog, or ./setup/health-check.sh --fix"
    fi
  fi
else
  echo "  [OK] mcp-catalog-sources includes Workshop custom"
fi

echo ""
echo "5. Gen AI Studio Playground MCP list (Technology Preview)..."
oc apply -f "${MCP_DIR}/gen-ai-aa-mcp-servers.yaml"
echo "  [OK] ConfigMap gen-ai-aa-mcp-servers (openshift-mcp-server)"
for ns in ${DS_PROJECTS}; do
  oc apply -n "${ns}" -f "${MCP_DIR}/gen-ai-aa-optional-cms.yaml"
  echo "  [OK] playground optional ConfigMaps in ${ns}"
done

echo ""
echo "=== Model Registry and MCP complete ==="
echo "  Model Registry:  ${MR_NS}/${MR_NAME} (Settings → Model registry settings)"
echo "  MCP Catalog:     AI hub → MCP servers → Catalog (Technology Preview)"
echo "  MCP Registry:    AI hub → MCP servers → Deployments (Technology Preview)"
echo "  Custom catalog:  workshop-custom-mcp (C2b — not pre-deployed)"
echo "  OpenShift MCP:   ${MCP_NS}/${MCP_NAME}  ${ADDR}"
echo "  Gen AI Playground MCP: ConfigMap gen-ai-aa-mcp-servers (not a pre-created playground instance)"
echo "  Not supported with Red Hat production SLAs; not recommended for production."
echo "  Docs: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_the_mcp_catalog/index"
echo "        https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_model_registries/creating-a-model-registry_managing-model-registries"
echo "        https://access.redhat.com/support/offerings/techpreview"
