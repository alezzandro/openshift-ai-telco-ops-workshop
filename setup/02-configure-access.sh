#!/bin/bash
# Let's Encrypt certificates (Cloud DNS DNS-01) and HTPasswd IDP.
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

CERTS_ONLY=0
for arg in "$@"; do
  case "${arg}" in
    --certs-only) CERTS_ONLY=1 ;;
    --help|-h)
      echo "Usage: $0 [--certs-only]"
      echo "  --certs-only  re-issue Let's Encrypt certs; leave HTPasswd users alone"
      exit 0
      ;;
  esac
done

load_gcp_credentials
gcp_activate

if [ -z "${GCP_ACME_EMAIL:-}" ]; then
  echo "  ERROR: GCP_ACME_EMAIL is required for Let's Encrypt." >&2
  echo "         Set it in the environment or add a gcp_acme_email line to" >&2
  echo "         private/credentials/gcp-credentials.txt" >&2
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "  ERROR: '$1' not found. Run ./setup/00-install-tools.sh" >&2
    exit 1
  fi
}
need_cmd lego
need_cmd htpasswd
need_cmd openssl

CLUSTER_DIR="$(workshop_cluster_dir)"
CERT_DIR="${CLUSTER_DIR}/tls"
mkdir -p "${CERT_DIR}"
chmod 700 "${CERT_DIR}"

DOMAIN="$(cluster_domain)"
if [ -z "${DOMAIN}" ]; then
  DOMAIN="apps.${CLUSTER_NAME}.${GCP_BASE_DOMAIN}"
fi
# cluster_domain is typically apps.<cluster>.<base>
APPS_HOST="*.${DOMAIN}"
API_HOST="api.${CLUSTER_NAME}.${GCP_BASE_DOMAIN}"
# If ingress domain is already apps.ocp.base, wildcard is *.apps.ocp.base
if [[ "${DOMAIN}" != apps.* ]]; then
  APPS_HOST="*.apps.${CLUSTER_NAME}.${GCP_BASE_DOMAIN}"
  DOMAIN="apps.${CLUSTER_NAME}.${GCP_BASE_DOMAIN}"
fi

echo "=== Configure access (TLS + HTPasswd) ==="
echo "  API:     ${API_HOST}"
echo "  Apps:    ${APPS_HOST}"
echo "  ACME:    ${GCP_ACME_EMAIL}"
echo ""

issue_cert() {
  local name="$1"
  shift
  local out="${CERT_DIR}/${name}"
  mkdir -p "${out}"
  local args=()
  local d
  for d in "$@"; do
    args+=(--domains "${d}")
  done
  echo "  Issuing ${name}: $*"
  GCE_PROJECT="${GCP_PROJECT}" \
  GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS}" \
  lego --accept-tos --email "${GCP_ACME_EMAIL}" --dns gcloud \
    --path "${out}" \
    "${args[@]}" \
    run
}

issue_cert api "${API_HOST}"
issue_cert apps "${APPS_HOST}"

API_CRT="$(find "${CERT_DIR}/api/certificates" -name '*.crt' ! -name '*issuer*' | head -1)"
API_KEY="$(find "${CERT_DIR}/api/certificates" -name '*.key' | head -1)"
APPS_CRT="$(find "${CERT_DIR}/apps/certificates" -name '*.crt' ! -name '*issuer*' | head -1)"
APPS_KEY="$(find "${CERT_DIR}/apps/certificates" -name '*.key' | head -1)"
if [ -z "${API_CRT}" ] || [ -z "${API_KEY}" ] || [ -z "${APPS_CRT}" ] || [ -z "${APPS_KEY}" ]; then
  echo "  ERROR: lego did not write certificate files under ${CERT_DIR}" >&2
  find "${CERT_DIR}" -type f | head -20 >&2
  exit 1
fi

echo "1. API serving certificate..."
oc create secret tls api-tls -n openshift-config \
  --cert="${API_CRT}" --key="${API_KEY}" \
  --dry-run=client -o yaml | oc apply -f -
API_PATCH="$(python3 -c "import json; print(json.dumps({'spec':{'servingCerts':{'namedCertificates':[{'names':['${API_HOST}'],'servingCertificate':{'name':'api-tls'}}]}}}))")"
oc patch apiserver cluster --type=merge -p "${API_PATCH}"
echo "  [OK] APIServer namedCertificates -> api-tls"
echo ""

echo "2. Ingress default certificate..."
oc create secret tls apps-tls -n openshift-ingress \
  --cert="${APPS_CRT}" --key="${APPS_KEY}" \
  --dry-run=client -o yaml | oc apply -f -
oc patch ingresscontroller default -n openshift-ingress-operator --type=merge \
  -p '{"spec":{"defaultCertificate":{"name":"apps-tls"}}}'
echo "  [OK] IngressController defaultCertificate -> apps-tls"
echo ""

if [ "${CERTS_ONLY}" -eq 1 ]; then
  echo "=== Certificates updated (--certs-only; HTPasswd unchanged) ==="
  exit 0
fi

echo "3. HTPasswd identity provider..."
HTPASS_FILE="$(mktemp)"
chmod 600 "${HTPASS_FILE}"
USERS="admin"
for i in $(seq 1 9); do
  USERS="${USERS} student${i}"
done
first=1
for user in ${USERS}; do
  pass="$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)"
  if [ "${first}" -eq 1 ]; then
    htpasswd -c -B -b "${HTPASS_FILE}" "${user}" "${pass}"
    first=0
  else
    htpasswd -B -b "${HTPASS_FILE}" "${user}" "${pass}"
  fi
  set_cred "HTPASSWD_${user}" "${pass}"
  echo "  [OK] user ${user}"
done

oc create secret generic htpasswd-workshop -n openshift-config \
  --from-file=htpasswd="${HTPASS_FILE}" \
  --dry-run=client -o yaml | oc apply -f -
rm -f "${HTPASS_FILE}"

python3 - <<'PY'
import json, subprocess
raw = subprocess.check_output(["oc", "get", "oauth", "cluster", "-o", "json"], text=True)
doc = json.loads(raw)
spec = doc.setdefault("spec", {})
idps = spec.setdefault("identityProviders", [])
ht = {
    "name": "htpasswd",
    "mappingMethod": "claim",
    "type": "HTPasswd",
    "htpasswd": {"fileData": {"name": "htpasswd-workshop"}},
}
idps = [p for p in idps if p.get("name") != "htpasswd"]
idps.insert(0, ht)
spec["identityProviders"] = idps
doc.pop("status", None)
md = doc.setdefault("metadata", {})
for k in ("uid", "resourceVersion", "generation", "creationTimestamp", "managedFields"):
    md.pop(k, None)
subprocess.run(["oc", "apply", "-f", "-"], input=json.dumps(doc), text=True, check=True)
print("  [OK] OAuth cluster IDP htpasswd")
PY

echo "  Waiting for oauth-openshift rollout..."
oc rollout status deployment/oauth-openshift -n openshift-authentication --timeout=180s || true

for user in ${USERS}; do
  oc adm policy add-cluster-role-to-user cluster-admin "${user}" >/dev/null
done
echo "  [OK] cluster-admin on admin + student1–9"
echo ""
echo "=== Access configured ==="
echo "  Passwords are in setup/.generated-credentials.env (gitignored)."
echo "  kubeadmin remains as break-glass."
echo "  ./setup/show-credentials.sh"
