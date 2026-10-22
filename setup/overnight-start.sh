#!/bin/bash
# Morning: start GCP VMs, restore Machine API, then scale GPU pools independently.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env-tools.sh
source "${SCRIPT_DIR}/env-tools.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=lib-gcp.sh
source "${SCRIPT_DIR}/lib-gcp.sh"

R4=""
R2=""
STUDENTS=0
usage() {
  cat <<EOF
Usage: $0 [--4l4 N] [--2l4 N] [--students]

Default GPU counts are GPU_4L4_LAST_REPLICAS / GPU_2L4_LAST_REPLICAS
from setup/.generated-credentials.env (presenter rehearsal: 1 and 0).

  --4l4 N      presenter g2-standard-48 replicas (0 or 1)
  --2l4 N      student g2-standard-24 replicas (0–3)
  --students   same as --4l4 1 --2l4 3

Examples:
  $0
  $0 --4l4 1
  $0 --students
  $0 --4l4 1 --2l4 0
  $0 --4l4 1 --2l4 3
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --4l4) R4="${2:-}"; shift 2 ;;
    --2l4) R2="${2:-}"; shift 2 ;;
    --students) STUDENTS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

load_gcp_credentials
gcp_activate

CLUSTER_DIR="$(workshop_cluster_dir)"
KUBECONFIG_PATH="${CLUSTER_DIR}/auth/kubeconfig"
if [ ! -f "${KUBECONFIG_PATH}" ]; then
  echo "  ERROR: ${KUBECONFIG_PATH} is missing." >&2
  exit 1
fi
export KUBECONFIG="${KUBECONFIG_PATH}"

INFRA="$(cluster_infra_id)"
if [ -z "${INFRA}" ]; then
  echo "  ERROR: could not determine installer infra ID." >&2
  exit 1
fi

api_url() {
  python3 - "${KUBECONFIG_PATH}" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
for line in text.splitlines():
    s = line.strip()
    if s.startswith("server:"):
        print(s.split(":", 1)[1].strip().strip('"').strip("'"))
        break
PY
}

instance_role() {
  local name="$1"
  local lname="${name,,}"
  if [[ "${lname}" == *bootstrap* ]]; then
    echo skip
  elif [[ "${lname}" == *master* ]] || [[ "${lname}" == *control-plane* ]]; then
    echo master
  elif [[ "${lname}" == *gpu* ]]; then
    echo gpu
  elif [[ "${lname}" == *worker* ]]; then
    echo worker
  else
    echo skip
  fi
}

start_role() {
  local want="$1"
  local started=0
  while IFS=$'\t' read -r name zone status mtype; do
    [ -n "${name}" ] || continue
    local role
    role="$(instance_role "${name}")"
    if [ "${role}" != "${want}" ]; then
      continue
    fi
    if [ "${status}" = "RUNNING" ]; then
      echo "  already running ${name}"
      continue
    fi
    echo "  starting ${name} in ${zone} (${mtype}, was ${status})..."
    gcloud compute instances start "${name}" --zone="${zone}" --project="${GCP_PROJECT}" --quiet
    started=$((started + 1))
  done < <(gcp_list_cluster_instances "${INFRA}")
  echo "  started ${started} ${want} instance(s)"
}

echo "=== Overnight start ==="
echo "  infraID: ${INFRA}"
echo ""

echo "1. Start masters, wait for API /healthz..."
start_role master
API="$(api_url)"
if [ -z "${API}" ]; then
  echo "  ERROR: no server URL in kubeconfig." >&2
  exit 1
fi
OK=0
for i in $(seq 1 60); do
  CODE="$(curl -sk --max-time 8 "${API}/healthz" 2>/dev/null || true)"
  if [ "${CODE}" = "ok" ]; then
    echo "  [OK] API /healthz after $((i * 10))s"
    OK=1
    break
  fi
  echo "  ... API not ready (${i}/60)"
  sleep 10
done
if [ "${OK}" -ne 1 ]; then
  echo "  ERROR: API /healthz did not return ok." >&2
  exit 1
fi
echo ""

echo "2. Start workers, wait Ready..."
start_role worker
wait_for_ready_nodes "node-role.kubernetes.io/worker" "${COMPUTE_REPLICAS}" "general worker" 900 || true
echo ""

echo "3. Restore Machine API..."
MAC="$(get_cred MACHINE_API_LAST_REPLICAS || echo 1)"
[[ "${MAC}" =~ ^[1-9][0-9]*$ ]] || MAC=1
oc scale deploy/machine-api-controllers -n openshift-machine-api --replicas="${MAC}"
oc rollout status deploy/machine-api-controllers -n openshift-machine-api --timeout=300s || true
echo "  [OK] machine-api-controllers replicas=${MAC}"
echo ""

echo "3b. Playground OGX token refs (C3 SA secret is gone after overnight-stop)..."
relax_ogx_missing_token_refs
OGX_DEG="$(oc get ogx default-ogx -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || true)"
if [ "${OGX_DEG}" = "True" ]; then
  echo "  Restarting ogx-k8s-operator (stale UnhealthyOGXServers after overnight-stop)..."
  oc rollout restart deploy/ogx-k8s-operator-controller-manager -n redhat-ods-applications >/dev/null || true
  oc rollout status deploy/ogx-k8s-operator-controller-manager -n redhat-ods-applications --timeout=180s || true
fi
echo ""

if [ "${STUDENTS}" -eq 1 ]; then
  R4="${R4:-1}"
  R2="${R2:-3}"
fi
if [ -z "${R4}" ]; then
  R4="$(get_cred GPU_4L4_LAST_REPLICAS || echo "${GPU_4L4_REPLICAS}")"
fi
if [ -z "${R2}" ]; then
  R2="$(get_cred GPU_2L4_LAST_REPLICAS || echo "${GPU_2L4_REPLICAS}")"
fi
[[ "${R4}" =~ ^[0-9]+$ ]] || R4=1
[[ "${R2}" =~ ^[0-9]+$ ]] || R2=0

echo "4. Scale GPU pools (--4l4 ${R4} --2l4 ${R2})..."
bash "${SCRIPT_DIR}/scale-gpu.sh" --4l4 "${R4}" --2l4 "${R2}"
echo ""

echo "5. Wait for NFD / GPU Operator allocatable counts..."
bash "${SCRIPT_DIR}/05-configure-gpu.sh" || true
echo ""

echo "6. Health check..."
bash "${SCRIPT_DIR}/health-check.sh"
echo ""
echo "=== Overnight start complete ==="
echo "  ./setup/show-credentials.sh"
