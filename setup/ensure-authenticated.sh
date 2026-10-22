#!/bin/bash
###############################################################################
# Verify the OpenShift session is active; offer oc login if not.
# Auto-uses ./cluster/auth/kubeconfig from setup/01-install-cluster.sh when present.
###############################################################################

_ENSURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env-tools.sh
source "${_ENSURE_DIR}/env-tools.sh"

_workshop_cluster_kubeconfig() {
  echo "$(cd "${_ENSURE_DIR}/.." && pwd)/cluster/auth/kubeconfig"
}

_ensure_oc_authenticated() {
  if ! command -v oc &>/dev/null; then
    echo ""
    echo "  ERROR: 'oc' CLI not found."
    echo "  Run:  ./setup/00-install-tools.sh"
    echo "  Or install from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
    exit 1
  fi

  local generated
  generated="$(_workshop_cluster_kubeconfig)"
  if [ -z "${KUBECONFIG:-}" ] && [ -f "${generated}" ]; then
    export KUBECONFIG="${generated}"
  fi

  if oc whoami &>/dev/null; then
    return 0
  fi

  if [ -f "${generated}" ] && [ "${KUBECONFIG:-}" != "${generated}" ]; then
    export KUBECONFIG="${generated}"
    if oc whoami &>/dev/null; then
      return 0
    fi
  fi

  echo ""
  echo "  OpenShift session expired or not logged in."

  local CLUSTER_URL
  CLUSTER_URL=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")

  if [ -n "${CLUSTER_URL}" ]; then
    echo "  Cluster API: ${CLUSTER_URL}"
  fi
  echo ""

  if [ -t 0 ]; then
    read -rp "  Would you like to log in now? [Y/n] " REPLY
    REPLY=${REPLY:-Y}
    if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
      echo ""
      if [ -n "${CLUSTER_URL}" ]; then
        read -rp "  Username [admin]: " OC_USER
        OC_USER=${OC_USER:-admin}
        read -rsp "  Password: " OC_PASS
        echo ""
        if oc login "${CLUSTER_URL}" -u "${OC_USER}" -p "${OC_PASS}" --insecure-skip-tls-verify=true; then
          echo "  [OK] Logged in as $(oc whoami)"
          echo ""
          return 0
        fi
      else
        echo "  No cluster URL found in kubeconfig."
        echo "  After IPI: export KUBECONFIG=$(cd "${_ENSURE_DIR}/.." && pwd)/cluster/auth/kubeconfig"
        echo "  Or run:  oc login <cluster-api-url>"
      fi
    fi
  fi

  echo ""
  echo "  ERROR: Not authenticated to OpenShift."
  echo "  After ./setup/01-install-cluster.sh:"
  echo "    export KUBECONFIG=$(cd "${_ENSURE_DIR}/.." && pwd)/cluster/auth/kubeconfig"
  echo "  Or: oc login <cluster-api-url>"
  exit 1
}

_ensure_oc_authenticated
