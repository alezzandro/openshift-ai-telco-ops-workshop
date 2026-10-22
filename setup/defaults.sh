# Shared pin values for this workshop. Sourced by setup scripts.
# shellcheck disable=SC2034

# GCP IPI (setup/01-install-cluster.sh). GPU workers are added later by 03-prereqs.
OCP_VERSION="${OCP_VERSION:-4.22.18}"
GCP_REGION="${GCP_REGION:-asia-southeast1}"
CLUSTER_NAME="${CLUSTER_NAME:-ocp}"
CONTROL_PLANE_TYPE="${CONTROL_PLANE_TYPE:-n2-standard-4}"
CONTROL_PLANE_DISK="${CONTROL_PLANE_DISK:-120}"
COMPUTE_TYPE="${COMPUTE_TYPE:-n2-standard-8}"
COMPUTE_DISK="${COMPUTE_DISK:-120}"
COMPUTE_REPLICAS="${COMPUTE_REPLICAS:-2}"
GCP_DISK_TYPE="${GCP_DISK_TYPE:-pd-ssd}"

# Presenter 4-L4 node (rehearsal). Students: 2-L4 nodes via scale-students.sh.
GPU_4L4_TYPE="${GPU_4L4_TYPE:-g2-standard-48}"
GPU_4L4_REPLICAS="${GPU_4L4_REPLICAS:-1}"
GPU_4L4_MAX="${GPU_4L4_MAX:-1}"
GPU_4L4_COUNT="${GPU_4L4_COUNT:-4}"
GPU_2L4_TYPE="${GPU_2L4_TYPE:-g2-standard-24}"
GPU_2L4_REPLICAS="${GPU_2L4_REPLICAS:-0}"
GPU_2L4_MAX="${GPU_2L4_MAX:-3}"
GPU_2L4_COUNT="${GPU_2L4_COUNT:-2}"
GPU_VOLUME_SIZE="${GPU_VOLUME_SIZE:-250}"
GPU_AZ="${GPU_AZ:-}"

# Rehearsal L4 quota preflight (class scale needs 10).
GCP_L4_QUOTA_REHEARSAL="${GCP_L4_QUOTA_REHEARSAL:-4}"
GCP_L4_QUOTA_CLASS="${GCP_L4_QUOTA_CLASS:-10}"

OPEN_WEBUI_IMAGE="${OPEN_WEBUI_IMAGE:-ghcr.io/open-webui/open-webui:v0.6.36}"
VLLM_IMAGE_FALLBACK="${VLLM_IMAGE_FALLBACK:-registry.redhat.io/rhaiis/vllm-cuda-rhel9:3.3.0}"

MODELCAR_MINISTRAL_14B="${MODELCAR_MINISTRAL_14B:-registry.redhat.io/rhai/modelcar-ministral-3-14b-instruct-2512:3.0}"
MODELCAR_QWEN_7B="${MODELCAR_QWEN_7B:-registry.redhat.io/rhelai1/modelcar-qwen2-5-7b-instruct:1.5}"
MODELCAR_QWEN_7B_W4A16="${MODELCAR_QWEN_7B_W4A16:-registry.redhat.io/rhelai1/modelcar-qwen2-5-7b-instruct-quantized-w4a16:1.5}"
MODELCAR_MISTRAL_24B_FP8="${MODELCAR_MISTRAL_24B_FP8:-registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503-fp8-dynamic:1.5}"
MODELCAR_MISTRAL_24B="${MODELCAR_MISTRAL_24B:-registry.redhat.io/rhelai1/modelcar-mistral-small-3-1-24b-instruct-2503:1.5}"

DS_PROJECTS="${DS_PROJECTS:-telco-ops-demo telco-ran-ai telco-core-ai}"
PRESENTER_PROJECT="${PRESENTER_PROJECT:-telco-ops-demo}"
WORKBENCH_PROJECT="${WORKBENCH_PROJECT:-telco-ops-notebooks}"
WORKBENCH_NAME="${WORKBENCH_NAME:-cpu-langchain}"
WORKBENCH_GIT_REPO="${WORKBENCH_GIT_REPO:-https://github.com/rh-aiservices-bu/llm-on-openshift.git}"
WORKBENCH_NOTEBOOK_REL="${WORKBENCH_NOTEBOOK_REL:-examples/notebooks/langchain/Langchain-vLLM-Prompt-memory.ipynb}"
NOTEBOOK_IMAGE_FALLBACK="${NOTEBOOK_IMAGE_FALLBACK:-image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/s2i-generic-data-science-notebook:3.5}"

MODEL_REGISTRY_NAME="${MODEL_REGISTRY_NAME:-workshop}"
MODEL_REGISTRY_NS="${MODEL_REGISTRY_NS:-rhoai-model-registries}"
MCP_SERVER_NAME="${MCP_SERVER_NAME:-openshift-mcp-server}"
# Catalog artifact: oci://registry.redhat.io/openshift-mcp-tech-preview/openshift-mcp-server-rhel9:0.4
OPENSHIFT_MCP_IMAGE="${OPENSHIFT_MCP_IMAGE:-registry.redhat.io/openshift-mcp-tech-preview/openshift-mcp-server-rhel9:0.4}"

# S4 (rh-aiservices-bu) is a demo S3 stand-in — not enterprise object storage.
# Pin a version tag; never :latest. https://github.com/rh-aiservices-bu/s4
S4_IMAGE="${S4_IMAGE:-quay.io/rh-aiservices-bu/s4:0.3.2-2}"
S4_NS="${S4_NS:-s4}"
S4_BUCKET="${S4_BUCKET:-models}"
S4_CONNECTION_NAME="${S4_CONNECTION_NAME:-workshop-s4-models}"
HF_C4_REPO="${HF_C4_REPO:-Qwen/Qwen2.5-7B-Instruct}"
HF_C4_PREFIX="${HF_C4_PREFIX:-qwen2.5-7b-instruct}"
HF_C4B_REPO="${HF_C4B_REPO:-ibm-granite/granite-3.3-2b-instruct}"
HF_C4B_IS="${HF_C4B_IS:-modelcar-granite-3-3-2b-instruct}"
HF_C4B_TAG="${HF_C4B_TAG:-workshop}"

LEGO_VERSION="${LEGO_VERSION:-v4.25.2}"

CREDS_FILE="${CREDS_FILE:-}"
