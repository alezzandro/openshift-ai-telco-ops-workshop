#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests/open-webui"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Deploying Open WebUI (multi-tenant) ==="
echo ""

echo "1. Namespace, SCC, PVC, Service, Route..."
oc apply -f "${MANIFESTS_DIR}/namespace.yaml"
oc apply -f "${MANIFESTS_DIR}/scc.yaml"
oc apply -f "${MANIFESTS_DIR}/pvc.yaml"
oc apply -f "${MANIFESTS_DIR}/service.yaml"
oc apply -f "${MANIFESTS_DIR}/route.yaml"
oc apply -f "${MANIFESTS_DIR}/networkpolicy.yaml"
echo ""

echo "2. Session secret..."
EXISTING_KEY="$(get_cred WEBUI_SECRET_KEY || true)"
if [ -z "${EXISTING_KEY}" ]; then
  EXISTING_KEY="$(openssl rand -hex 32)"
  set_cred WEBUI_SECRET_KEY "${EXISTING_KEY}"
  echo "  Generated WEBUI_SECRET_KEY"
else
  echo "  Reusing WEBUI_SECRET_KEY"
fi
oc create secret generic open-webui-secret \
  -n open-webui \
  --from-literal=WEBUI_SECRET_KEY="${EXISTING_KEY}" \
  --dry-run=client -o yaml | oc apply -f -
echo ""

echo "3. Deployment (pinned ${OPEN_WEBUI_IMAGE})..."
TMP_DEP="$(mktemp)"
sed "s|image: ghcr.io/open-webui/open-webui:v0.6.36|image: ${OPEN_WEBUI_IMAGE}|" \
  "${MANIFESTS_DIR}/deployment.yaml" > "${TMP_DEP}"
oc apply -f "${TMP_DEP}"
rm -f "${TMP_DEP}"

oc wait deployment/open-webui -n open-webui --for=condition=Available --timeout=300s \
  || echo "  [WARN] Deployment not Available yet; image may still be pulling"
echo ""

echo "4. Creating admin account (first signup is admin)..."
ADMIN_EMAIL="$(get_cred WEBUI_ADMIN_EMAIL || true)"
ADMIN_PASS="$(get_cred WEBUI_ADMIN_PASSWORD || true)"
if [ -z "${ADMIN_EMAIL}" ]; then
  ADMIN_EMAIL="admin@workshop.local"
  set_cred WEBUI_ADMIN_EMAIL "${ADMIN_EMAIL}"
fi
if [ -z "${ADMIN_PASS}" ]; then
  ADMIN_PASS="$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
  set_cred WEBUI_ADMIN_PASSWORD "${ADMIN_PASS}"
fi

ROUTE_HOST=$(oc get route open-webui -n open-webui -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
SIGNUP_OK=0
for i in $(seq 1 30); do
  CODE=$(curl -sk -o /tmp/webui-signup.json -w '%{http_code}' \
    -X POST "https://${ROUTE_HOST}/api/v1/auths/signup" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASS}\",\"name\":\"Workshop Admin\"}" \
    2>/dev/null || echo "000")
  if [ "${CODE}" = "200" ] || [ "${CODE}" = "201" ]; then
    echo "  [OK] Admin created (${ADMIN_EMAIL})"
    SIGNUP_OK=1
    break
  fi
  if [ "${CODE}" = "400" ] || [ "${CODE}" = "409" ]; then
    echo "  [OK] Admin already exists (${ADMIN_EMAIL})"
    SIGNUP_OK=1
    break
  fi
  echo "  Signup HTTP ${CODE} — waiting (${i}/30)"
  sleep 5
done
rm -f /tmp/webui-signup.json
if [ "${SIGNUP_OK}" -ne 1 ]; then
  echo "  [WARN] Could not create admin via API. First browser login becomes admin — use ${ADMIN_EMAIL}"
fi

echo ""
echo "5. Forcing legacy function calling and keeping student signup enabled..."
PATCHED=0
for _ in $(seq 1 24); do
  if patch_open_webui_sqlite; then
    PATCHED=1
    break
  fi
  echo "  Waiting for Open WebUI config table..."
  sleep 5
done
if [ "${PATCHED}" -eq 1 ]; then
  oc rollout restart deployment/open-webui -n open-webui
  oc rollout status deployment/open-webui -n open-webui --timeout=180s
else
  echo "  [WARN] Could not patch sqlite; env DEFAULT_MODEL_PARAMS still applies on a fresh PVC"
fi

echo ""
echo "=== Open WebUI ready ==="
echo "  URL:      https://${ROUTE_HOST}"
echo "  Admin:    ${ADMIN_EMAIL}"
echo "  Password: stored in setup/.generated-credentials.env"
echo "  Students: call the model Route with a workshop-infer token (not Open WebUI Direct Connections)."
echo "  Do not load GGUF into Open WebUI — deploy with OpenShift AI first."
