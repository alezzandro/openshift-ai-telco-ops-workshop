#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=env-tools.sh
source "${SCRIPT_DIR}/env-tools.sh"

echo "============================================"
echo "  OpenShift AI Telco Operations Workshop"
echo "============================================"
echo "  Presenter minimum: tools + GCP IPI + access + 1× 4-L4 + operators + apps."
echo "  Student 2-L4 nodes: ./setup/scale-students.sh (not this script)."
echo ""
if [ "${SKIP_PREPULL:-0}" = "1" ]; then
  echo "WARNING: SKIP_PREPULL=1 — first dashboard deploy will stall on ModelCar/vLLM pull."
  echo ""
fi

run_step() {
  local script="$1"
  local name
  name=$(basename "${script}" .sh)
  echo ""
  echo "============================================"
  echo "  Running: ${name}"
  echo "============================================"
  bash "${script}"
  echo ""
  echo "  ${name} completed."
  echo ""
}

run_step "${SCRIPT_DIR}/00-install-tools.sh"

KUBECONFIG_PATH="${REPO_ROOT}/cluster/auth/kubeconfig"
if [ -f "${KUBECONFIG_PATH}" ] && KUBECONFIG="${KUBECONFIG_PATH}" oc whoami >/dev/null 2>&1; then
  echo "Skipping 01-install-cluster.sh (cluster/auth/kubeconfig already works)."
  export KUBECONFIG="${KUBECONFIG_PATH}"
else
  run_step "${SCRIPT_DIR}/01-install-cluster.sh"
  export KUBECONFIG="${KUBECONFIG_PATH}"
fi

run_step "${SCRIPT_DIR}/02-configure-access.sh"
run_step "${SCRIPT_DIR}/03-prereqs.sh"
run_step "${SCRIPT_DIR}/04-install-operators.sh"

echo "Waiting 60 seconds for operators to stabilize..."
sleep 60

run_step "${SCRIPT_DIR}/05-configure-gpu.sh"
run_step "${SCRIPT_DIR}/06-configure-rhoai.sh"
run_step "${SCRIPT_DIR}/07-prepull-images.sh"
run_step "${SCRIPT_DIR}/08-deploy-open-webui.sh"
run_step "${SCRIPT_DIR}/09-deploy-workbench.sh"
run_step "${SCRIPT_DIR}/10-deploy-registry-mcp.sh"
run_step "${SCRIPT_DIR}/11-deploy-lab-guide.sh"
run_step "${SCRIPT_DIR}/12-deploy-s4.sh"

echo ""
echo "============================================"
echo "  Setup complete (presenter rehearsal, including S4 demo object storage)"
echo "============================================"
echo ""
echo "Next:"
echo "  ./setup/show-credentials.sh"
echo "  Open the lab guide Route (printed first)."
echo "  Register models in Model Registry workshop, then deploy those versions from the dashboard — none were pre-created."
echo "  Class day: ./setup/scale-students.sh"
echo ""
