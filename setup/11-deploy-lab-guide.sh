#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFESTS_DIR="${REPO_ROOT}/manifests/lab-guide"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Deploying in-cluster lab guide ==="
echo ""

echo "1. Namespace, ImageStream, BuildConfig..."
oc apply -f "${MANIFESTS_DIR}/namespace.yaml"
oc apply -f "${MANIFESTS_DIR}/build.yaml"
echo ""

echo "2. Binary build (content + lab-guide only; private/ is not uploaded)..."
echo "  First build needs egress to registry.access.redhat.com and registry.npmjs.org."
CONTEXT="$(mktemp -d)"
trap 'rm -rf "${CONTEXT}"' EXIT
mkdir -p "${CONTEXT}/lab-guide"
cp -a "${REPO_ROOT}/lab-guide/." "${CONTEXT}/lab-guide/"
rm -rf "${CONTEXT}/lab-guide/www" "${CONTEXT}/lab-guide/.cache"
cp -a "${REPO_ROOT}/content" "${CONTEXT}/content"
oc start-build lab-guide -n lab-guide --from-dir="${CONTEXT}" --follow --wait
echo ""

echo "3. Placeholder env ConfigMap, then Deployment + Route..."
oc create configmap lab-guide-env -n lab-guide \
  --from-literal=env.json='{"console":"","rhoai_dashboard":"","open_webui":""}' \
  --dry-run=client -o yaml | oc apply -f -
oc apply -f "${MANIFESTS_DIR}/deployment.yaml"
echo ""

echo "4. Writing live URLs into env.json..."
sleep 2
write_lab_guide_env
oc rollout restart deployment/lab-guide -n lab-guide 2>/dev/null || true
oc rollout status deployment/lab-guide -n lab-guide --timeout=300s || true

echo ""
echo "=== Lab guide ready ==="
echo "  Presenter:  ${GUIDE:-https://<lab-guide-route>}"
echo "  Playground: ${PLAYGROUND:-https://<playground-route>}"
echo "  Hand students the Playground URL only."
