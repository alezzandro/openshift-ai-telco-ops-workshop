#!/bin/bash
# Install a base OpenShift 4.22 cluster on the GCP sandbox (IPI).
# GPU workers are NOT part of this install — setup/03-prereqs.sh clones
# g2-standard-48 / g2-standard-24 MachineSets after the cluster is up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=env-tools.sh
source "${SCRIPT_DIR}/env-tools.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib-gcp.sh
source "${SCRIPT_DIR}/lib-gcp.sh"

FORCE=0
usage() {
  cat <<EOF
Usage: $0 [--force]

Install OpenShift ${OCP_VERSION:-4.22.18} on GCP IPI in ${GCP_REGION}.

Credentials (gitignored, never printed):
  private/credentials/gcp-credentials.txt
  private/credentials/rh-pull-secret.txt

Options:
  --force   Continue when NVIDIA_L4 quota is below ${GCP_L4_QUOTA_REHEARSAL}
  --help    Show this help

Environment:
  CLUSTER_NAME            default: ocp
  GCP_BASE_DOMAIN         override Cloud DNS zone from the credentials file
  GCP_REGION_OVERRIDE=1   allow a region other than ${GCP_REGION}
  OCP_VERSION             default: 4.22.18
  CLUSTER_REGEN_CONFIG=1  rewrite cluster/install-config.yaml
EOF
}

for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: ${arg}" >&2; usage; exit 1 ;;
  esac
done

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "  ERROR: '$1' not found. Run ./setup/00-install-tools.sh" >&2
    exit 1
  fi
}

echo "=== OpenShift GCP IPI ==="
echo ""

need_cmd gcloud
need_cmd jq
need_cmd python3
need_cmd openshift-install
need_cmd oc
need_cmd ssh-keygen

load_gcp_credentials
assert_gcp_region
gcp_activate

CLUSTER_DIR="$(workshop_cluster_dir)"
CLUSTER_NAME="${CLUSTER_NAME:-ocp}"
mkdir -p "${CLUSTER_DIR}"
chmod 700 "${CLUSTER_DIR}"

PULL_SECRET_FILE="$(workshop_pull_secret_file)"
if [ ! -f "${PULL_SECRET_FILE}" ]; then
  echo "  ERROR: pull secret not found: ${PULL_SECRET_FILE}" >&2
  exit 1
fi
python3 - "${PULL_SECRET_FILE}" <<'PY'
import json, sys
from pathlib import Path
raw = Path(sys.argv[1]).read_text().strip()
if not raw:
    sys.stderr.write("  ERROR: pull secret file is empty\n")
    sys.exit(1)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.stderr.write("  ERROR: pull secret is not JSON\n")
    sys.exit(1)
if "auths" not in data:
    sys.stderr.write("  ERROR: pull secret JSON has no auths map\n")
    sys.exit(1)
print("  [OK] pull secret JSON looks valid")
PY

if [ -z "${GCP_BASE_DOMAIN:-}" ]; then
  echo "  ERROR: could not parse Cloud DNS base domain from the credentials file." >&2
  echo "         Set GCP_BASE_DOMAIN to the existing Cloud DNS zone from the credentials dump." >&2
  exit 1
fi

ensure_cluster_ssh_key
SSH_PUB="$(workshop_ssh_key).pub"

echo "  Cluster:     ${CLUSTER_NAME}.${GCP_BASE_DOMAIN}"
echo "  Project:     ${GCP_PROJECT}"
echo "  Region:      ${GCP_REGION}"
echo "  Control:     3 × ${CONTROL_PLANE_TYPE} (${CONTROL_PLANE_DISK} GiB ${GCP_DISK_TYPE})"
echo "  Compute:     ${COMPUTE_REPLICAS} × ${COMPUTE_TYPE} (${COMPUTE_DISK} GiB ${GCP_DISK_TYPE})"
echo "  GPU worker:  added later by setup/03-prereqs.sh (${GPU_4L4_TYPE} × ${GPU_4L4_REPLICAS})"
echo ""

echo "1. GCP identity..."
ACCOUNT="$(gcloud config get-value account 2>/dev/null || echo "${GCP_SA_EMAIL}")"
echo "  [OK] ${ACCOUNT} project ${GCP_PROJECT} region ${GCP_REGION}"
echo ""

echo "2. Cloud DNS zone for ${GCP_BASE_DOMAIN}..."
assert_public_dns_zone
echo ""

echo "3. G2 machine types in ${GCP_REGION}..."
G2_ZONES="$(gcloud compute machine-types list \
  --filter="name=${GPU_4L4_TYPE} AND zone:${GCP_REGION}" \
  --format='value(zone)' --project="${GCP_PROJECT}" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
if [ -z "${G2_ZONES}" ]; then
  echo "  ERROR: ${GPU_4L4_TYPE} is not listed in ${GCP_REGION}." >&2
  exit 1
fi
FIRST_G2_ZONE="$(echo "${G2_ZONES}" | awk '{print $1}')"
echo "  [OK] offered in: ${G2_ZONES}"
echo "  Default GPU_AZ for 03-prereqs: ${FIRST_G2_ZONE}"
echo "  (Offering ≠ live stock. If launch fails: ./setup/switch-gpu-az.sh --try ${G2_ZONES// /,})"
printf '%s\n' "${FIRST_G2_ZONE}" > "${CLUSTER_DIR}/.gpu-az"
printf '%s\n' "${G2_ZONES}" > "${CLUSTER_DIR}/.gpu-azs"
echo ""

echo "4. NVIDIA_L4 quota in ${GCP_REGION} (need ≥ ${GCP_L4_QUOTA_REHEARSAL} for rehearsal)..."
if ! preflight_l4_quota "${GCP_L4_QUOTA_REHEARSAL}"; then
  if [ "${FORCE}" -ne 1 ]; then
    echo "  ERROR: refusing to install. Re-run with --force to override." >&2
    exit 1
  fi
  echo "  --force set; continuing."
else
  echo "  [OK] quota is enough for the presenter 4-L4 node"
fi
echo ""

if [ -f "${CLUSTER_DIR}/metadata.json" ]; then
  echo "  [OK] ${CLUSTER_DIR}/metadata.json already exists — installer will resume or no-op."
  echo "       Destroy first with ./setup/destroy-cluster.sh if you want a new cluster."
fi

write_install_config() {
  local out="${CLUSTER_DIR}/install-config.yaml"
  if [ -f "${out}" ] && [ "${CLUSTER_REGEN_CONFIG:-0}" != "1" ]; then
    echo "  [OK] keeping existing ${out} (set CLUSTER_REGEN_CONFIG=1 to rewrite)"
    return 0
  fi
  CLUSTER_DIR_OUT="${CLUSTER_DIR}" \
  PULL_SECRET_FILE="${PULL_SECRET_FILE}" \
  SSH_PUB="${SSH_PUB}" \
  BASE_DOMAIN="${GCP_BASE_DOMAIN}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  REGION="${GCP_REGION}" \
  PROJECT="${GCP_PROJECT}" \
  CP_TYPE="${CONTROL_PLANE_TYPE}" \
  CP_DISK="${CONTROL_PLANE_DISK}" \
  W_TYPE="${COMPUTE_TYPE}" \
  W_DISK="${COMPUTE_DISK}" \
  W_REPLICAS="${COMPUTE_REPLICAS}" \
  DISK_TYPE="${GCP_DISK_TYPE}" \
  python3 - <<'PY'
import json, os, pathlib
pull = pathlib.Path(os.environ["PULL_SECRET_FILE"]).read_text().strip()
json.loads(pull)
ssh = pathlib.Path(os.environ["SSH_PUB"]).read_text().strip()

def yaml_quote(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"

cfg = f"""apiVersion: v1
baseDomain: {os.environ["BASE_DOMAIN"]}
credentialsMode: Passthrough
metadata:
  name: {os.environ["CLUSTER_NAME"]}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    gcp:
      type: {os.environ["W_TYPE"]}
      osDisk:
        diskSizeGB: {int(os.environ["W_DISK"])}
        diskType: {os.environ["DISK_TYPE"]}
  replicas: {int(os.environ["W_REPLICAS"])}
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    gcp:
      type: {os.environ["CP_TYPE"]}
      osDisk:
        diskSizeGB: {int(os.environ["CP_DISK"])}
        diskType: {os.environ["DISK_TYPE"]}
  replicas: 3
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  gcp:
    projectID: {os.environ["PROJECT"]}
    region: {os.environ["REGION"]}
publish: External
pullSecret: {yaml_quote(pull)}
sshKey: {yaml_quote(ssh)}
"""
out = pathlib.Path(os.environ["CLUSTER_DIR_OUT"]) / "install-config.yaml"
out.write_text(cfg)
out.chmod(0o600)
print(f"  [OK] wrote {out}")
PY
}

echo "5. install-config.yaml..."
write_install_config
echo ""

# RHPDS Open Environment SAs are Owner of the cluster project but the key's
# project_id is the host project. CCO Passthrough then fails
# openshift-image-registry-gcs with "root creds do not have enough
# permissions" even though GCS create/delete works. Copy the installer
# gcp-credentials secret so the registry operator can create its bucket.
copy_image_registry_gcp_creds() {
  if ! oc get secret gcp-credentials -n kube-system >/dev/null 2>&1; then
    echo "  [WARN] kube-system/gcp-credentials missing; cannot seed image-registry"
    return 1
  fi
  python3 - <<'PY' | oc apply -f -
import json, subprocess
src = json.loads(subprocess.check_output(
    ["oc", "get", "secret", "gcp-credentials", "-n", "kube-system", "-o", "json"],
    text=True,
))
doc = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": "installer-cloud-credentials",
        "namespace": "openshift-image-registry",
    },
    "type": src.get("type") or "Opaque",
    "data": src.get("data") or {},
}
print(json.dumps(doc))
PY
  echo "  [OK] seeded openshift-image-registry/installer-cloud-credentials from kube-system/gcp-credentials"
}

echo "6. openshift-install create cluster (30–45 minutes)..."
echo "   Log: ${CLUSTER_DIR}/.openshift_install.log"
export GOOGLE_APPLICATION_CREDENTIALS
INSTALL_RC=0
openshift-install create cluster --dir "${CLUSTER_DIR}" --log-level=info || INSTALL_RC=$?

KUBECONFIG_PATH="${CLUSTER_DIR}/auth/kubeconfig"
if [ ! -f "${KUBECONFIG_PATH}" ]; then
  echo "  ERROR: installer finished but ${KUBECONFIG_PATH} is missing (exit ${INSTALL_RC})." >&2
  exit 1
fi
chmod 600 "${KUBECONFIG_PATH}" "${CLUSTER_DIR}/auth/kubeadmin-password" 2>/dev/null || true
export KUBECONFIG="${KUBECONFIG_PATH}"

if [ "${INSTALL_RC}" -ne 0 ]; then
  echo "  [WARN] openshift-install create cluster exited ${INSTALL_RC}; trying image-registry seed + wait-for"
  copy_image_registry_gcp_creds || true
  # CCO Passthrough still marks the GCS CredentialsRequest failed (testIamPermissions
  # against the SA host project). Manual stops that reconcile; secrets already exist.
  if oc get co cloud-credential -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null | grep -q True; then
    oc patch cloudcredential cluster --type merge -p '{"spec":{"credentialsMode":"Manual"}}' >/dev/null
    echo "  [OK] CloudCredential credentialsMode=Manual (CCO was Degraded after Passthrough IAM check)"
  fi
  openshift-install wait-for install-complete --dir "${CLUSTER_DIR}" --log-level=info
fi
echo ""

echo "7. Prefer a worker zone that actually exists and offers G2..."
WORKER_AZS="$(oc get machinesets -n openshift-machine-api -o json \
  | python3 "${SCRIPT_DIR}/gpu_machineset.py" list-azs 2>/dev/null || true)"
PICKED_AZ=""
for az in ${WORKER_AZS}; do
  if echo " ${G2_ZONES} " | grep -q " ${az} "; then
    PICKED_AZ="${az}"
    break
  fi
done
if [ -z "${PICKED_AZ}" ]; then
  PICKED_AZ="$(echo "${WORKER_AZS}" | awk 'NF{print; exit}')"
fi
if [ -n "${PICKED_AZ}" ]; then
  printf '%s\n' "${PICKED_AZ}" > "${CLUSTER_DIR}/.gpu-az"
  echo "  [OK] cluster/.gpu-az = ${PICKED_AZ} (worker MachineSet present)"
else
  echo "  [WARN] keeping offering default cluster/.gpu-az = ${FIRST_G2_ZONE}"
fi
echo ""

echo "=== Cluster installed ==="
echo "  export KUBECONFIG=${KUBECONFIG_PATH}"
echo "  Console: https://console-openshift-console.apps.${CLUSTER_NAME}.${GCP_BASE_DOMAIN}"
echo "  kubeadmin password: cluster/auth/kubeadmin-password (gitignored; never commit)"
echo ""
echo "Next:"
echo "  export KUBECONFIG=${KUBECONFIG_PATH}"
echo "  ./setup/full-setup.sh"
echo "  GPU zone hint written to cluster/.gpu-az"
