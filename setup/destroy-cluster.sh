#!/bin/bash
# Destroy the GCP IPI cluster created by setup/01-install-cluster.sh.
# Does not uninstall workshop operators on a still-running cluster — use
# setup/uninstall-demo.sh for that. Does not delete the pre-existing Cloud DNS zone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env-tools.sh
source "${SCRIPT_DIR}/env-tools.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib-gcp.sh
source "${SCRIPT_DIR}/lib-gcp.sh"

FORCE=0
for arg in "$@"; do
  case "${arg}" in
    --force|-y) FORCE=1 ;;
    --help|-h)
      echo "Usage: $0 [--force]"
      echo "Destroy the OpenShift cluster in ./cluster (openshift-install destroy)."
      echo "Keeps the public Cloud DNS managed zone."
      exit 0
      ;;
    *) echo "Unknown argument: ${arg}" >&2; exit 1 ;;
  esac
done

if ! command -v openshift-install >/dev/null 2>&1; then
  echo "  ERROR: openshift-install not found. Run ./setup/00-install-tools.sh" >&2
  exit 1
fi

load_gcp_credentials
assert_gcp_region
gcp_activate

CLUSTER_DIR="$(workshop_cluster_dir)"
if [ ! -f "${CLUSTER_DIR}/metadata.json" ]; then
  echo "  ERROR: ${CLUSTER_DIR}/metadata.json not found. Nothing to destroy." >&2
  exit 1
fi

if [ "${FORCE}" -ne 1 ] && [ -t 0 ]; then
  echo "This will delete the OpenShift cluster in ${CLUSTER_DIR} and its GCP resources."
  echo "The Cloud DNS zone ${GCP_BASE_DOMAIN} is kept."
  read -rp "Continue? [y/N] " REPLY
  [[ "${REPLY}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

echo "=== Destroying cluster ==="
export GOOGLE_APPLICATION_CREDENTIALS
openshift-install destroy cluster --dir "${CLUSTER_DIR}" --log-level=info
echo ""
echo "Removing leftover installer files (keeping .gpu-az hints if present)..."
# Keep SSH keys and the extracted SA JSON; remove installer state.
# Do not delete private/credentials or the Cloud DNS zone.
rm -f "${CLUSTER_DIR}/metadata.json" \
  "${CLUSTER_DIR}/terraform."* \
  "${CLUSTER_DIR}/.openshift_install"* \
  "${CLUSTER_DIR}/auth/kubeconfig" \
  "${CLUSTER_DIR}/auth/kubeadmin-password" 2>/dev/null || true
echo "=== Destroy complete ==="
