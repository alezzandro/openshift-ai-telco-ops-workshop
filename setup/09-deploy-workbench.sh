#!/bin/bash
# CPU Jupyter workbench in a non-Kueue Data Science Project, with Red Hat
# llm-on-openshift example notebooks cloned onto the workbench PVC.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WB_DIR="${REPO_ROOT}/manifests/workbench"
PROJ_DIR="${REPO_ROOT}/manifests/projects"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${WORKBENCH_PROJECT}"
NB="${WORKBENCH_NAME}"
NOTEBOOK_FILE="llm-on-openshift/${WORKBENCH_NOTEBOOK_REL}"

echo "=== Deploying CPU workbench (${NS}/${NB}) ==="
echo ""

echo "1. Data Science Project (no Kueue LocalQueue)..."
oc apply -f "${PROJ_DIR}/namespaces.yaml"
oc apply -f "${PROJ_DIR}/resourcequotas.yaml"
oc apply -f "${PROJ_DIR}/networkpolicies.yaml"
echo ""

echo "2. Workbench PVC and ServiceAccounts (anyuid — Jupyter UID 1001)..."
oc apply -f "${WB_DIR}/sa.yaml"
oc apply -f "${WB_DIR}/pvc.yaml"
echo ""

NOTEBOOK_IMAGE="$(detect_notebook_image)"
IMAGE_DISPLAY="$(notebook_image_display_name)"
DASHBOARD_HOST="$(rhoai_dashboard_host)"
DASHBOARD_URL=""
[ -n "${DASHBOARD_HOST}" ] && DASHBOARD_URL="https://${DASHBOARD_HOST}"
echo "  Notebook image: ${NOTEBOOK_IMAGE}"
echo "  Dashboard: ${DASHBOARD_URL:-unknown}"
echo ""

notebooks_present() {
  local pod
  pod="$(oc get pod -n "${NS}" -l "notebook-name=${NB}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "${pod}" ] || return 1
  oc exec -n "${NS}" "${pod}" -c "${NB}" -- \
    test -f "/opt/app-root/src/${NOTEBOOK_FILE}" >/dev/null 2>&1
}

stop_notebook() {
  oc patch notebook "${NB}" -n "${NS}" --type merge \
    -p '{"metadata":{"annotations":{"kubeflow-resource-stopped":"true"}}}' \
    >/dev/null 2>&1 || true
  for _ in $(seq 1 36); do
    local phase
    phase="$(oc get pods -n "${NS}" -l "notebook-name=${NB}" --no-headers 2>/dev/null | awk '{print $3}' | head -1 || true)"
    [ -z "${phase}" ] && return 0
    sleep 5
  done
}

start_notebook() {
  oc annotate notebook "${NB}" -n "${NS}" kubeflow-resource-stopped- --overwrite >/dev/null 2>&1 || true
}

run_clone_job() {
  echo "3. Cloning ${WORKBENCH_GIT_REPO} onto the PVC..."
  oc delete job clone-llm-on-openshift -n "${NS}" --ignore-not-found >/dev/null
  oc create configmap workbench-seed -n "${NS}" \
    --from-file=START-HERE.md="${WB_DIR}/START-HERE.md" \
    --dry-run=client -o yaml | oc apply -f -

  CLONE_IMAGE="${NOTEBOOK_IMAGE}" \
  CLONE_REPO="${WORKBENCH_GIT_REPO}" \
  CLONE_NS="${NS}" \
  python3 - <<'PY' | oc apply -f -
import json, os
ns = os.environ["CLONE_NS"]
image = os.environ["CLONE_IMAGE"]
repo = os.environ["CLONE_REPO"]
doc = {
  "apiVersion": "batch/v1",
  "kind": "Job",
  "metadata": {"name": "clone-llm-on-openshift", "namespace": ns},
  "spec": {
    "backoffLimit": 3,
    "template": {
      "spec": {
        "restartPolicy": "OnFailure",
        "serviceAccountName": "clone-notebooks",
        "securityContext": {"runAsUser": 0, "fsGroup": 0},
        "affinity": {
          "nodeAffinity": {
            "requiredDuringSchedulingIgnoredDuringExecution": {
              "nodeSelectorTerms": [{
                "matchExpressions": [{
                  "key": "node-role.kubernetes.io/control-plane",
                  "operator": "DoesNotExist",
                }]
              }]
            }
          }
        },
        "containers": [{
          "name": "clone",
          "image": image,
          "imagePullPolicy": "IfNotPresent",
          "command": ["/bin/bash", "-lc"],
          "args": ["""
set -euo pipefail
DEST=/opt/app-root/src
REPO_DIR="${DEST}/llm-on-openshift"
mkdir -p "${DEST}"
if [ ! -f "${REPO_DIR}/examples/notebooks/langchain/Langchain-vLLM-Prompt-memory.ipynb" ]; then
  rm -rf "${REPO_DIR}"
  git clone --depth 1 "${CLONE_REPO}" "${REPO_DIR}"
fi
if [ -f /workshop/START-HERE.md ]; then
  cp /workshop/START-HERE.md "${DEST}/START-HERE.md"
fi
# Jupyter in the workbench image runs as UID 1001 / GID 0.
chown -R 1001:0 "${DEST}" || true
chmod -R ugo+rwX "${DEST}" || true
echo "=== workbench home ==="
ls -la "${DEST}"
ls -la "${REPO_DIR}/examples/notebooks/langchain" | head
"""],
          "env": [{"name": "CLONE_REPO", "value": repo}],
          "resources": {
            "requests": {"cpu": "100m", "memory": "256Mi"},
            "limits": {"cpu": "1", "memory": "1Gi"},
          },
          "volumeMounts": [
            {"name": "src", "mountPath": "/opt/app-root/src"},
            {"name": "seed", "mountPath": "/workshop", "readOnly": True},
          ],
        }],
        "volumes": [
          {"name": "src", "persistentVolumeClaim": {"claimName": "cpu-langchain"}},
          {"name": "seed", "configMap": {"name": "workbench-seed"}},
        ],
      }
    }
  }
}
print(json.dumps(doc, indent=2))
PY

  echo "  Waiting for clone job (needs egress to github.com)..."
  if oc wait job/clone-llm-on-openshift -n "${NS}" --for=condition=complete --timeout=600s; then
    echo "  [OK] Notebooks cloned"
  else
    echo "  [FAIL] git clone did not complete. Job log:"
    oc logs job/clone-llm-on-openshift -n "${NS}" --tail=80 || true
    exit 1
  fi
}

if oc get notebook "${NB}" -n "${NS}" >/dev/null 2>&1 && notebooks_present; then
  echo "3. Red Hat notebooks already on the workbench PVC — skipping clone"
elif oc get notebook "${NB}" -n "${NS}" >/dev/null 2>&1; then
  echo "3. Stopping workbench so the RWO PVC can be seeded..."
  stop_notebook
  run_clone_job
  start_notebook
else
  run_clone_job
fi

echo "   Refreshing START-HERE.md..."
oc create configmap workbench-seed -n "${NS}" \
  --from-file=START-HERE.md="${WB_DIR}/START-HERE.md" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
SEED_POD="$(oc get pod -n "${NS}" -l "notebook-name=${NB}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "${SEED_POD}" ]; then
  if oc exec -i -n "${NS}" "${SEED_POD}" -c "${NB}" -- \
      tee /opt/app-root/src/START-HERE.md >/dev/null < "${WB_DIR}/START-HERE.md"; then
    echo "  [OK] START-HERE.md on workbench PVC"
  else
    echo "  [WARN] Could not write START-HERE.md into ${SEED_POD}"
  fi
fi
echo ""

echo "4. Applying Notebook CR (CPU only HardwareProfile)..."
TMP_NB="$(mktemp)"
NOTEBOOK_IMAGE="${NOTEBOOK_IMAGE}" DASHBOARD_URL="${DASHBOARD_URL}" IMAGE_DISPLAY="${IMAGE_DISPLAY}" \
TEMPLATE="${WB_DIR}/notebook.yaml" python3 - <<'PY' > "${TMP_NB}"
import os
text = open(os.environ["TEMPLATE"], encoding="utf-8").read()
text = text.replace("__NOTEBOOK_IMAGE__", os.environ.get("NOTEBOOK_IMAGE", ""))
text = text.replace("__DASHBOARD_URL__", os.environ.get("DASHBOARD_URL", ""))
text = text.replace("__IMAGE_DISPLAY_NAME__", os.environ.get("IMAGE_DISPLAY", ""))
print(text, end="")
PY
oc apply -f "${TMP_NB}"
rm -f "${TMP_NB}"
# Drop the 2.x inject-oauth annotation if a previous run left it on the CR.
oc annotate notebook "${NB}" -n "${NS}" notebooks.opendatahub.io/inject-oauth- --overwrite >/dev/null 2>&1 || true
start_notebook
echo ""

echo "5. Waiting for workbench pod..."
READY=0
for i in $(seq 1 60); do
  PHASE="$(oc get pods -n "${NS}" -l "notebook-name=${NB}" --no-headers 2>/dev/null | awk '{print $3}' | head -1 || true)"
  if [ "${PHASE}" = "Running" ]; then
    if notebooks_present || oc get pod -n "${NS}" -l "notebook-name=${NB}" \
      -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
      READY=1
      echo "  [OK] Workbench pod Running"
      break
    fi
  fi
  echo "  Attempt ${i}/60 — pod ${PHASE:-Pending}"
  sleep 10
done
if [ "${READY}" -ne 1 ]; then
  echo "  [WARN] Workbench not Ready yet. Image may still be pulling."
  oc get pods -n "${NS}" -o wide || true
fi

echo ""
echo "=== CPU workbench ready ==="
echo "  Project:  ${NS}  (not Kueue-managed — CPU HardwareProfile is visible here)"
echo "  Notebook: ${NB}"
echo "  Open from OpenShift AI → ${NS} → Workbenches → click CPU LangChain examples"
echo "  Then open START-HERE.md and ${NOTEBOOK_FILE}"
echo "  Source: ${WORKBENCH_GIT_REPO}"
