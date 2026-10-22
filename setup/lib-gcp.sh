# GCP / IPI helpers. Source after defaults.sh. Never print secret values.
# shellcheck disable=SC1091

workshop_repo_root() {
  echo "$(cd "${SCRIPT_DIR}/.." && pwd)"
}

workshop_cluster_dir() {
  # IPI artifacts live in ./cluster (gitignored). CLUSTER_DIR overrides that
  # path for destroy/overnight if you point at a different install-dir.
  if [ -n "${CLUSTER_DIR:-}" ]; then
    echo "${CLUSTER_DIR}"
    return 0
  fi
  echo "$(workshop_repo_root)/cluster"
}

workshop_gcp_creds_file() {
  echo "${GCP_CREDENTIALS_FILE:-$(workshop_repo_root)/private/credentials/gcp-credentials.txt}"
}

workshop_pull_secret_file() {
  echo "${PULL_SECRET_FILE:-$(workshop_repo_root)/private/credentials/rh-pull-secret.txt}"
}

workshop_ssh_key() {
  echo "${SSH_KEY_FILE:-$(workshop_repo_root)/private/ssh/id_ed25519}"
}

workshop_gcp_sa_json() {
  echo "$(workshop_cluster_dir)/.gcp-sa.json"
}

# Parse the Open Environment labeled dump. Exports GCP_PROJECT, GCP_BASE_DOMAIN,
# GCP_SA_EMAIL, GCP_ACME_EMAIL (optional), GOOGLE_APPLICATION_CREDENTIALS.
# Does not echo values. Disables xtrace around the eval.
load_gcp_credentials() {
  local creds
  creds="$(workshop_gcp_creds_file)"
  if [ ! -f "${creds}" ]; then
    echo "  ERROR: GCP credentials file not found: ${creds}" >&2
    echo "         Place the Open Environment dump at private/credentials/gcp-credentials.txt" >&2
    return 1
  fi

  local preset_domain="${GCP_BASE_DOMAIN:-}"
  local preset_project="${GCP_PROJECT:-}"
  local preset_email="${GCP_ACME_EMAIL:-}"
  local sa_json
  sa_json="$(workshop_gcp_sa_json)"
  mkdir -p "$(dirname "${sa_json}")"
  chmod 700 "$(dirname "${sa_json}")" 2>/dev/null || true

  local parsed
  parsed="$(mktemp)"
  chmod 600 "${parsed}"
  python3 - "${creds}" "${parsed}" "${sa_json}" <<'PY'
import json
import sys
from pathlib import Path

src, dest, sa_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
text = src.read_text()
result = {}
lines = [ln.strip() for ln in text.splitlines()]
keymap = {
    "gcp_dns_zone": "GCP_BASE_DOMAIN",
    "gcp_project": "GCP_PROJECT",
    "gcp_service_account": "GCP_SA_EMAIL",
    "gcp_acme_email": "GCP_ACME_EMAIL",
}
i = 0
json_blob = None
while i < len(lines):
    key = lines[i].lower()
    if key == "gcp_credentials_file" and i + 1 < len(lines):
        json_blob = lines[i + 1]
        i += 2
        continue
    if key in keymap and i + 1 < len(lines) and lines[i + 1]:
        val = lines[i + 1].strip()
        if keymap[key] == "GCP_BASE_DOMAIN":
            val = val.lstrip(".").rstrip(".")
        result[keymap[key]] = val
        i += 2
        continue
    i += 1

if not json_blob:
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        json_blob = text[start : end + 1]

if not json_blob:
    sys.stderr.write("  ERROR: credential file has no service-account JSON\n")
    sys.exit(1)
try:
    obj = json.loads(json_blob)
except json.JSONDecodeError:
    sys.stderr.write("  ERROR: service-account JSON is invalid\n")
    sys.exit(1)
if obj.get("type") != "service_account":
    sys.stderr.write("  ERROR: JSON is not a service_account key\n")
    sys.exit(1)
result.setdefault("GCP_SA_EMAIL", obj.get("client_email") or "")
result.setdefault("GCP_PROJECT", "")  # project is the openenv, not the SA host project

sa_path.write_text(json.dumps(obj))
sa_path.chmod(0o600)
result["GOOGLE_APPLICATION_CREDENTIALS"] = str(sa_path)

need = ("GCP_PROJECT", "GCP_BASE_DOMAIN", "GCP_SA_EMAIL")
# GCP_PROJECT must come from the labeled dump (openenv-*), not SA project_id.
missing = [k for k in need if not result.get(k)]
if missing:
    sys.stderr.write("  ERROR: credential file is missing: " + ", ".join(missing) + "\n")
    sys.exit(1)

def sh_single(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"

with dest.open("w") as fh:
    for key, val in result.items():
        fh.write(f"export {key}={sh_single(val)}\n")
PY

  local old_xtrace
  old_xtrace="$(set +o | grep xtrace || true)"
  set +x
  # shellcheck disable=SC1090
  source "${parsed}"
  rm -f "${parsed}"
  eval "${old_xtrace}"

  # Project always comes from the credentials file so a previous tenant
  # left in the shell cannot install into the wrong GCP project.
  if [ -n "${preset_project}" ] && [ "${preset_project}" != "${GCP_PROJECT}" ]; then
    echo "  [WARN] ignoring stale GCP_PROJECT=${preset_project}; using credentials file ${GCP_PROJECT}" >&2
  fi
  if [ -n "${preset_domain}" ] && [ "${preset_domain}" != "${GCP_BASE_DOMAIN:-}" ]; then
    echo "  [WARN] GCP_BASE_DOMAIN env (${preset_domain}) overrides credentials file (${GCP_BASE_DOMAIN:-})" >&2
    export GCP_BASE_DOMAIN="${preset_domain#.}"
    GCP_BASE_DOMAIN="${GCP_BASE_DOMAIN%.}"
    export GCP_BASE_DOMAIN
  elif [ -n "${GCP_BASE_DOMAIN:-}" ]; then
    GCP_BASE_DOMAIN="${GCP_BASE_DOMAIN#.}"
    GCP_BASE_DOMAIN="${GCP_BASE_DOMAIN%.}"
    export GCP_BASE_DOMAIN
  fi
  if [ -n "${preset_email}" ]; then
    export GCP_ACME_EMAIL="${preset_email}"
  fi

  if [ -z "${GCP_PROJECT:-}" ] || [ -z "${GCP_BASE_DOMAIN:-}" ] || [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
    echo "  ERROR: failed to export GCP credentials from ${creds}" >&2
    return 1
  fi
  export CLOUDSDK_CORE_PROJECT="${GCP_PROJECT}"
  export CLOUDSDK_CORE_ACCOUNT="${GCP_SA_EMAIL}"
  export CLOUDSDK_CORE_DISABLE_PROMPTS=1
  export GCE_PROJECT="${GCP_PROJECT}"
}

assert_gcp_region() {
  local wanted="${GCP_REGION:-asia-southeast1}"
  local current="${GCP_REGION}"
  if [ -z "${current}" ]; then
    export GCP_REGION="${wanted}"
    return 0
  fi
  if [ "${current}" != "${wanted}" ] && [ "${GCP_REGION_OVERRIDE:-0}" != "1" ]; then
    echo "  ERROR: this lab installs in ${wanted} (G2 L4 stock on the 2026-10-21 probe)." >&2
    echo "         Refusing region ${current}. Set GCP_REGION_OVERRIDE=1 to override." >&2
    return 1
  fi
  export GCP_REGION="${current}"
}

gcp_activate() {
  if ! command -v gcloud >/dev/null 2>&1; then
    echo "  ERROR: gcloud not found. Install the Google Cloud SDK, then re-run ./setup/00-install-tools.sh" >&2
    return 1
  fi
  if [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] || [ ! -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]; then
    echo "  ERROR: GOOGLE_APPLICATION_CREDENTIALS is missing. Run load_gcp_credentials first." >&2
    return 1
  fi
  export CLOUDSDK_CORE_PROJECT="${GCP_PROJECT}"
  export CLOUDSDK_CORE_ACCOUNT="${GCP_SA_EMAIL}"
  export GCE_PROJECT="${GCP_PROJECT}"
  gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" --quiet >/dev/null
  gcloud config set project "${GCP_PROJECT}" --quiet >/dev/null
  gcloud config set compute/region "${GCP_REGION}" --quiet >/dev/null
}

ensure_cluster_ssh_key() {
  local key
  key="$(workshop_ssh_key)"
  mkdir -p "$(dirname "${key}")"
  chmod 700 "$(dirname "${key}")" 2>/dev/null || true
  if [ ! -f "${key}" ]; then
    ssh-keygen -t ed25519 -N "" -f "${key}" -C "workshop-ipi" >/dev/null
    chmod 600 "${key}" "${key}.pub"
    echo "  [OK] generated SSH key ${key}"
  elif [ ! -f "${key}.pub" ]; then
    ssh-keygen -y -f "${key}" > "${key}.pub"
    chmod 600 "${key}" "${key}.pub"
  fi
}

assert_public_dns_zone() {
  local domain="${GCP_BASE_DOMAIN}"
  local json vis name
  json="$(gcloud dns managed-zones list --format=json --project="${GCP_PROJECT}")"
  name="$(echo "${json}" | python3 -c '
import json,sys
want=sys.argv[1].rstrip(".")+"."
for z in json.load(sys.stdin):
    if z.get("dnsName")==want and z.get("visibility")=="public":
        print(z.get("name",""))
        break
' "${domain}")"
  if [ -z "${name}" ]; then
    echo "  ERROR: no public Cloud DNS managed zone for ${domain} in project ${GCP_PROJECT}." >&2
    echo "         OpenShift IPI needs that pre-created zone. Do not create or re-delegate DNS here." >&2
    return 1
  fi
  echo "  [OK] public Cloud DNS zone ${name} for ${domain}"
}

gcp_l4_quota() {
  local region="${1:-${GCP_REGION}}"
  gcloud compute regions describe "${region}" --format=json --project="${GCP_PROJECT}" \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
qs={q["metric"]:q for q in d.get("quotas",[])}
q=qs.get("NVIDIA_L4_GPUS") or {}
print(int(float(q.get("limit") or 0)), int(float(q.get("usage") or 0)))
'
}

preflight_l4_quota() {
  local need="${1:-${GCP_L4_QUOTA_REHEARSAL}}"
  local limit usage remaining
  read -r limit usage < <(gcp_l4_quota "${GCP_REGION}")
  remaining=$((limit - usage))
  echo "  NVIDIA_L4_GPUS in ${GCP_REGION}: limit=${limit} usage=${usage} remaining=${remaining} (need ${need})"
  if [ "${remaining}" -lt "${need}" ]; then
    echo "  ERROR: remaining L4 quota ${remaining} < ${need}. This sandbox has no quota-increase path." >&2
    return 1
  fi
}

cluster_infra_id() {
  local meta
  meta="$(workshop_cluster_dir)/metadata.json"
  if [ -f "${meta}" ]; then
    python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('infraID',''))" "${meta}"
    return 0
  fi
  oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || true
}

gcp_list_cluster_instances() {
  local infra="$1"
  gcloud compute instances list --project="${GCP_PROJECT}" \
    --filter="name~${infra}" \
    --format='value(name,zone.basename(),status,machineType.basename())'
}
