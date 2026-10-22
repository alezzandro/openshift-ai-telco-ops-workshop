#!/bin/bash
# Wipe workshop InferenceServices. Keep operators, GPU MachineSet, Open WebUI accounts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

RESET_WEBUI=0
if [ "${1:-}" = "--reset-webui" ]; then
  RESET_WEBUI=1
fi

echo "=== Reset workshop artifacts ==="
echo ""

echo "1. Deleting InferenceServices, LLMInferenceServices, and leftover PVCs in workshop projects..."
for ns in ${DS_PROJECTS}; do
  oc delete inferenceservice --all -n "${ns}" --wait=false 2>/dev/null || true
  oc delete llminferenceservice --all -n "${ns}" --wait=false 2>/dev/null || true
  oc delete pvc --all -n "${ns}" --wait=false 2>/dev/null || true
  echo "  [OK] ${ns}"
done
echo ""

echo "2. Uncordoning any accidentally cordoned workers..."
oc get nodes --no-headers 2>/dev/null | awk '$2 ~ /SchedulingDisabled/ {print $1}' \
  | while read -r n; do
      [ -n "${n}" ] || continue
      oc adm uncordon "${n}" || true
    done
echo ""

echo "3. Force-deleting leftover Failed predictor pods..."
force_delete_failed_predictors
echo ""

if [ "${RESET_WEBUI}" -eq 1 ]; then
  echo "4. --reset-webui: deleting Open WebUI PVC (admin and student accounts go away)..."
  oc delete deploy open-webui -n open-webui --wait=false 2>/dev/null || true
  oc delete pvc open-webui-pvc -n open-webui --wait=true 2>/dev/null || true
  echo "  Re-run ./setup/08-deploy-open-webui.sh to recreate admin."
else
  echo "4. Keeping Open WebUI PVC (accounts preserved). Use --reset-webui to wipe chat."
fi

echo ""
echo "=== Reset complete ==="
echo "  Operators, HardwareProfiles, Kueue, CPU workbench, Model Registry, MCP server, lab guide, GPU MachineSet unchanged."
