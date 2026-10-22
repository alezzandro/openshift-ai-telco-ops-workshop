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
echo "  OpenShift AI Telco Operations Workshop — URLs"
echo "============================================================"
echo ""

DOMAIN="$(cluster_domain)"
API="$(oc whoami --show-server 2>/dev/null || echo unknown)"

GUIDE_HOST=$(oc get route lab-guide -n lab-guide -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
PLAY_HOST=$(oc get route playground -n lab-guide -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
echo "--- Presenter guide ---"
if [ -n "${GUIDE_HOST}" ]; then
  echo "  URL:         https://${GUIDE_HOST}"
  echo "  Audience:    Facilitator (guided demo C1–C8 / TELCO)"
else
  echo "  [NOT DEPLOYED]  Run ./setup/11-deploy-lab-guide.sh"
fi
echo ""
echo "--- Playground (students) ---"
if [ -n "${PLAY_HOST}" ]; then
  echo "  URL:         https://${PLAY_HOST}"
  echo "  Audience:    Students (rules + P1–P8). Do not send the presenter URL."
else
  echo "  [NOT DEPLOYED]  Run ./setup/11-deploy-lab-guide.sh"
fi
echo ""

echo "--- OpenShift ---"
echo "  Console:     https://console-openshift-console.${DOMAIN}"
echo "  API server:  ${API}"
echo "  User:        $(oc whoami 2>/dev/null || echo unknown)"
KUBEADMIN_FILE="$(cd "${SCRIPT_DIR}/.." && pwd)/cluster/auth/kubeconfig"
KUBEADMIN_PW="$(cd "${SCRIPT_DIR}/.." && pwd)/cluster/auth/kubeadmin-password"
if [ -f "${KUBEADMIN_PW}" ]; then
  echo "  kubeadmin:   $(cat "${KUBEADMIN_PW}")  (break-glass)"
fi
if [ -f "${KUBEADMIN_FILE}" ]; then
  echo "  kubeconfig:  $(cd "${SCRIPT_DIR}/.." && pwd)/cluster/auth/kubeconfig"
fi
echo ""
echo "--- HTPasswd (cluster-admin) ---"
echo "  Login at the console with these users. Passwords are not in the lab-guide banner."
HT_USERS="admin"
for i in $(seq 1 9); do
  HT_USERS="${HT_USERS} student${i}"
done
HT_ANY=0
for user in ${HT_USERS}; do
  if PASS="$(get_cred "HTPASSWD_${user}")"; then
    printf '  %-10s %s\n' "${user}" "${PASS}"
    HT_ANY=1
  fi
done
if [ "${HT_ANY}" -eq 0 ]; then
  echo "  (none yet — run ./setup/02-configure-access.sh)"
fi
echo ""

RHOAI_HOST="$(rhoai_dashboard_host)"
echo "--- Red Hat OpenShift AI ---"
if [ -n "${RHOAI_HOST}" ]; then
  echo "  Dashboard:   https://${RHOAI_HOST}"
else
  echo "  Dashboard:   (no route)"
fi
echo "  Auth:        OpenShift credentials"
echo "  Projects:    ${DS_PROJECTS}"
echo "  Workbench:   ${WORKBENCH_PROJECT}/${WORKBENCH_NAME} (CPU, no Kueue)"
echo "  Notebooks:   llm-on-openshift/${WORKBENCH_NOTEBOOK_REL}"
echo "  Registry:    ${MODEL_REGISTRY_NS}/${MODEL_REGISTRY_NAME}"
echo "  MCP Catalog: AI hub → MCP servers (Technology Preview)"
echo "  Custom MCP:  Catalog card workshop-custom-mcp (C2b, not pre-deployed)"
MCP_ADDR="$(oc get mcpserver "${MCP_SERVER_NAME}" -n "${PRESENTER_PROJECT}" -o jsonpath='{.status.address.url}' 2>/dev/null || true)"
if [ -z "${MCP_ADDR}" ]; then
  MCP_ADDR="$(oc get mcpserver "${MCP_SERVER_NAME}" -n "${PRESENTER_PROJECT}" --no-headers 2>/dev/null || echo not-deployed)"
fi
echo "  OpenShift MCP: ${PRESENTER_PROJECT}/${MCP_SERVER_NAME}  ${MCP_ADDR}"
echo ""

WEBUI_HOST=$(oc get route open-webui -n open-webui -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
echo "--- Open WebUI ---"
if [ -n "${WEBUI_HOST}" ]; then
  echo "  URL:         https://${WEBUI_HOST}"
  echo "  Admin email: $(get_cred WEBUI_ADMIN_EMAIL || echo 'admin@workshop.local')"
  if PASS="$(get_cred WEBUI_ADMIN_PASSWORD)"; then
    echo "  Admin pass:  ${PASS}"
  else
    echo "  Admin pass:  (see setup/.generated-credentials.env)"
  fi
  echo "  Presenter:   optional in-cluster Admin OpenAI connection (not required for the student path)"
  echo "  Students:    authenticated model Route + oc create token workshop-infer (not Direct Connections)"
else
  echo "  [NOT DEPLOYED]"
fi
echo ""

S4_HOST=$(oc get route s4 -n "${S4_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
echo "--- S4 (demo S3 only — not production object storage) ---"
if [ -n "${S4_HOST}" ]; then
  echo "  UI:          https://${S4_HOST}"
  echo "  User:        $(get_cred S4_UI_USER || echo admin)"
  if PASS="$(get_cred S4_UI_PASSWORD)"; then
    echo "  Password:    ${PASS}"
  else
    echo "  Password:    (see setup/.generated-credentials.env)"
  fi
  echo "  S3 (in-cluster): http://s4.${S4_NS}.svc.cluster.local:7480"
  echo "  Bucket/path: s3://${S4_BUCKET}/${HF_C4_PREFIX}/   (${HF_C4_REPO})"
  echo "  Connection:  ${S4_CONNECTION_NAME} (all Data Science Projects)"
  echo "  C4b OCI:     oci://image-registry.openshift-image-registry.svc:5000/${PRESENTER_PROJECT}/${HF_C4B_IS}:${HF_C4B_TAG}"
  echo "  Replace S4 with OpenShift Data Foundation / cloud S3 outside this lab."
else
  echo "  [NOT DEPLOYED]  Run ./setup/12-deploy-s4.sh"
fi
echo ""

echo "--- GPU pools ---"
for pool in 4l4 2l4; do
  GPU_MS_INFO="$(find_gpu_machineset "${pool}")"
  if [ -n "${GPU_MS_INFO}" ]; then
    echo "  ${pool} MachineSet: ${GPU_MS_INFO%%|*}"
    echo "  ${pool} replicas:   ${GPU_MS_INFO##*|}"
  else
    echo "  ${pool} MachineSet: (none)"
  fi
done
oc get nodes -l node-role.kubernetes.io/worker-gpu \
  -o custom-columns=NAME:.metadata.name,L4:.metadata.labels.workshop\\.opendatahub\\.io/l4-count,GPUS:.status.allocatable.nvidia\\.com/gpu --no-headers 2>/dev/null \
  | while read -r line; do echo "  Node:        ${line}"; done
echo "  Class day:   ./setup/scale-students.sh"
echo ""

IS_ANY=$(oc get inferenceservice -A --no-headers 2>/dev/null | wc -l)
echo "--- InferenceServices (student path: Route + workshop-infer token) ---"
if [ "${IS_ANY}" -eq 0 ]; then
  echo "  (none — deploy from the dashboard with Model access + token auth)"
else
  oc get inferenceservice -A 2>/dev/null
  echo ""
  echo "  Routes:"
  oc get route -A -l inferenceservice-name -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,HOST:.spec.host --no-headers 2>/dev/null \
    | while read -r line; do echo "    ${line}"; done
  echo "  Token: oc create token workshop-infer -n <project> --duration=8h"
fi
echo ""
echo "============================================================"
