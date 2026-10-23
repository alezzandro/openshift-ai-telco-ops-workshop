# Common helpers. Source after defaults.sh and ensure-authenticated.sh.
# shellcheck disable=SC2034

workshop_creds_file() {
  echo "${SCRIPT_DIR}/.generated-credentials.env"
}

set_cred() {
  local key="$1"
  local value="$2"
  local file
  file="$(workshop_creds_file)"
  touch "${file}"
  chmod 0600 "${file}"
  if grep -q "^${key}=" "${file}" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    grep -v "^${key}=" "${file}" > "${tmp}" || true
    mv "${tmp}" "${file}"
    chmod 0600 "${file}"
  fi
  printf "%s='%s'\n" "${key}" "${value}" >> "${file}"
}

get_cred() {
  local key="$1"
  local file
  file="$(workshop_creds_file)"
  [ -f "${file}" ] || return 1
  local line
  line="$(grep "^${key}=" "${file}" 2>/dev/null | tail -1 || true)"
  [ -n "${line}" ] || return 1
  local val="${line#*=}"
  val="${val#\'}"
  val="${val%\'}"
  val="${val#\"}"
  val="${val%\"}"
  printf '%s' "${val}"
}

find_gpu_machineset() {
  # Prefer a GPU MachineSet with replicas>0 so overnight --fix does not
  # scale a drained zone back up after switch-gpu-az.sh.
  # Optional pool: 4l4 or 2l4.
  # pick-active prints nothing when no GPU MachineSet exists; always succeed
  # so callers with set -euo pipefail can treat empty as "not found".
  local pool="${1:-}"
  local args=()
  if [ -n "${pool}" ]; then
    args+=(--pool "${pool}")
  fi
  oc get machinesets -n openshift-machine-api -o json 2>/dev/null \
    | python3 "${SCRIPT_DIR}/gpu_machineset.py" pick-active "${args[@]}" 2>/dev/null \
    | awk -F'|' 'NF>=2 {print $1"|"$2}' || true
}

cluster_domain() {
  oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo ""
}

rhoai_dashboard_host() {
  local host
  host="$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [ -z "${host}" ]; then
    host="$(oc get route -n redhat-ods-applications -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
  fi
  printf '%s' "${host}"
}

ocp_major_minor() {
  oc version -o json 2>/dev/null | python3 -c "
import sys, json, re
v = json.load(sys.stdin).get('openshiftVersion', '')
m = re.match(r'(\d+\.\d+)', v or '')
print(m.group(1) if m else '4.19')
" 2>/dev/null || echo "4.19"
}

detect_notebook_image() {
  local img
  img="$(oc get imagestream s2i-generic-data-science-notebook -n redhat-ods-applications -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
repo = (data.get('status') or {}).get('dockerImageRepository') or ''
if not repo:
    sys.exit(0)
recommended = None
first = None
for tag in (data.get('spec') or {}).get('tags') or []:
    name = tag.get('name') or ''
    if not name:
        continue
    if first is None:
        first = name
    ann = tag.get('annotations') or {}
    if str(ann.get('opendatahub.io/workbench-image-recommended', '')).lower() == 'true':
        recommended = name
        break
tag = recommended or first
if tag:
    print(f'{repo}:{tag}')
" 2>/dev/null || true)"
  if [ -z "${img}" ]; then
    img="${NOTEBOOK_IMAGE_FALLBACK:-image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/s2i-generic-data-science-notebook:3.5}"
  fi
  printf '%s' "${img}"
}

notebook_image_display_name() {
  oc get imagestream s2i-generic-data-science-notebook -n redhat-ods-applications \
    -o jsonpath='{.metadata.annotations.opendatahub\.io/notebook-image-name}' 2>/dev/null \
    || echo "Jupyter | Data Science | CPU | Python 3.12"
}

detect_vllm_image() {
  local img
  img="$(oc get template -n redhat-ods-applications -o json 2>/dev/null | python3 -c "
import sys, json, re
data = json.load(sys.stdin)
for t in data.get('items', []):
    name = t.get('metadata', {}).get('name', '')
    if 'vllm' in name.lower() and 'cuda' in name.lower():
        for obj in t.get('objects', []):
            for c in obj.get('spec', {}).get('containers', []) or []:
                image = c.get('image', '')
                if image:
                    print(image)
                    sys.exit(0)
        break
" 2>/dev/null || true)"
  if [ -z "${img}" ]; then
    img="${VLLM_IMAGE_FALLBACK}"
  fi
  printf '%s' "${img}"
}

wait_for_csv() {
  local namespace="$1"
  local name_pattern="$2"
  local timeout="${3:-300}"
  echo "  Waiting for CSV matching '${name_pattern}' in '${namespace}'..."
  local i
  for i in $(seq 1 $((timeout / 5))); do
    local csv_line
    csv_line="$(oc get csv -n "${namespace}" --no-headers 2>/dev/null | grep "${name_pattern}" | head -1 || true)"
    if [ -n "${csv_line}" ]; then
      local phase
      phase="$(echo "${csv_line}" | awk '{print $NF}')"
      if [ "${phase}" = "Succeeded" ]; then
        echo "  [OK] CSV ready: $(echo "${csv_line}" | awk '{print $1}')"
        return 0
      fi
    fi
    sleep 5
  done
  echo "  [WARN] CSV '${name_pattern}' not Succeeded within ${timeout}s"
  return 1
}

# oc apply a multi-doc operator manifest, but do not create a second OperatorGroup
# in a namespace that already has one (OLM TooManyOperatorGroups).
apply_operator_manifest() {
  local file="$1"
  python3 - "$file" <<'PY'
import subprocess, sys

try:
    import yaml
except ImportError:
    subprocess.run(["oc", "apply", "-f", sys.argv[1]], check=True)
    sys.exit(0)

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
keep = []
for doc in docs:
    if doc.get("kind") == "OperatorGroup":
        ns = doc.get("metadata", {}).get("namespace", "")
        r = subprocess.run(
            ["oc", "get", "operatorgroup", "-n", ns, "--no-headers"],
            capture_output=True, text=True,
        )
        if (r.stdout or "").strip():
            print(f"  skip OperatorGroup in {ns}: one already exists")
            continue
    keep.append(doc)
if keep:
    subprocess.run(
        ["oc", "apply", "-f", "-"],
        input=yaml.safe_dump_all(keep),
        text=True,
        check=True,
    )
PY
}

packagemanifest_default_channel() {
  local package="$1"
  oc get packagemanifest "${package}" -n openshift-marketplace \
    -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true
}

report_gpu_machines() {
  local events rc=0
  events="$(mktemp)"
  oc get events -n openshift-machine-api -o json > "${events}" 2>/dev/null \
    || printf '%s\n' '{"items":[]}' > "${events}"
  oc get machines -n openshift-machine-api -o json 2>/dev/null \
    | python3 "${SCRIPT_DIR}/gpu_machineset.py" capacity-check --events-json "${events}" \
    || rc=$?
  rm -f "${events}"
  return "${rc}"
}

wait_for_gpu_pool() {
  local needed="${1:-1}"
  local timeout="${2:-900}"
  local elapsed=0
  echo "  Waiting for ${needed} GPU node(s) Ready (timeout ${timeout}s)..."
  while [ "${elapsed}" -lt "${timeout}" ]; do
    local ready
    ready="$(oc get nodes -l node-role.kubernetes.io/worker-gpu --no-headers 2>/dev/null \
      | awk '$2 == "Ready" { n++ } END { print n+0 }')"
    if [ "${ready}" -ge "${needed}" ]; then
      echo "  [OK] ${ready}/${needed} GPU node(s) Ready"
      return 0
    fi
    local rc=0
    report_gpu_machines || rc=$?
    if [ "${rc}" -eq 1 ]; then
      echo "  [FAIL] GPU Machine entered Failed. Check NVIDIA_L4 quota and G2 stock in the zone."
      echo "         If the event is ZONE_RESOURCE_POOL_EXHAUSTED, switch zone:"
      echo "         ./setup/switch-gpu-az.sh --list"
      echo "         ./setup/switch-gpu-az.sh --az <zone>"
      echo "         Operators, Open WebUI, and the lab guide can still install on general workers."
      return 1
    fi
    echo "  ... ${ready}/${needed} Ready (${elapsed}s)"
    sleep 30
    elapsed=$((elapsed + 30))
  done
  echo "  [WARN] Timeout waiting for GPU nodes"
  report_gpu_machines || true
  return 1
}

wait_for_ready_nodes() {
  local label="$1"
  local needed="$2"
  local desc="$3"
  local timeout="${4:-900}"
  local elapsed=0
  echo "  Waiting for ${needed} ${desc} node(s) Ready (timeout ${timeout}s)..."
  while [ "${elapsed}" -lt "${timeout}" ]; do
    local ready
    ready="$(oc get nodes -l "${label}" --no-headers 2>/dev/null \
      | awk '$2 == "Ready" { n++ } END { print n+0 }')"
    if [ "${ready}" -ge "${needed}" ]; then
      echo "  [OK] ${ready}/${needed} ${desc} node(s) Ready"
      return 0
    fi
    if [[ "${desc}" == "4l4" || "${desc}" == "2l4" ]]; then
      local cap_rc=0
      report_gpu_machines || cap_rc=$?
      if [ "${cap_rc}" -eq 1 ]; then
        echo "  [FAIL] GPU Machine Failed while waiting for ${desc} (quota or STOCKOUT)."
        return 1
      fi
    fi
    echo "  ... ${ready}/${needed} Ready (${elapsed}s)"
    sleep 30
    elapsed=$((elapsed + 30))
  done
  echo "  [WARN] Timeout waiting for ${desc} nodes"
  return 1
}

gpu_allocatable_ok() {
  local needed="${1:-${GPU_4L4_COUNT:-4}}"
  local selector="${2:-node-role.kubernetes.io/worker-gpu}"
  oc get nodes -l "${selector}" --no-headers 2>/dev/null \
    | awk '{print $1}' | while read -r node; do
        [ -n "${node}" ] || continue
        local alloc
        alloc="$(oc get node "${node}" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo 0)"
        echo "${node} allocatable=${alloc:-0}"
        if [ "${alloc:-0}" != "${needed}" ]; then
          return 1
        fi
      done
}

write_lab_guide_env() {
  local domain console api rhoai_host rhoai webui_host webui s4_host s4 guide_host guide play_host play
  domain="$(cluster_domain)"
  console="https://console-openshift-console.${domain}"
  api="$(oc whoami --show-server 2>/dev/null || echo "")"
  rhoai_host="$(rhoai_dashboard_host)"
  rhoai=""
  [ -n "${rhoai_host}" ] && rhoai="https://${rhoai_host}"
  webui_host="$(oc get route open-webui -n open-webui -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  webui=""
  [ -n "${webui_host}" ] && webui="https://${webui_host}"
  s4_host="$(oc get route s4 -n s4 -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  s4=""
  [ -n "${s4_host}" ] && s4="https://${s4_host}"
  guide_host="$(oc get route lab-guide -n lab-guide -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  guide=""
  [ -n "${guide_host}" ] && guide="https://${guide_host}"
  play_host="$(oc get route playground -n lab-guide -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  play=""
  [ -n "${play_host}" ] && play="https://${play_host}"
  export CONSOLE="${console}" API="${api}" RHOAI="${rhoai}" WEBUI="${webui}" GUIDE="${guide}" PLAYGROUND="${play}" S4="${s4}"
  export PRESENTER_PROJECT="${PRESENTER_PROJECT:-telco-ops-demo}"
  export WORKBENCH_PROJECT="${WORKBENCH_PROJECT:-telco-ops-notebooks}"
  python3 - <<'PY' | oc apply -f -
import json, os
payload = {
  "console": os.environ.get("CONSOLE", ""),
  "api": os.environ.get("API", ""),
  "rhoai_dashboard": os.environ.get("RHOAI", ""),
  "open_webui": os.environ.get("WEBUI", ""),
  "s4": os.environ.get("S4", ""),
  "lab_guide": os.environ.get("GUIDE", ""),
  "playground": os.environ.get("PLAYGROUND", ""),
  "presenter_project": os.environ.get("PRESENTER_PROJECT", "telco-ops-demo"),
  "workbench_project": os.environ.get("WORKBENCH_PROJECT", "telco-ops-notebooks"),
  "ran_project": "telco-ran-ai",
  "core_project": "telco-core-ai",
}
doc = {
  "apiVersion": "v1",
  "kind": "ConfigMap",
  "metadata": {"name": "lab-guide-env", "namespace": "lab-guide"},
  "data": {"env.json": json.dumps(payload, indent=2) + "\n"},
}
print(json.dumps(doc, indent=2))
PY
}

patch_clusterqueue_gpu_quota() {
  local name="$1"
  local quota="$2"
  local flavor="${3:-}"
  CQ_NAME="${name}" QUOTA="${quota}" FLAVOR="${flavor}" python3 - <<'PY'
import json, os, subprocess, sys
name = os.environ["CQ_NAME"]
quota = os.environ["QUOTA"]
flavor_filter = os.environ.get("FLAVOR") or ""
raw = subprocess.check_output(["oc", "get", "clusterqueue", name, "-o", "json"], text=True)
cq = json.loads(raw)
changed = False
for group in cq.get("spec", {}).get("resourceGroups", []):
    flavors = group.get("flavors", [])
    for flavor in flavors:
        if flavor_filter and flavor.get("name") != flavor_filter:
            continue
        for resource in flavor.get("resources", []):
            if resource.get("name") == "nvidia.com/gpu":
                resource["nominalQuota"] = quota
                changed = True
if not changed:
    sys.exit(1)
cq.pop("status", None)
md = cq.setdefault("metadata", {})
for k in ("uid", "resourceVersion", "generation", "creationTimestamp", "managedFields"):
    md.pop(k, None)
subprocess.run(["oc", "apply", "-f", "-"], input=json.dumps(cq), text=True, check=True)
print(f"ClusterQueue {name} nvidia.com/gpu nominalQuota={quota}" + (f" flavor={flavor_filter}" if flavor_filter else ""))
PY
}

wait_gpu_machines_gone() {
  local timeout="${1:-600}"
  local elapsed=0
  echo "  Waiting until GPU Machines are gone (timeout ${timeout}s)..."
  while [ "${elapsed}" -lt "${timeout}" ]; do
    local n
    n="$(oc get machines -n openshift-machine-api -o json 2>/dev/null | python3 -c '
import json,sys
data=json.load(sys.stdin)
n=0
for m in data.get("items") or []:
    name=(m.get("metadata") or {}).get("name","")
    labels=(m.get("metadata") or {}).get("labels") or {}
    role=labels.get("machine.openshift.io/cluster-api-machine-type","")
    if "gpu" in name.lower() or "gpu" in role.lower():
        n += 1
print(n)
' 2>/dev/null || echo 0)"
    n="${n// /}"
    if [ "${n:-0}" = "0" ]; then
      echo "  [OK] no GPU Machines remain"
      return 0
    fi
    echo "  ... ${n} GPU Machine(s) still present (${elapsed}s)"
    sleep 15
    elapsed=$((elapsed + 15))
  done
  echo "  [WARN] GPU Machines still present after ${timeout}s"
  oc get machines -n openshift-machine-api --no-headers 2>/dev/null | grep -i gpu || true
  return 1
}

# Rehearsal (r2=0): both ClusterQueues share cohort workshop-gpu so student
# LocalQueue workshop can borrow unused 4-L4 quota.
# Class (r2>0): drop the cohort. Same-cohort borrow lets gpu-pool-2l4 take
# presenter 4-L4 GPUs after the 6 student cards fill, so P5 hits ResourceQuota
# instead of Kueue SchedulingGated.
sync_kueue_gpu_quotas() {
  local r4="${1:-0}"
  local r2="${2:-0}"
  local q4=$((r4 * ${GPU_4L4_COUNT:-4}))
  local q2=$((r2 * ${GPU_2L4_COUNT:-2}))
  R4="${r4}" R2="${r2}" Q4="${q4}" Q2="${q2}" python3 - <<'PY'
import json, os, subprocess, sys

q4, q2 = os.environ["Q4"], os.environ["Q2"]
r2 = int(os.environ["R2"] or 0)

def flavor(name, gpu, cpu="32", mem="128Gi"):
    return {
        "name": name,
        "resources": [
            {"name": "cpu", "nominalQuota": cpu},
            {"name": "memory", "nominalQuota": mem},
            {"name": "nvidia.com/gpu", "nominalQuota": str(gpu)},
        ],
    }

def load(name):
    raw = subprocess.check_output(["oc", "get", "clusterqueue", name, "-o", "json"], text=True)
    return json.loads(raw)

def apply(cq):
    cq.pop("status", None)
    md = cq.setdefault("metadata", {})
    for k in ("uid", "resourceVersion", "generation", "creationTimestamp", "managedFields"):
        md.pop(k, None)
    subprocess.run(["oc", "apply", "-f", "-"], input=json.dumps(cq), text=True, check=True)

def drop_cohort(name):
    # oc apply cannot remove spec.cohortName; JSON patch can.
    live = load(name)
    spec = live.get("spec") or {}
    if "cohortName" not in spec and "cohort" not in spec:
        print(f"ClusterQueue {name} already has no cohortName")
        return
    p = subprocess.run(
        [
            "oc", "patch", "clusterqueue", name, "--type=json",
            "-p", '[{"op":"remove","path":"/spec/cohortName"}]',
        ],
        capture_output=True,
        text=True,
    )
    err = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        print(f"ClusterQueue {name} cohortName removed (class day, no borrow)")
        return
    print(f"  [WARN] could not drop cohortName on {name}: {err.strip()[:200]}", file=sys.stderr)

try:
    cq4 = load("gpu-pool-4l4")
except subprocess.CalledProcessError:
    cq4 = None
if cq4 is not None:
    groups = cq4.setdefault("spec", {}).setdefault("resourceGroups", [])
    if not groups:
        groups.append({"coveredResources": ["cpu", "memory", "nvidia.com/gpu"], "flavors": []})
    groups[0]["flavors"] = [flavor("l4-gpu-4", q4)]
    spec = cq4.setdefault("spec", {})
    spec.pop("cohort", None)
    if r2 > 0:
        spec.pop("cohortName", None)
    else:
        spec["cohortName"] = "workshop-gpu"
    apply(cq4)
    if r2 > 0:
        drop_cohort("gpu-pool-4l4")
    print(f"ClusterQueue gpu-pool-4l4 nvidia.com/gpu nominalQuota={q4}")

try:
    cq2 = load("gpu-pool-2l4")
except subprocess.CalledProcessError:
    cq2 = None
    try:
        old = load("gpu-pool")
    except subprocess.CalledProcessError:
        old = None
    if old is not None:
        for group in old.get("spec", {}).get("resourceGroups", []):
            for fl in group.get("flavors", []):
                for resource in fl.get("resources", []):
                    if resource.get("name") == "nvidia.com/gpu":
                        resource["nominalQuota"] = str(int(q4) + int(q2))
        apply(old)
        print(f"ClusterQueue gpu-pool nvidia.com/gpu nominalQuota={int(q4)+int(q2)}")
        sys.exit(0)

if cq2 is not None:
    groups = cq2.setdefault("spec", {}).setdefault("resourceGroups", [])
    if not groups:
        groups.append({"coveredResources": ["cpu", "memory", "nvidia.com/gpu"], "flavors": []})
    two = flavor("l4-gpu-2", q2, cpu="64", mem="256Gi")
    four = flavor("l4-gpu-4", "0")
    # Class: only the 2-L4 flavor so student jobs cannot land on the
    # presenter node. Rehearsal: 4-L4 flavor first (borrow).
    groups[0]["flavors"] = [two] if r2 > 0 else [four, two]
    spec = cq2.setdefault("spec", {})
    spec.pop("cohort", None)
    if r2 > 0:
        spec.pop("cohortName", None)
    else:
        spec["cohortName"] = "workshop-gpu"
    apply(cq2)
    if r2 > 0:
        drop_cohort("gpu-pool-2l4")
        print(f"ClusterQueue gpu-pool-2l4 flavors order=2l4-first gpu2={q2} gpu4=0 (no cohort, no 4-L4 borrow)")
    else:
        print(f"ClusterQueue gpu-pool-2l4 flavors order=4l4-first gpu2={q2} gpu4=0 (cohort borrow)")
PY
}

# Open WebUI 0.6 stores one JSON blob in config.data; older builds used key/value.
# oc exec -i + stdin avoids python -c quoting through the API.
patch_open_webui_sqlite() {
  oc exec -i -n open-webui deploy/open-webui -- python3 - <<'PY'
import json, sqlite3, time

con = sqlite3.connect("/app/backend/data/webui.db")
cur = con.cursor()
tables = [row[0] for row in cur.execute("SELECT name FROM sqlite_master WHERE type='table'")]
if "config" not in tables:
    raise SystemExit("config table missing")
cols = [row[1] for row in cur.execute("PRAGMA table_info(config)")]
now = int(time.time() * 1000)

def load_json(raw):
    if raw is None or raw == "":
        return {}
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode()
    if isinstance(raw, dict):
        return dict(raw)
    if isinstance(raw, str):
        return json.loads(raw)
    return {}

if "key" in cols and "value" in cols:
    updates = {
        "models.default_params": {"function_calling": "legacy"},
        "ui.enable_signup": True,
        "direct.enable": False,
        "openai.enable": True,
        "openai.api_base_urls": [],
        "openai.api_keys": [],
        "openai.api_configs": {},
        "code_interpreter.enable": False,
        "code_execution.enable": False,
        "web.search.enable": False,
        "image_generation.enable": False,
    }
    for key, value in updates.items():
        stored = json.dumps(value)
        cur.execute(
            "INSERT INTO config(key, value, updated_at) VALUES(?, ?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
            (key, stored, now),
        )
elif "data" in cols:
    row = cur.execute("SELECT id, data FROM config ORDER BY id DESC LIMIT 1").fetchone()
    if not row:
        raise SystemExit("config row missing")
    cfg = load_json(row[1])
    ui = cfg.setdefault("ui", {})
    ui["enable_signup"] = True
    cfg.setdefault("direct", {})["enable"] = False
    # Empty OPENAI_API_BASE_URL defaults to https://api.openai.com/v1. This
    # cluster has no internet egress from Open WebUI, so that poll is a 10s
    # "Connection error". Students use the authenticated model Route, not
    # Open WebUI. Direct Connections stay disabled.
    openai = cfg.setdefault("openai", {})
    openai["enable"] = True
    openai["api_base_urls"] = []
    openai["api_keys"] = []
    openai["api_configs"] = {}
    params = cfg.setdefault("models", {}).setdefault("default_params", {})
    if isinstance(params, str):
        params = load_json(params)
        cfg["models"]["default_params"] = params
    params["function_calling"] = "legacy"
    for section in ("code_interpreter", "code_execution", "image_generation"):
        cfg.setdefault(section, {})["enable"] = False
    cfg.setdefault("web", {}).setdefault("search", {})["enable"] = False
    cur.execute("UPDATE config SET data=? WHERE id=?", (json.dumps(cfg), row[0]))
else:
    raise SystemExit("unrecognized config schema")
con.commit()
print("webui config patched")
PY
}

open_webui_has_no_default_openai() {
  oc exec -i -n open-webui deploy/open-webui -- python3 - <<'PY'
import json, sqlite3, sys

con = sqlite3.connect("/app/backend/data/webui.db")
cur = con.cursor()
tables = [row[0] for row in cur.execute("SELECT name FROM sqlite_master WHERE type='table'")]
if "config" not in tables:
    sys.exit(1)
cols = [row[1] for row in cur.execute("PRAGMA table_info(config)")]
urls = None
if "data" in cols:
    row = cur.execute("SELECT data FROM config ORDER BY id DESC LIMIT 1").fetchone()
    raw = row[0] if row else {}
    cfg = raw if isinstance(raw, dict) else json.loads(raw or "{}")
    urls = (cfg.get("openai") or {}).get("api_base_urls")
sys.exit(0 if urls == [] else 1)
PY
}

open_webui_has_legacy_function_calling() {
  oc exec -i -n open-webui deploy/open-webui -- python3 - <<'PY'
import json, sqlite3, sys

con = sqlite3.connect("/app/backend/data/webui.db")
cur = con.cursor()
tables = [row[0] for row in cur.execute("SELECT name FROM sqlite_master WHERE type='table'")]
if "config" not in tables:
    sys.exit(1)
cols = [row[1] for row in cur.execute("PRAGMA table_info(config)")]
blob = ""
if "key" in cols and "value" in cols:
    blob = " ".join(val or "" for _, val in cur.execute("SELECT key, value FROM config"))
elif "data" in cols:
    row = cur.execute("SELECT data FROM config ORDER BY id DESC LIMIT 1").fetchone()
    raw = row[0] if row else ""
    blob = raw if isinstance(raw, str) else json.dumps(raw or {})
sys.exit(0 if ("function_calling" in blob and "legacy" in blob) else 1)
PY
}

mcp_catalog_has_workshop_server() {
  oc exec -n rhoai-model-registries deploy/model-catalog -c catalog -- \
    curl -sS --max-time 10 \
    'http://127.0.0.1:8080/api/mcp_catalog/v1alpha1/mcp_servers?pageSize=10&q=workshop-custom-mcp' \
    2>/dev/null | grep -q 'workshop-custom-mcp'
}

# Rolling-restart of model-catalog starts the new pod before the old one
# releases Postgres table locks.catalog-leader. The new pod stays standby
# (read-only) and never ingests custom MCP YAML. Delete the stale row, then
# delete only the catalog pod (not postgres — they share app=model-catalog).
recover_model_catalog_leader() {
  echo "        Recovering model-catalog leader lock..."
  oc exec -n rhoai-model-registries deploy/model-catalog-postgres -- \
    psql -U postgres -d model_catalog -c "DELETE FROM locks WHERE name = 'catalog-leader';" \
    >/dev/null 2>&1 || true
  oc delete pod -n rhoai-model-registries -l app.kubernetes.io/name=model-catalog --wait=true --timeout=120s \
    >/dev/null 2>&1 || true
  oc rollout status deployment/model-catalog -n rhoai-model-registries --timeout=180s >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 36); do
    if oc logs -n rhoai-model-registries deploy/model-catalog -c catalog --tail=80 2>/dev/null \
        | grep -q 'mcp plugin leader mode active'; then
      echo "        model-catalog is catalog leader"
      return 0
    fi
    sleep 5
  done
  echo "        [WARN] model-catalog did not log leader mode yet"
  return 1
}

force_delete_failed_predictors() {
  local ns
  for ns in ${DS_PROJECTS}; do
    oc get pods -n "${ns}" --no-headers 2>/dev/null \
      | awk '$3 ~ /Failed|Error|Init:Crash/ {print $1}' \
      | while read -r pod; do
          [ -n "${pod}" ] || continue
          echo "  Force-deleting leftover pod ${ns}/${pod}"
          oc delete pod "${pod}" -n "${ns}" --force --grace-period=0 2>/dev/null || true
        done
  done
}

# List leftover serving CRs (InferenceService + LLMInferenceService). Empty if none.
list_inference_services() {
  {
    oc get inferenceservice -A --no-headers 2>/dev/null || true
    oc get llminferenceservice -A --no-headers 2>/dev/null || true
  } | sed '/^$/d'
}

# Stop dashboard leftovers so GPU nodes can drain. Keeps Model Registry and PVCs.
# $1 = wait timeout seconds (default 180). Always returns 0 so overnight can continue.
stop_inference_services() {
  local timeout="${1:-180}"
  local leftover ns name
  leftover="$(list_inference_services)"
  if [ -z "${leftover}" ]; then
    echo "  No InferenceServices present"
    return 0
  fi
  echo "${leftover}"
  echo "  Deleting InferenceServices (Model Registry entries stay)..."
  while read -r ns name _; do
    [ -n "${ns}" ] && [ -n "${name}" ] || continue
    oc delete inferenceservice "${name}" -n "${ns}" --wait=false 2>/dev/null || true
  done < <(oc get inferenceservice -A --no-headers 2>/dev/null || true)
  while read -r ns name _; do
    [ -n "${ns}" ] && [ -n "${name}" ] || continue
    oc delete llminferenceservice "${name}" -n "${ns}" --wait=false 2>/dev/null || true
  done < <(oc get llminferenceservice -A --no-headers 2>/dev/null || true)

  if [ "${timeout}" -le 0 ]; then
    echo "  delete issued (not waiting)"
    return 0
  fi

  local i
  for i in $(seq 1 $((timeout / 5))); do
    leftover="$(list_inference_services)"
    if [ -z "${leftover}" ]; then
      echo "  [OK] InferenceServices stopped"
      return 0
    fi
    sleep 5
  done

  echo "  [WARN] still present after ${timeout}s; clearing finalizers and force-deleting"
  force_delete_failed_predictors
  while read -r ns name _; do
    [ -n "${ns}" ] && [ -n "${name}" ] || continue
    oc patch inferenceservice "${name}" -n "${ns}" --type=merge \
      -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    oc delete inferenceservice "${name}" -n "${ns}" --force --grace-period=0 --wait=false 2>/dev/null || true
  done < <(oc get inferenceservice -A --no-headers 2>/dev/null || true)
  while read -r ns name _; do
    [ -n "${ns}" ] && [ -n "${name}" ] || continue
    oc patch llminferenceservice "${name}" -n "${ns}" --type=merge \
      -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    oc delete llminferenceservice "${name}" -n "${ns}" --force --grace-period=0 --wait=false 2>/dev/null || true
  done < <(oc get llminferenceservice -A --no-headers 2>/dev/null || true)

  leftover="$(list_inference_services)"
  if [ -n "${leftover}" ]; then
    echo "  [WARN] leftover serving CRs (continuing overnight anyway):"
    echo "${leftover}"
    return 0
  fi
  echo "  [OK] InferenceServices stopped"
  return 0
}

# Playground OGXServer pins VLLM_API_TOKEN_* to the C3 SA secret. Deleting the
# InferenceService removes that secret and leaves CreateContainerConfigError.
# Mark missing secretKeyRefs optional so OGX can start without a live model.
relax_ogx_missing_token_refs() {
  local ns name tmp
  for ns in ${DS_PROJECTS}; do
    while read -r name; do
      [ -n "${name}" ] || continue
      tmp="$(mktemp)"
      if NS="${ns}" NAME="${name}" python3 - <<'PY' >"${tmp}"
import json, os, subprocess, sys

ns, name = os.environ["NS"], os.environ["NAME"]
raw = subprocess.check_output(
    ["oc", "get", "ogxserver", name, "-n", ns, "-o", "json"],
    stderr=subprocess.DEVNULL,
)
doc = json.loads(raw)
env = (
    doc.get("spec", {})
    .get("workload", {})
    .get("overrides", {})
    .get("env")
    or []
)
changed = False
for item in env:
    ref = (item.get("valueFrom") or {}).get("secretKeyRef") or {}
    secret = ref.get("name")
    if not secret:
        continue
    rc = subprocess.call(
        ["oc", "get", "secret", secret, "-n", ns],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if rc != 0 and not ref.get("optional"):
        ref["optional"] = True
        item["valueFrom"]["secretKeyRef"] = ref
        changed = True
        print(f"  {ns}/{name}: {item.get('name')} secret {secret} missing → optional", file=sys.stderr)
if changed:
    print(json.dumps(doc))
PY
      then
        if [ -s "${tmp}" ]; then
          oc replace -f "${tmp}" >/dev/null
        fi
      fi
      rm -f "${tmp}"
    done < <(oc get ogxserver -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  done
}

# Shared OCI-v1 connection for catalog ModelCars (C3 Ministral, C6 Phi-4, …).
# Matching is by OCI_HOST (registry.redhat.io), not by model name. C3 used to
# create a connection named after Ministral; C6 then locked that leftover in
# the deploy dropdown. Prefer one well-named connection per Data Science Project.
ensure_redhat_catalog_oci_connections() {
  local ns
  for ns in ${DS_PROJECTS}; do
    CATALOG_OCI_CONNECTION_NAME="${CATALOG_OCI_CONNECTION_NAME}" \
    CATALOG_OCI_CONNECTION_DISPLAY="${CATALOG_OCI_CONNECTION_DISPLAY}" \
    CATALOG_OCI_HOST="${CATALOG_OCI_HOST}" \
    NS="${ns}" python3 - <<'PY' | oc apply -f -
import base64, json, os, subprocess, sys

ns = os.environ["NS"]
want_name = os.environ["CATALOG_OCI_CONNECTION_NAME"]
display = os.environ["CATALOG_OCI_CONNECTION_DISPLAY"]
host = os.environ["CATALOG_OCI_HOST"]
desc = (
    "OCI pull host for catalog ModelCars on registry.redhat.io. "
    "Shared by every catalog model (Ministral, Phi-4, and others). "
    "The Model Registry version names the image; this connection is not the model."
)

def decode(data, key):
    raw = (data or {}).get(key)
    if not raw:
        return ""
    return base64.b64decode(raw).decode()

secrets = json.loads(subprocess.check_output(["oc", "get", "secrets", "-n", ns, "-o", "json"]))
existing = []
for secret in secrets.get("items") or []:
    ann = secret.get("metadata", {}).get("annotations") or {}
    if ann.get("opendatahub.io/connection-type-ref") != "oci-v1":
        continue
    if decode(secret.get("data"), "OCI_HOST") != host:
        continue
    existing.append(secret["metadata"]["name"])

name = existing[0] if existing else want_name
doc = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": name,
        "namespace": ns,
        "labels": {"opendatahub.io/dashboard": "true"},
        "annotations": {
            "opendatahub.io/connection-type-protocol": "oci",
            "opendatahub.io/connection-type-ref": "oci-v1",
            "openshift.io/display-name": display,
            "openshift.io/description": desc,
        },
    },
    "type": "Opaque",
    "stringData": {
        "ACCESS_TYPE": '["Pull"]',
        "OCI_HOST": host,
    },
}
print(json.dumps(doc, indent=2))
if existing and name != want_name:
    print(f"  [OK] {ns}/{name} (renamed leftover catalog OCI connection)", file=sys.stderr)
else:
    print(f"  [OK] {ns}/{name}", file=sys.stderr)
PY
  done
}

# OCI connection for ImageStream ModelCars (C4b Granite). KServe pulls
# oci://image-registry.openshift-image-registry.svc:5000/... and the
# operator injects spec.predictor.imagePullSecrets from this Secret.
# Type must be kubernetes.io/dockerconfigjson with an "auths" map.
# Uploading the default SA's raw .dockercfg (no auths wrapper) yields
# "authentication required". One connection per host — extras lock the
# deploy dropdown on a leftover Granite-named secret.
ensure_incluster_registry_oci_connections() {
  local ns
  for ns in ${DS_PROJECTS}; do
    INCLUSTER_OCI_CONNECTION_NAME="${INCLUSTER_OCI_CONNECTION_NAME}" \
    INCLUSTER_OCI_CONNECTION_DISPLAY="${INCLUSTER_OCI_CONNECTION_DISPLAY}" \
    INCLUSTER_OCI_HOST="${INCLUSTER_OCI_HOST}" \
    NS="${ns}" python3 - <<'PY'
import base64, json, os, subprocess, sys

ns = os.environ["NS"]
want_name = os.environ["INCLUSTER_OCI_CONNECTION_NAME"]
display = os.environ["INCLUSTER_OCI_CONNECTION_DISPLAY"]
host = os.environ["INCLUSTER_OCI_HOST"]
desc = (
    "OCI pull host for ModelCars in the in-cluster image registry. "
    "Requires kubernetes.io/dockerconfigjson (auths wrapper). "
    "Shared by every image-registry.openshift-image-registry.svc ModelCar."
)
want_type = "kubernetes.io/dockerconfigjson"

def oc_json(*args):
    return json.loads(subprocess.check_output(["oc", *args]))

def oc_run(*args, check=True):
    return subprocess.run(["oc", *args], check=check, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

def decode(data, key):
    raw = (data or {}).get(key)
    if not raw:
        return ""
    return base64.b64decode(raw).decode()

def default_sa_auths(namespace):
    sa = oc_json("get", "sa", "default", "-n", namespace, "-o", "json")
    auths = {}
    for ref in sa.get("imagePullSecrets") or []:
        name = ref.get("name")
        if not name:
            continue
        sec = oc_json("get", "secret", name, "-n", namespace, "-o", "json")
        data = sec.get("data") or {}
        if ".dockerconfigjson" in data:
            cfg = json.loads(base64.b64decode(data[".dockerconfigjson"]))
            if isinstance(cfg.get("auths"), dict):
                auths.update(cfg["auths"])
            elif isinstance(cfg, dict):
                # Mis-uploaded legacy dockercfg stored in the dockerconfigjson key.
                auths.update({k: v for k, v in cfg.items() if k != "auths" and isinstance(v, dict)})
        if ".dockercfg" in data:
            cfg = json.loads(base64.b64decode(data[".dockercfg"]))
            if isinstance(cfg, dict):
                auths.update(cfg)
    return auths

def is_incluster_oci(secret):
    ann = secret.get("metadata", {}).get("annotations") or {}
    protocol = ann.get("opendatahub.io/connection-type-protocol")
    ref = ann.get("opendatahub.io/connection-type-ref")
    if protocol != "oci" and ref != "oci-v1":
        return False
    got = decode(secret.get("data"), "OCI_HOST")
    return "image-registry.openshift-image-registry.svc" in got

def apply_secret(doc):
    proc = subprocess.run(
        ["oc", "apply", "-f", "-"],
        input=json.dumps(doc).encode(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode() or "oc apply failed\n")
        sys.exit(proc.returncode)

auths = default_sa_auths(ns)
if not auths:
    print(f"  [WARN] {ns}: default SA has no image pull auths; skip in-cluster OCI connection", file=sys.stderr)
    sys.exit(0)
if host not in auths:
    print(f"  [WARN] {ns}: default SA auths missing {host}", file=sys.stderr)

dockerconfigjson = json.dumps({"auths": auths}, separators=(",", ":"))
doc = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": want_name,
        "namespace": ns,
        "labels": {"opendatahub.io/dashboard": "true"},
        "annotations": {
            "opendatahub.io/connection-type-protocol": "oci",
            "opendatahub.io/connection-type-ref": "oci-v1",
            "openshift.io/display-name": display,
            "openshift.io/description": desc,
        },
    },
    "type": want_type,
    "stringData": {
        "ACCESS_TYPE": '["Pull"]',
        "OCI_HOST": host,
        ".dockerconfigjson": dockerconfigjson,
    },
}

secrets = oc_json("get", "secrets", "-n", ns, "-o", "json")
existing = [s for s in secrets.get("items") or [] if is_incluster_oci(s)]
canonical = next((s for s in existing if s["metadata"]["name"] == want_name), None)
if canonical and canonical.get("type") != want_type:
    oc_run("delete", "secret", want_name, "-n", ns, "--ignore-not-found=true")

apply_secret(doc)

for secret in existing:
    extra = secret["metadata"]["name"]
    if extra == want_name:
        continue
    oc_run("delete", "secret", extra, "-n", ns, "--ignore-not-found=true")
    print(f"  [OK] {ns}: removed leftover OCI connection {extra}", file=sys.stderr)

print(f"  [OK] {ns}/{want_name} ({display})", file=sys.stderr)
PY
  done
}
