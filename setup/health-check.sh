#!/bin/bash
# Health check after overnight shutdown. --fix is known recovery only
# (per-pool GPU MachineSet from 0, Let's Encrypt re-issue under 30 days,
# dashboard flags, DSC ogx status, NemoGuardrails list CRD, MCP catalog lock,
# Open WebUI bounce). --fix does not clone MachineSets or start stopped VMs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

FIX=0
if [ "${1:-}" = "--fix" ]; then
  FIX=1
fi

PASS=0
WARN=0
FAIL=0
pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
section() { echo ""; echo "── $1 ──"; }

echo "=== Workshop health check ==="
[ "${FIX}" -eq 1 ] && echo "(--fix: known recovery only)"

section "1. OpenShift cluster"
pass "Authenticated as $(oc whoami)"
API_STATUS=$(oc get --raw /healthz 2>/dev/null || echo "error")
if [ "${API_STATUS}" = "ok" ]; then
  pass "API server healthy"
else
  fail "API server returned: ${API_STATUS}"
fi

TOTAL_NODES=$(oc get nodes --no-headers 2>/dev/null | wc -l)
READY_NODES=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{n++} END{print n+0}')
if [ "${READY_NODES}" -eq "${TOTAL_NODES}" ] && [ "${TOTAL_NODES}" -gt 0 ]; then
  pass "All ${TOTAL_NODES} nodes Ready"
else
  warn "${READY_NODES}/${TOTAL_NODES} nodes Ready"
fi

section "2. Operators"
check_csv() {
  local ns="$1" pattern="$2" label="$3"
  local csv_line
  csv_line=$(oc get csv -n "${ns}" --no-headers 2>/dev/null | grep "${pattern}" | head -1)
  if [ -z "${csv_line}" ]; then
    fail "${label}: CSV not found in ${ns}"
  else
    local phase name
    phase=$(echo "${csv_line}" | awk '{print $NF}')
    name=$(echo "${csv_line}" | awk '{print $1}')
    if [ "${phase}" = "Succeeded" ]; then
      pass "${label}: ${name}"
    else
      fail "${label}: ${name} (${phase})"
    fi
  fi
}
check_csv "openshift-nfd" "nfd" "NFD Operator"
check_csv "nvidia-gpu-operator" "gpu-operator" "GPU Operator"
check_csv "redhat-ods-operator" "rhods-operator" "OpenShift AI Operator"
check_csv "cert-manager-operator" "cert-manager" "cert-manager"
check_csv "openshift-kueue-operator" "kueue-operator" "Kueue Operator"

section "3. GPU MachineSets and capacity"
MAC_REPLICAS="$(oc get deploy machine-api-controllers -n openshift-machine-api \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")"
if [ "${MAC_REPLICAS}" = "0" ]; then
  fail "machine-api-controllers replicas=0 (overnight pause). --fix does not start VMs."
  echo "        Morning path: ./setup/overnight-start.sh"
fi

check_gpu_pool() {
  local pool="$1"
  local last_key="$2"
  local per_node="$3"
  local default_last="$4"
  local info name replicas last
  info="$(find_gpu_machineset "${pool}")"
  if [ -z "${info}" ]; then
    fail "No ${pool} GPU MachineSet"
    if [ "${FIX}" -eq 1 ]; then
      echo "        --fix will not clone a MachineSet. Run ./setup/03-prereqs.sh"
    fi
    return 0
  fi
  name="${info%%|*}"
  replicas="${info##*|}"
  pass "${pool} MachineSet ${name} replicas=${replicas}"
  last="$(get_cred "${last_key}" || echo "${default_last}")"
  if ! [[ "${last}" =~ ^[0-9]+$ ]]; then
    last="${default_last}"
  fi
  if [ "${FIX}" -eq 1 ] && [ "${MAC_REPLICAS}" != "0" ] && [ "${replicas}" -lt "${last}" ]; then
    echo "        Scaling ${name} to last replicas ${last}..."
    oc scale machineset "${name}" -n openshift-machine-api --replicas="${last}"
    wait_for_ready_nodes "workshop.opendatahub.io/l4-count=${per_node}" "${last}" "${pool}" 900 || true
    info="$(find_gpu_machineset "${pool}")"
    replicas="${info##*|}"
  fi
  if [ "${replicas:-0}" -eq 0 ]; then
    if [ "${last}" -gt 0 ]; then
      warn "${pool} replicas=0 (last ${last}). Overnight: ./setup/overnight-start.sh  Day-2: ./setup/scale-gpu.sh --${pool} ${last}"
    else
      pass "${pool} replicas=0 (student pool stays down until ./setup/scale-students.sh)"
    fi
    return 0
  fi
  local ready
  ready="$(oc get nodes -l "workshop.opendatahub.io/l4-count=${per_node}" --no-headers 2>/dev/null \
    | awk '$2=="Ready"{n++} END{print n+0}')"
  if [ "${ready}" -ge "${replicas}" ]; then
    pass "${ready} Ready ${pool} node(s)"
  else
    fail "${pool}: ${ready}/${replicas} Ready nodes"
    report_gpu_machines || true
    echo "        If GCP reports ZONE_RESOURCE_POOL_EXHAUSTED:"
    echo "        ./setup/switch-gpu-az.sh --list"
    echo "        ./setup/switch-gpu-az.sh --az <zone>"
  fi
  local all_ok=1
  while read -r node; do
    [ -n "${node}" ] || continue
    local alloc present
    alloc=$(oc get node "${node}" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo 0)
    present=$(oc get node "${node}" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.present}' 2>/dev/null || echo "")
    echo "        ${node}: present=${present:-?} allocatable=${alloc:-0} (want ${per_node})"
    if [ "${alloc:-0}" != "${per_node}" ]; then
      all_ok=0
    fi
  done < <(oc get nodes -l "workshop.opendatahub.io/l4-count=${per_node}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if [ "${all_ok}" -eq 1 ] && [ "${ready}" -ge 1 ]; then
    pass "${pool} allocatable nvidia.com/gpu=${per_node}"
  elif [ "${replicas}" -gt 0 ]; then
    fail "${pool} allocatable is not ${per_node} on every up node"
    if [ "${FIX}" -eq 1 ]; then
      echo "        Waiting for GPU Operator / NFD..."
      for i in $(seq 1 60); do
        sleep 10
        alloc=$(oc get nodes -l "workshop.opendatahub.io/l4-count=${per_node}" \
          -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo 0)
        if [ "${alloc}" = "${per_node}" ]; then
          pass "${pool} GPU capacity recovered"
          FAIL=$((FAIL - 1))
          break
        fi
        echo "        ... allocatable=${alloc} (${i}/60)"
      done
    fi
  fi
}

check_gpu_pool 4l4 GPU_4L4_LAST_REPLICAS "${GPU_4L4_COUNT}" "${GPU_4L4_REPLICAS}"
check_gpu_pool 2l4 GPU_2L4_LAST_REPLICAS "${GPU_2L4_COUNT}" "${GPU_2L4_REPLICAS}"

if oc get nfd.nfd.openshift.io nfd-instance -n openshift-nfd &>/dev/null \
   || oc get nodefeaturediscovery nfd-instance -n openshift-nfd &>/dev/null; then
  pass "NodeFeatureDiscovery instance present"
else
  fail "NFD instance missing"
  if [ "${FIX}" -eq 1 ]; then
    echo "        Re-applying NFD / GPU ClusterPolicy..."
    bash "${SCRIPT_DIR}/05-configure-gpu.sh" || true
  fi
fi

if oc get servicemonitor nvidia-dcgm-exporter -n nvidia-gpu-operator &>/dev/null; then
  pass "DCGM ServiceMonitor nvidia-dcgm-exporter"
else
  fail "DCGM ServiceMonitor missing (Observe & monitor GPU consumption empty)"
  if [ "${FIX}" -eq 1 ]; then
    oc label ns nvidia-gpu-operator openshift.io/cluster-monitoring=true --overwrite >/dev/null || true
    oc apply -f "${SCRIPT_DIR}/../manifests/operators/gpu-cluster-policy.yaml" || true
    oc apply -f "${SCRIPT_DIR}/../manifests/operators/dcgm-servicemonitor.yaml" || true
  fi
fi

section "3b. Let's Encrypt certificates"
DOMAIN="$(cluster_domain)"
CONSOLE_HOST="console-openshift-console.${DOMAIN}"
TLS_JSON="$(python3 - "${CONSOLE_HOST}" <<'PY'
import json, subprocess, sys
from datetime import datetime, timezone
host = sys.argv[1]
try:
    pem = subprocess.check_output(
        ["openssl", "s_client", "-servername", host, "-connect", f"{host}:443"],
        input=b"",
        stderr=subprocess.DEVNULL,
        timeout=20,
    )
    meta = subprocess.check_output(
        ["openssl", "x509", "-noout", "-issuer", "-enddate"],
        input=pem,
        stderr=subprocess.DEVNULL,
        timeout=10,
    ).decode()
except Exception as exc:
    print(json.dumps({"ok": False, "error": str(exc)}))
    sys.exit(0)
issuer = ""
end = ""
for line in meta.splitlines():
    if line.startswith("issuer="):
        issuer = line.split("=", 1)[1]
    elif line.startswith("notAfter="):
        end = line.split("=", 1)[1]
days = None
if end:
    try:
        dt = datetime.strptime(end, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
        days = int((dt - datetime.now(timezone.utc)).total_seconds() // 86400)
    except ValueError:
        days = None
blob = (issuer + " " + end).lower()
ingress_ca = any(
    marker in blob
    for marker in (
        "ingress-operator",
        "kubernetes ingress controller",
        "openshift-ingress-operator",
        "ingresscontroller",
    )
)
print(json.dumps({"ok": True, "issuer": issuer, "not_after": end, "days": days, "ingress_ca": ingress_ca}))
PY
)"
python3 -c "import json,sys; json.loads(sys.argv[1])" "${TLS_JSON}" 2>/dev/null || TLS_JSON='{"ok":false}'
TLS_OK="$(echo "${TLS_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok'))")"
if [ "${TLS_OK}" != "True" ]; then
  fail "Could not read console certificate for ${CONSOLE_HOST}"
else
  ISSUER="$(echo "${TLS_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('issuer',''))")"
  DAYS="$(echo "${TLS_JSON}" | python3 -c "import json,sys; d=json.load(sys.stdin).get('days'); print('' if d is None else d)")"
  INGRESS_CA="$(echo "${TLS_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ingress_ca'))")"
  echo "        issuer: ${ISSUER}"
  echo "        days remaining: ${DAYS:-unknown}"
  if [ "${INGRESS_CA}" = "True" ]; then
    fail "Console cert is the cluster ingress CA (need Let's Encrypt)"
    if [ "${FIX}" -eq 1 ]; then
      echo "        Re-issuing certificates..."
      bash "${SCRIPT_DIR}/02-configure-access.sh" --certs-only || true
    fi
  else
    pass "Console cert is not the cluster ingress CA"
  fi
  if [ -n "${DAYS}" ] && [ "${DAYS}" -lt 30 ]; then
    fail "Console cert expires in ${DAYS} day(s) (< 30)"
    if [ "${FIX}" -eq 1 ]; then
      echo "        Re-issuing certificates (expiry < 30 days)..."
      bash "${SCRIPT_DIR}/02-configure-access.sh" --certs-only || true
    fi
  elif [ -n "${DAYS}" ]; then
    pass "Console cert valid for ${DAYS} more day(s)"
  fi
fi

section "4. OpenShift AI"
DSC_PHASE=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "${DSC_PHASE}" = "Ready" ]; then
  pass "DataScienceCluster: Ready"
else
  fail "DataScienceCluster: ${DSC_PHASE:-not found}"
fi
MS=$(oc get dscinitialization default-dsci -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")].status}' 2>/dev/null || echo "")
if [ "${MS}" = "True" ]; then
  pass "DSCI MonitoringStackAvailable (Observe & monitor metrics)"
else
  fail "DSCI MonitoringStackAvailable=${MS:-False} (Average compute consumption stays empty)"
  if [ "${FIX}" -eq 1 ]; then
    oc apply -f "${SCRIPT_DIR}/../manifests/operators/coo-subscription.yaml" || true
    oc apply -f "${SCRIPT_DIR}/../manifests/operators/opentelemetry-subscription.yaml" || true
    oc apply -f "${SCRIPT_DIR}/../manifests/rhoai/dscinitialization.yaml" || true
  fi
fi
RHOAI_HOST="$(rhoai_dashboard_host)"
if [ -n "${RHOAI_HOST}" ]; then
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${RHOAI_HOST}/" 2>/dev/null || echo "000")
  if [ "${CODE}" = "200" ] || [ "${CODE}" = "301" ] || [ "${CODE}" = "302" ] || [ "${CODE}" = "403" ]; then
    pass "Dashboard Route reachable (${RHOAI_HOST}, HTTP ${CODE})"
  else
    fail "Dashboard Route HTTP ${CODE}"
  fi
else
  fail "OpenShift AI dashboard Route not found"
fi

IS_COUNT=$(oc get inferenceservice -A --no-headers 2>/dev/null | wc -l)
if [ "${IS_COUNT}" -eq 0 ]; then
  pass "No InferenceServices (expected unless a lab is in progress)"
else
  warn "${IS_COUNT} InferenceService(s) present — leftover from a previous run?"
  oc get inferenceservice -A --no-headers 2>/dev/null | while read -r line; do
    echo "        ${line}"
  done
  if [ "${FIX}" -eq 1 ]; then
    force_delete_failed_predictors
  fi
fi

if oc get clusterqueue gpu-pool-4l4 &>/dev/null && oc get clusterqueue gpu-pool-2l4 &>/dev/null; then
  pass "Kueue ClusterQueues gpu-pool-4l4 and gpu-pool-2l4"
  CQ_COHORT4="$(oc get clusterqueue gpu-pool-4l4 -o jsonpath='{.spec.cohortName}' 2>/dev/null || true)"
  CQ_COHORT2="$(oc get clusterqueue gpu-pool-2l4 -o jsonpath='{.spec.cohortName}' 2>/dev/null || true)"
  if [ "${CQ_COHORT4}" = "workshop-gpu" ] && [ "${CQ_COHORT2}" = "workshop-gpu" ]; then
    pass "ClusterQueues share cohortName workshop-gpu (rehearsal borrow)"
  else
    fail "ClusterQueue cohortName missing (v1beta2 uses cohortName, not cohort); C3 stays SchedulingGated"
    if [ "${FIX}" -eq 1 ]; then
      oc apply -f "${SCRIPT_DIR}/../manifests/kueue/cluster-queue.yaml" || true
    fi
  fi
else
  fail "ClusterQueue gpu-pool-4l4 or gpu-pool-2l4 not found"
  if [ "${FIX}" -eq 1 ]; then
    oc apply -f "${SCRIPT_DIR}/../manifests/kueue/cluster-queue.yaml" || true
    oc apply -f "${SCRIPT_DIR}/../manifests/kueue/local-queues.yaml" || true
  fi
fi

FLAVOR_TOL=$(oc get resourceflavor l4-gpu-4 -o jsonpath='{.spec.tolerations}' 2>/dev/null || true)
FLAVOR_TOL2=$(oc get resourceflavor l4-gpu-2 -o jsonpath='{.spec.tolerations}' 2>/dev/null || true)
if echo "${FLAVOR_TOL}${FLAVOR_TOL2}" | grep -q 'nvidia.com/gpu'; then
  pass "ResourceFlavors l4-gpu-4 / l4-gpu-2 inject GPU taint toleration"
else
  fail "ResourceFlavor missing spec.tolerations for nvidia.com/gpu (predictors stay SchedulingGated)"
  if [ "${FIX}" -eq 1 ]; then
    echo "        Re-applying manifests/kueue/resource-flavor.yaml..."
    oc apply -f "${SCRIPT_DIR}/../manifests/kueue/resource-flavor.yaml" || true
  fi
fi

AUTH_OK=1
for ns in ${DS_PROJECTS}; do
  if oc get sa workshop-infer -n "${ns}" &>/dev/null \
     && oc get networkpolicy allow-openshift-ingress -n "${ns}" &>/dev/null \
     && oc get networkpolicy allow-from-openshift-monitoring -n "${ns}" &>/dev/null; then
    pass "workshop-infer SA, ingress NP, and metrics scrape NP in ${ns}"
  else
    AUTH_OK=0
    fail "workshop-infer SA or NetworkPolicy missing in ${ns} (Observe models stay No data)"
  fi
done
if ! oc get prometheusrule kserve-vllm-recording-rules -n "${PRESENTER_PROJECT}" &>/dev/null; then
  AUTH_OK=0
  fail "PrometheusRule kserve-vllm-recording-rules missing (Observe Deployed models stays No data)"
else
  pass "PrometheusRule kserve-vllm-recording-rules"
fi
if [ "${AUTH_OK}" -eq 0 ] && [ "${FIX}" -eq 1 ]; then
  echo "        Re-applying inference-auth.yaml, networkpolicies.yaml, kserve-vllm-prometheusrule.yaml..."
  oc apply -f "${SCRIPT_DIR}/../manifests/projects/inference-auth.yaml" || true
  oc apply -f "${SCRIPT_DIR}/../manifests/projects/networkpolicies.yaml" || true
  oc apply -f "${SCRIPT_DIR}/../manifests/projects/kserve-vllm-prometheusrule.yaml" || true
fi

CATALOG_CONN_OK=0
for ns in ${DS_PROJECTS}; do
  if oc get secrets -n "${ns}" -o json 2>/dev/null | \
     CATALOG_OCI_HOST="${CATALOG_OCI_HOST}" \
     CATALOG_OCI_CONNECTION_DISPLAY="${CATALOG_OCI_CONNECTION_DISPLAY}" \
     python3 -c '
import base64, json, os, sys
host = os.environ["CATALOG_OCI_HOST"]
display = os.environ["CATALOG_OCI_CONNECTION_DISPLAY"]
data = json.load(sys.stdin)
for secret in data.get("items") or []:
    ann = secret.get("metadata", {}).get("annotations") or {}
    if ann.get("opendatahub.io/connection-type-ref") != "oci-v1":
        continue
    raw = (secret.get("data") or {}).get("OCI_HOST")
    got = base64.b64decode(raw).decode() if raw else ""
    if got != host:
        continue
    if ann.get("openshift.io/display-name") != display:
        sys.exit(1)
    sys.exit(0)
sys.exit(1)
' ; then
    CATALOG_CONN_OK=$((CATALOG_CONN_OK + 1))
    pass "Catalog OCI connection ${CATALOG_OCI_CONNECTION_DISPLAY} in ${ns}"
  else
    fail "Catalog OCI connection ${CATALOG_OCI_CONNECTION_DISPLAY} missing in ${ns}"
  fi
done
if [ "${CATALOG_CONN_OK}" -lt 3 ] && [ "${FIX}" -eq 1 ]; then
  echo "        Creating ${CATALOG_OCI_CONNECTION_DISPLAY} in Data Science Projects..."
  ensure_redhat_catalog_oci_connections || true
fi

INCLUSTER_CONN_OK=0
for ns in ${DS_PROJECTS}; do
  if oc get secrets -n "${ns}" -o json 2>/dev/null | \
     INCLUSTER_OCI_HOST="${INCLUSTER_OCI_HOST}" \
     INCLUSTER_OCI_CONNECTION_DISPLAY="${INCLUSTER_OCI_CONNECTION_DISPLAY}" \
     python3 -c '
import base64, json, os, sys
host = os.environ["INCLUSTER_OCI_HOST"]
display = os.environ["INCLUSTER_OCI_CONNECTION_DISPLAY"]
data = json.load(sys.stdin)
for secret in data.get("items") or []:
    if secret.get("type") != "kubernetes.io/dockerconfigjson":
        continue
    ann = secret.get("metadata", {}).get("annotations") or {}
    raw = (secret.get("data") or {}).get("OCI_HOST")
    got = base64.b64decode(raw).decode() if raw else ""
    if got != host:
        continue
    cfg_raw = (secret.get("data") or {}).get(".dockerconfigjson")
    if not cfg_raw:
        continue
    cfg = json.loads(base64.b64decode(cfg_raw))
    auths = cfg.get("auths") if isinstance(cfg.get("auths"), dict) else {}
    if host not in auths:
        continue
    if ann.get("openshift.io/display-name") != display:
        sys.exit(1)
    sys.exit(0)
sys.exit(1)
' ; then
    INCLUSTER_CONN_OK=$((INCLUSTER_CONN_OK + 1))
    pass "In-cluster registry OCI connection ${INCLUSTER_OCI_CONNECTION_DISPLAY} in ${ns}"
  else
    fail "In-cluster registry OCI connection ${INCLUSTER_OCI_CONNECTION_DISPLAY} missing in ${ns}"
  fi
done
if [ "${INCLUSTER_CONN_OK}" -lt 3 ] && [ "${FIX}" -eq 1 ]; then
  echo "        Creating ${INCLUSTER_OCI_CONNECTION_DISPLAY} (dockerconfigjson) in Data Science Projects..."
  ensure_incluster_registry_oci_connections || true
fi

section "5. CPU workbench"
if oc get notebook "${WORKBENCH_NAME}" -n "${WORKBENCH_PROJECT}" &>/dev/null; then
  WB_PHASE=$(oc get pods -n "${WORKBENCH_PROJECT}" -l "notebook-name=${WORKBENCH_NAME}" --no-headers 2>/dev/null | awk '{print $3}' | head -1 || echo "")
  if [ "${WB_PHASE}" = "Running" ]; then
    pass "Workbench ${WORKBENCH_PROJECT}/${WORKBENCH_NAME} Running"
  else
    fail "Workbench ${WORKBENCH_PROJECT}/${WORKBENCH_NAME} ${WB_PHASE:-missing}"
    if [ "${FIX}" -eq 1 ]; then
      echo "        Restarting workbench..."
      oc annotate notebook "${WORKBENCH_NAME}" -n "${WORKBENCH_PROJECT}" kubeflow-resource-stopped- --overwrite 2>/dev/null || true
      oc delete pod -n "${WORKBENCH_PROJECT}" -l "notebook-name=${WORKBENCH_NAME}" --force --grace-period=0 2>/dev/null || true
    fi
  fi
  WB_POD=$(oc get pod -n "${WORKBENCH_PROJECT}" -l "notebook-name=${WORKBENCH_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "${WB_POD}" ] && oc exec -n "${WORKBENCH_PROJECT}" "${WB_POD}" -c "${WORKBENCH_NAME}" -- \
      test -f "/opt/app-root/src/llm-on-openshift/${WORKBENCH_NOTEBOOK_REL}" >/dev/null 2>&1; then
    pass "Red Hat llm-on-openshift LangChain notebook present on PVC"
  else
    warn "LangChain example notebook not found on workbench PVC (re-run ./setup/09-deploy-workbench.sh)"
  fi
else
  fail "Workbench ${WORKBENCH_PROJECT}/${WORKBENCH_NAME} not found"
  if [ "${FIX}" -eq 1 ]; then
    echo "        --fix will not create the workbench. Run ./setup/09-deploy-workbench.sh"
  fi
fi

section "6. Open WebUI"
if oc get deploy open-webui -n open-webui &>/dev/null; then
  READY=$(oc get deploy open-webui -n open-webui -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  DESIRED=$(oc get deploy open-webui -n open-webui -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  if [ "${READY}" = "${DESIRED}" ] && [ "${READY}" != "0" ]; then
    pass "Open WebUI Deployment ${READY}/${DESIRED}"
  else
    fail "Open WebUI Deployment ${READY:-0}/${DESIRED:-?}"
    if [ "${FIX}" -eq 1 ]; then
      echo "        Restarting Open WebUI..."
      oc rollout restart deployment/open-webui -n open-webui
      oc rollout status deployment/open-webui -n open-webui --timeout=180s || true
    fi
  fi
  HOST=$(oc get route open-webui -n open-webui -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "${HOST}" ]; then
    CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${HOST}/" 2>/dev/null || echo "000")
    if [ "${CODE}" = "200" ] || [ "${CODE}" = "302" ]; then
      pass "Open WebUI Route HTTP ${CODE}"
    else
      fail "Open WebUI Route HTTP ${CODE}"
      if [ "${FIX}" -eq 1 ]; then
        oc rollout restart deployment/open-webui -n open-webui
        oc rollout status deployment/open-webui -n open-webui --timeout=180s || true
      fi
    fi
  else
    fail "Open WebUI Route missing"
  fi
  if open_webui_has_legacy_function_calling >/dev/null 2>&1; then
    pass "Open WebUI sqlite function_calling=legacy"
  else
    warn "Open WebUI sqlite missing function_calling=legacy (env DEFAULT_MODEL_PARAMS still applies on a fresh PVC)"
  fi
  if open_webui_has_no_default_openai >/dev/null 2>&1; then
    pass "Open WebUI has no default api.openai.com connection"
  else
    fail "Open WebUI still lists api.openai.com (no internet egress → Connection error)"
    if [ "${FIX}" -eq 1 ]; then
      patch_open_webui_sqlite || true
      oc rollout restart deployment/open-webui -n open-webui >/dev/null || true
      oc rollout status deployment/open-webui -n open-webui --timeout=180s || true
    fi
  fi
else
  fail "Open WebUI Deployment not found"
fi

section "7. Model Registry and MCP"
MR_PHASE="$(oc get modelregistry.modelregistry.opendatahub.io "${MODEL_REGISTRY_NAME}" -n "${MODEL_REGISTRY_NS}" \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
if [ -z "${MR_PHASE}" ]; then
  MR_PHASE="$(oc get modelregistry.modelregistry.opendatahub.io "${MODEL_REGISTRY_NAME}" -n "${MODEL_REGISTRY_NS}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
fi
if [ "${MR_PHASE}" = "True" ]; then
  pass "ModelRegistry ${MODEL_REGISTRY_NS}/${MODEL_REGISTRY_NAME} Ready"
else
  fail "ModelRegistry ${MODEL_REGISTRY_NS}/${MODEL_REGISTRY_NAME} ${MR_PHASE:-not found}"
  if [ "${FIX}" -eq 1 ]; then
    echo "        Re-applying Model Registry / MCP..."
    bash "${SCRIPT_DIR}/10-deploy-registry-mcp.sh" || true
  fi
fi

DASH_FLAGS="$(oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig.mcpCatalog} {.spec.dashboardConfig.mcpRegistry} {.spec.dashboardConfig.disableModelRegistry} {.spec.dashboardConfig.genAiStudio}' 2>/dev/null || true)"
if echo "${DASH_FLAGS}" | grep -q '^true true false true$'; then
  pass "Dashboard MCP Catalog, MCP Registry, Model Registry, and Gen AI Studio enabled"
else
  warn "Dashboard flags mcpCatalog/mcpRegistry/disableModelRegistry/genAiStudio = '${DASH_FLAGS}' (want 'true true false true')"
  if [ "${FIX}" -eq 1 ]; then
    oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type merge \
      -p '{"spec":{"dashboardConfig":{"disableModelCatalog":false,"disableModelRegistry":false,"genAiStudio":true,"aiAssetCustomEndpoints":true,"mcpCatalog":true,"mcpRegistry":true}}}' \
      >/dev/null || true
  fi
fi

OGX_SPEC="$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.ogx.managementState}' 2>/dev/null || true)"
OGX_STATUS="$(oc get datasciencecluster default-dsc -o jsonpath='{.status.components.ogx.managementState}' 2>/dev/null || true)"
if [ "${OGX_SPEC}" = "Managed" ]; then
  pass "DSC spec ogx=Managed"
else
  fail "DSC spec ogx=${OGX_SPEC:-missing} (Playground requires Managed)"
  if [ "${FIX}" -eq 1 ]; then
    oc patch datasciencecluster default-dsc --type merge \
      -p '{"spec":{"components":{"ogx":{"managementState":"Managed"}}}}' >/dev/null || true
  fi
fi
# Dashboard Playground nav reads status, not spec.
if [ "${OGX_STATUS}" = "Managed" ] || [ "${OGX_STATUS}" = "Unmanaged" ]; then
  pass "DSC status.components.ogx=${OGX_STATUS} (Playground nav visible)"
else
  fail "DSC status.components.ogx=${OGX_STATUS:-empty} (Playground menu hidden until this is Managed)"
  if [ "${FIX}" -eq 1 ]; then
    echo "        Patching DSC status.components.ogx=Managed..."
    oc patch datasciencecluster default-dsc --subresource=status --type merge \
      -p '{"status":{"components":{"ogx":{"managementState":"Managed"}}}}' >/dev/null || true
    oc rollout restart deploy/rhods-dashboard deploy/gen-ai-ui -n redhat-ods-applications >/dev/null || true
  fi
fi

if oc get cm gen-ai-aa-mcp-servers -n redhat-ods-applications -o jsonpath='{.data}' 2>/dev/null \
    | grep -q openshift-mcp-server; then
  pass "Gen AI Playground MCP ConfigMap lists openshift-mcp-server"
else
  fail "ConfigMap gen-ai-aa-mcp-servers missing openshift-mcp-server"
  if [ "${FIX}" -eq 1 ]; then
    oc apply -f "${SCRIPT_DIR}/../manifests/mcp/gen-ai-aa-mcp-servers.yaml" || true
  fi
fi

if oc get crd nemoguardrails.trustyai.opendatahub.io &>/dev/null; then
  pass "NemoGuardrails CRD present (Playground chat list API)"
else
  fail "NemoGuardrails CRD missing (Playground chat returns HTTP 500)"
  if [ "${FIX}" -eq 1 ]; then
    oc apply -f "${SCRIPT_DIR}/../manifests/rhoai/nemoguardrails-crd.yaml" || true
    oc rollout restart deploy/gen-ai-ui -n redhat-ods-applications >/dev/null || true
  fi
fi

MCP_OP="$(oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=mcp-lifecycle-operator \
  --no-headers 2>/dev/null | awk '$3=="Running"{n++} END{print n+0}')"
if [ "${MCP_OP}" -ge 1 ]; then
  pass "MCP Lifecycle Operator pod Running"
else
  fail "MCP Lifecycle Operator pod not Running"
fi

MCP_READY="$(oc get mcpserver "${MCP_SERVER_NAME}" -n "${PRESENTER_PROJECT}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [ "${MCP_READY}" = "True" ]; then
  pass "MCPServer ${PRESENTER_PROJECT}/${MCP_SERVER_NAME} Ready (Technology Preview)"
else
  fail "MCPServer ${PRESENTER_PROJECT}/${MCP_SERVER_NAME} ${MCP_READY:-not found}"
  if [ "${FIX}" -eq 1 ]; then
    echo "        Re-applying Model Registry / MCP..."
    bash "${SCRIPT_DIR}/10-deploy-registry-mcp.sh" || true
  fi
fi

# ClusterRole view cannot list core nodes. C3b needs this for worker-gpu inventory.
if oc auth can-i list nodes --as="system:serviceaccount:${PRESENTER_PROJECT}:mcp-viewer" >/dev/null 2>&1; then
  pass "mcp-viewer can list nodes (C3b GPU inventory)"
else
  fail "mcp-viewer cannot list nodes (ClusterRole view is not enough; C3b MCP will 403)"
  if [ "${FIX}" -eq 1 ]; then
    oc apply -f "${SCRIPT_DIR}/../manifests/mcp/rbac.yaml" || true
    if oc auth can-i list nodes --as="system:serviceaccount:${PRESENTER_PROJECT}:mcp-viewer" >/dev/null 2>&1; then
      pass "mcp-viewer can list nodes after rbac.yaml"
    else
      fail "mcp-viewer still cannot list nodes after rbac.yaml"
    fi
  fi
fi

if oc get cm mcp-catalog-sources -n rhoai-model-registries -o jsonpath='{.data.sources\.yaml}' 2>/dev/null \
    | grep -q workshop_custom_mcp; then
  pass "Custom MCP catalog ConfigMap workshop_custom_mcp"
else
  warn "Custom MCP catalog source missing (re-run ./setup/10-deploy-registry-mcp.sh for C2b)"
  if [ "${FIX}" -eq 1 ]; then
    bash "${SCRIPT_DIR}/10-deploy-registry-mcp.sh" || true
  fi
fi

if mcp_catalog_has_workshop_server; then
  pass "MCP Catalog API lists workshop-custom-mcp (search C2b)"
else
  fail "MCP Catalog API has no workshop-custom-mcp (stale catalog-leader lock?)"
  if [ "${FIX}" -eq 1 ]; then
    recover_model_catalog_leader || true
    sleep 8
    if mcp_catalog_has_workshop_server; then
      pass "MCP Catalog API lists workshop-custom-mcp after leader recover"
    else
      fail "workshop-custom-mcp still missing after leader recover"
    fi
  fi
fi

section "8. Lab guide"
if oc get deploy lab-guide -n lab-guide &>/dev/null; then
  READY=$(oc get deploy lab-guide -n lab-guide -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  if [ "${READY}" != "0" ]; then
    pass "Lab guide Deployment Ready"
  else
    fail "Lab guide Deployment not Ready"
    if [ "${FIX}" -eq 1 ]; then
      echo "        Refreshing env.json and restarting lab guide..."
      write_lab_guide_env || true
      oc rollout restart deployment/lab-guide -n lab-guide
      oc rollout status deployment/lab-guide -n lab-guide --timeout=180s || true
    fi
  fi
  HOST=$(oc get route lab-guide -n lab-guide -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "${HOST}" ]; then
    CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${HOST}/" 2>/dev/null || echo "000")
    if [ "${CODE}" = "200" ] || [ "${CODE}" = "302" ]; then
      pass "Presenter guide Route HTTP ${CODE} (https://${HOST})"
    else
      fail "Presenter guide Route HTTP ${CODE}"
      if [ "${FIX}" -eq 1 ]; then
        echo "        Refreshing env.json and restarting lab guide..."
        write_lab_guide_env || true
        oc rollout restart deployment/lab-guide -n lab-guide
        oc rollout status deployment/lab-guide -n lab-guide --timeout=180s || true
      fi
    fi
  else
    fail "Presenter guide Route missing"
  fi
  PLAY=$(oc get route playground -n lab-guide -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "${PLAY}" ]; then
    PCODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${PLAY}/" 2>/dev/null || echo "000")
    if [ "${PCODE}" = "200" ] || [ "${PCODE}" = "302" ]; then
      pass "Playground Route HTTP ${PCODE} (https://${PLAY})"
    else
      fail "Playground Route HTTP ${PCODE}"
    fi
  else
    fail "Playground Route missing"
  fi
else
  fail "Lab guide Deployment not found"
fi

section "9. S4 demo object storage (C4 / C4b)"
if oc get deploy s4 -n "${S4_NS}" &>/dev/null; then
  READY=$(oc get deploy s4 -n "${S4_NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  if [ "${READY}" != "0" ]; then
    pass "S4 Deployment Ready (demo S3; not enterprise storage)"
  else
    fail "S4 Deployment not Ready"
    if [ "${FIX}" -eq 1 ]; then
      oc rollout restart deployment/s4 -n "${S4_NS}" >/dev/null || true
      oc rollout status deployment/s4 -n "${S4_NS}" --timeout=180s || true
    fi
  fi
  HOST=$(oc get route s4 -n "${S4_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "${HOST}" ]; then
    CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${HOST}/" 2>/dev/null || echo "000")
    if [ "${CODE}" = "200" ] || [ "${CODE}" = "302" ] || [ "${CODE}" = "401" ]; then
      pass "S4 UI Route HTTP ${CODE}"
    else
      fail "S4 UI Route HTTP ${CODE}"
    fi
  else
    fail "S4 Route missing"
  fi
  CONN_OK=0
  for ns in ${DS_PROJECTS}; do
    if oc get secret "${S4_CONNECTION_NAME}" -n "${ns}" >/dev/null 2>&1; then
      CONN_OK=$((CONN_OK + 1))
    fi
  done
  if [ "${CONN_OK}" -ge 1 ]; then
    pass "S3 connection ${S4_CONNECTION_NAME} in ${CONN_OK} Data Science Project(s)"
  else
    fail "S3 connection ${S4_CONNECTION_NAME} missing"
    if [ "${FIX}" -eq 1 ]; then
      bash "${SCRIPT_DIR}/12-deploy-s4.sh" || true
    fi
  fi
  if oc get job s4-seed -n "${S4_NS}" -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -qx 1; then
    pass "C4 s4-seed Job Complete (Qwen 7B → s3://${S4_BUCKET}/${HF_C4_PREFIX}/)"
  else
    warn "C4 s4-seed Job not Complete yet (./setup/12-deploy-s4.sh)"
  fi
  if oc get istag "${HF_C4B_IS}:${HF_C4B_TAG}" -n "${PRESENTER_PROJECT}" >/dev/null 2>&1; then
    pass "C4b ModelCar ImageStreamTag ${HF_C4B_IS}:${HF_C4B_TAG}"
  else
    warn "C4b ModelCar ${HF_C4B_IS}:${HF_C4B_TAG} not built yet (oc start-build -n ${PRESENTER_PROJECT} ${HF_C4B_IS})"
  fi
else
  fail "S4 Deployment not found (C4 needs ./setup/12-deploy-s4.sh)"
  if [ "${FIX}" -eq 1 ]; then
    bash "${SCRIPT_DIR}/12-deploy-s4.sh" || true
  fi
fi

section "Summary"
echo "  PASS: ${PASS}  |  WARN: ${WARN}  |  FAIL: ${FAIL}"
if [ "${FAIL}" -eq 0 ]; then
  echo "  Environment is ready."
else
  echo "  ${FAIL} check(s) failed. After cluster start: ./setup/health-check.sh --fix"
fi
echo ""
exit "${FAIL}"
