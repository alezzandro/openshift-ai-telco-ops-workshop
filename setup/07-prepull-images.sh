#!/bin/bash
# Pre-pull ModelCar + vLLM onto GPU nodes and Open WebUI onto general workers.
# Always run from full-setup.sh. Emergency skip: SKIP_PREPULL=1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [ "${SKIP_PREPULL:-0}" = "1" ]; then
  echo "=== SKIP_PREPULL=1 — image pre-pull disabled ==="
  echo "  First dashboard deploy will wait on ModelCar/vLLM pull."
  exit 0
fi

echo "=== Pre-pulling workshop images (default) ==="
echo ""

VLLM_IMAGE="$(detect_vllm_image)"
export VLLM_IMAGE OPEN_WEBUI_IMAGE
export MODELCAR_MINISTRAL_14B MODELCAR_QWEN_7B MODELCAR_QWEN_7B_W4A16
export MODELCAR_MISTRAL_24B_FP8 MODELCAR_MISTRAL_24B
echo "  vLLM image: ${VLLM_IMAGE}"
echo "  Open WebUI image: ${OPEN_WEBUI_IMAGE}"

oc create namespace workshop-prepull --dry-run=client -o yaml | oc apply -f -

# Init containers whose only job is to exist so the kubelet caches the image.
# The pause container is UBI micro so the pod can reach Ready.
PAUSE_IMAGE="registry.access.redhat.com/ubi9/ubi-minimal:latest"

gpu_init_containers() {
  python3 - <<'PY'
import json, os
images = [
    os.environ["VLLM_IMAGE"],
    os.environ["MODELCAR_MINISTRAL_14B"],
    os.environ["MODELCAR_QWEN_7B"],
    os.environ["MODELCAR_QWEN_7B_W4A16"],
    os.environ["MODELCAR_MISTRAL_24B_FP8"],
    os.environ["MODELCAR_MISTRAL_24B"],
]
out = []
for i, img in enumerate(images):
    safe = f"pull-{i}"
    out.append({
        "name": safe,
        "image": img,
        "imagePullPolicy": "IfNotPresent",
        "command": ["/bin/true"],
        "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}},
    })
print(json.dumps(out))
PY
}

apply_puller() {
  local name="$1"
  local selector_json="$2"
  local tolerations_json="$3"
  local inits_json="$4"

  PULLER_NAME="${name}" \
  PULLER_SELECTOR="${selector_json}" \
  PULLER_TOLERATIONS="${tolerations_json}" \
  PULLER_INITS="${inits_json}" \
  PULLER_PAUSE="${PAUSE_IMAGE}" \
  python3 - <<'PY' | oc apply -f -
import json, os
name = os.environ["PULLER_NAME"]
selector = json.loads(os.environ["PULLER_SELECTOR"])
tolerations = json.loads(os.environ["PULLER_TOLERATIONS"])
inits = json.loads(os.environ["PULLER_INITS"])
pause = os.environ["PULLER_PAUSE"]
doc = {
  "apiVersion": "apps/v1",
  "kind": "DaemonSet",
  "metadata": {
    "name": name,
    "namespace": "workshop-prepull",
    "labels": {"app": name},
  },
  "spec": {
    "selector": {"matchLabels": {"app": name}},
    "updateStrategy": {"type": "RollingUpdate"},
    "template": {
      "metadata": {"labels": {"app": name}},
      "spec": {
        "nodeSelector": selector,
        "tolerations": tolerations,
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
        "initContainers": inits,
        "containers": [{
          "name": "pause",
          "image": pause,
          "command": ["/bin/sleep", "infinity"],
          "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}},
        }],
      },
    },
  },
}
print(json.dumps(doc, indent=2))
PY
}

GPU_INITS="$(gpu_init_containers)"

echo "1. GPU-node puller (ModelCar + vLLM)..."
apply_puller \
  "prepull-gpu" \
  '{"node-role.kubernetes.io/worker-gpu":""}' \
  '[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]' \
  "${GPU_INITS}"

NOTEBOOK_IMAGE="$(detect_notebook_image)"
export NOTEBOOK_IMAGE OPENSHIFT_MCP_IMAGE S4_IMAGE
echo "  Workbench image: ${NOTEBOOK_IMAGE}"
echo "  OpenShift MCP image: ${OPENSHIFT_MCP_IMAGE}"
echo "  S4 image: ${S4_IMAGE}"
WORKER_INITS="$(python3 -c "import json,os; print(json.dumps([{'name':'pull-webui','image':os.environ['OPEN_WEBUI_IMAGE'],'imagePullPolicy':'IfNotPresent','command':['/bin/true'],'resources':{'requests':{'cpu':'10m','memory':'32Mi'}}},{'name':'pull-notebook','image':os.environ['NOTEBOOK_IMAGE'],'imagePullPolicy':'IfNotPresent','command':['/bin/true'],'resources':{'requests':{'cpu':'10m','memory':'32Mi'}}},{'name':'pull-openshift-mcp','image':os.environ['OPENSHIFT_MCP_IMAGE'],'imagePullPolicy':'IfNotPresent','command':['/bin/true'],'resources':{'requests':{'cpu':'10m','memory':'32Mi'}}},{'name':'pull-s4','image':os.environ['S4_IMAGE'],'imagePullPolicy':'IfNotPresent','command':['/bin/true'],'resources':{'requests':{'cpu':'10m','memory':'32Mi'}}}]))")"
echo "2. General-worker puller (Open WebUI + CPU workbench + OpenShift MCP + S4)..."
apply_puller \
  "prepull-workers" \
  '{"node-role.kubernetes.io/worker":""}' \
  '[]' \
  "${WORKER_INITS}"

puller_images_cached() {
  local app="$1"
  oc get pods -n workshop-prepull -l "app=${app}" -o json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
items = data.get("items") or []
if not items:
    sys.exit(1)
for pod in items:
    inits = pod.get("status", {}).get("initContainerStatuses") or []
    if not inits:
        sys.exit(1)
    for st in inits:
        waiting = (st.get("state") or {}).get("waiting") or {}
        if waiting.get("reason") in ("ErrImagePull", "ImagePullBackOff"):
            sys.exit(1)
        if not st.get("imageID"):
            sys.exit(1)
sys.exit(0)
'
}

echo ""
echo "3. Waiting for GPU puller image IDs (15–25 minutes on first run)..."
echo "  ModelCar images may not contain /bin/true; the kubelet still caches layers once imageID is set."
GPU_DS_DESIRED=$(oc get ds prepull-gpu -n workshop-prepull -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
if [ "${GPU_DS_DESIRED}" = "0" ]; then
  echo "  [WARN] prepull-gpu desiredNumberScheduled=0 (no worker-gpu node yet). Skipping GPU image wait."
  echo "         Re-run ./setup/07-prepull-images.sh after the GPU node is Ready."
else
  GPU_PULL_OK=0
  for i in $(seq 1 180); do
    if puller_images_cached prepull-gpu; then
      echo "  [OK] prepull-gpu images cached on scheduled GPU node(s)"
      GPU_PULL_OK=1
      break
    fi
    echo "  Attempt ${i}/180 — waiting for ModelCar/vLLM pull"
    sleep 10
  done
  if [ "${GPU_PULL_OK}" -ne 1 ]; then
    echo "  [WARN] GPU image IDs not all present yet. First dashboard deploy may still wait on pull."
  fi
fi

if puller_images_cached prepull-workers; then
  echo "  [OK] prepull-workers Open WebUI image cached"
else
  echo "  Worker puller still pulling Open WebUI (smaller image; setup continues)"
fi

echo ""
echo "=== Image pre-pull complete ==="
echo "  After scale-gpu.sh, this DaemonSet lands on new GPU nodes automatically."
