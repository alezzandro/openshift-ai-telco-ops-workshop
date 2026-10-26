#!/bin/bash
# Demo-only S3 (S4) + Hugging Face seed for C4, and a pre-built ModelCar for C4b.
# S4 is not a certified product; customers use enterprise object storage in prod.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
S4_DIR="${REPO_ROOT}/manifests/s4"
MC_DIR="${REPO_ROOT}/manifests/modelcar"
# shellcheck source=ensure-authenticated.sh
source "${SCRIPT_DIR}/ensure-authenticated.sh"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

echo "=== Deploying S4 (demo S3) and seeding C4/C4b models ==="
echo "  S4 is a lab stand-in. Production uses enterprise S3-compatible storage."
echo ""

echo "1. Namespace, SCC, PVC, Service, Route, NetworkPolicy..."
oc apply -f "${S4_DIR}/namespace.yaml"
oc apply -f "${S4_DIR}/sa.yaml"
oc apply -f "${S4_DIR}/pvc.yaml"
oc apply -f "${S4_DIR}/configmap.yaml"
oc apply -f "${S4_DIR}/service.yaml"
oc apply -f "${S4_DIR}/route.yaml"
oc apply -f "${S4_DIR}/networkpolicy.yaml"
echo ""

echo "2. S4 credentials (generated, gitignored)..."
S4_ACCESS="$(get_cred S4_ACCESS_KEY || true)"
S4_SECRET="$(get_cred S4_SECRET_KEY || true)"
S4_UI_USER="$(get_cred S4_UI_USER || true)"
S4_UI_PASS="$(get_cred S4_UI_PASSWORD || true)"
S4_JWT="$(get_cred S4_JWT_SECRET || true)"
if [ -z "${S4_ACCESS}" ]; then
  S4_ACCESS="$(openssl rand -hex 12)"
  set_cred S4_ACCESS_KEY "${S4_ACCESS}"
fi
if [ -z "${S4_SECRET}" ]; then
  S4_SECRET="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
  set_cred S4_SECRET_KEY "${S4_SECRET}"
fi
if [ -z "${S4_UI_USER}" ]; then
  S4_UI_USER="admin"
  set_cred S4_UI_USER "${S4_UI_USER}"
fi
if [ -z "${S4_UI_PASS}" ]; then
  S4_UI_PASS="$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
  set_cred S4_UI_PASSWORD "${S4_UI_PASS}"
fi
if [ -z "${S4_JWT}" ]; then
  S4_JWT="$(openssl rand -hex 32)"
  set_cred S4_JWT_SECRET "${S4_JWT}"
fi
oc -n "${S4_NS}" create secret generic s4-credentials \
  --from-literal=AWS_ACCESS_KEY_ID="${S4_ACCESS}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${S4_SECRET}" \
  --from-literal=UI_USERNAME="${S4_UI_USER}" \
  --from-literal=UI_PASSWORD="${S4_UI_PASS}" \
  --from-literal=JWT_SECRET="${S4_JWT}" \
  --dry-run=client -o yaml | oc apply -f -
echo "  UI user stored in setup/.generated-credentials.env"
echo ""

echo "3. Deployment (pinned ${S4_IMAGE})..."
TMP_DEP="$(mktemp)"
sed "s|image: quay.io/rh-aiservices-bu/s4:0.3.2-2|image: ${S4_IMAGE}|" \
  "${S4_DIR}/deployment.yaml" > "${TMP_DEP}"
oc apply -f "${TMP_DEP}"
rm -f "${TMP_DEP}"
oc wait deployment/s4 -n "${S4_NS}" --for=condition=Available --timeout=420s \
  || echo "  [WARN] S4 Deployment not Available yet"
echo ""

S4_HOST="$(oc get route s4 -n "${S4_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [ -n "${S4_HOST}" ]; then
  oc -n "${S4_NS}" patch cm s4-config --type merge \
    -p "{\"data\":{\"ALLOWED_ORIGINS\":\"https://${S4_HOST}\"}}" >/dev/null || true
fi

echo "4. OpenShift AI S3 connections in Data Science Projects..."
S4_ENDPOINT="http://s4.${S4_NS}.svc.cluster.local:7480"
ensure_s4_workshop_connections
echo ""

echo "5. C4b ModelCar BuildConfig (Granite 3.3 2B Instruct)..."
oc apply -f "${MC_DIR}/build.yaml"
for ns in ${DS_PROJECTS}; do
  oc adm policy add-role-to-group system:image-puller "system:serviceaccounts:${ns}" \
    -n "${PRESENTER_PROJECT}" >/dev/null 2>&1 || true
done
echo "  In-cluster registry OCI connections (dockerconfigjson pull secret)..."
ensure_incluster_registry_oci_connections
EXISTING_IS="$(oc get istag "${HF_C4B_IS}:${HF_C4B_TAG}" -n "${PRESENTER_PROJECT}" \
  -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || true)"
if [ -n "${EXISTING_IS}" ]; then
  echo "  [OK] ImageStreamTag ${HF_C4B_IS}:${HF_C4B_TAG} already present"
else
  ACTIVE_BUILD="$(oc get builds -n "${PRESENTER_PROJECT}" -l buildconfig="${HF_C4B_IS}" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${ACTIVE_BUILD}" ]; then
    echo "  [OK] ModelCar build ${ACTIVE_BUILD} already running"
  else
    echo "  Starting ModelCar build (Hugging Face download inside the build; 20–40 min)..."
    oc start-build "${HF_C4B_IS}" -n "${PRESENTER_PROJECT}" --follow=false
  fi
fi
echo ""

if [ "${SKIP_S4_SEED:-0}" = "1" ]; then
  echo "SKIP_S4_SEED=1 — not importing ${HF_C4_REPO} into S4."
else
  echo "6. Seeding s3://${S4_BUCKET}/${HF_C4_PREFIX}/ from ${HF_C4_REPO}..."
  oc -n "${S4_NS}" create configmap s4-seed --from-file=s4_seed.py="${SCRIPT_DIR}/s4_seed.py" \
    --dry-run=client -o yaml | oc apply -f -
  oc -n "${S4_NS}" delete job s4-seed --ignore-not-found
  S4_ACCESS="${S4_ACCESS}" S4_SECRET="${S4_SECRET}" S4_UI_USER="${S4_UI_USER}" \
  S4_UI_PASS="${S4_UI_PASS}" S4_NS="${S4_NS}" S4_BUCKET="${S4_BUCKET}" \
  HF_C4_REPO="${HF_C4_REPO}" HF_C4_PREFIX="${HF_C4_PREFIX}" \
  python3 - <<'PY' | oc apply -f -
import json, os
ns = os.environ["S4_NS"]
doc = {
  "apiVersion": "batch/v1",
  "kind": "Job",
  "metadata": {"name": "s4-seed", "namespace": ns, "labels": {"app": "s4-seed"}},
  "spec": {
    "backoffLimit": 2,
    "activeDeadlineSeconds": 5400,
    "template": {
      "spec": {
        "restartPolicy": "Never",
        "containers": [{
          "name": "seed",
          "image": "registry.access.redhat.com/ubi9/python-311:1",
          "command": ["/bin/bash", "-lc",
                      "pip install --quiet boto3 huggingface_hub && python3 /scripts/s4_seed.py"],
          "env": [
            {"name": "S4_API", "value": "http://s4.%s.svc.cluster.local:5000" % ns},
            {"name": "S4_S3", "value": "http://s4.%s.svc.cluster.local:7480" % ns},
            {"name": "S4_BUCKET", "value": os.environ["S4_BUCKET"]},
            {"name": "HF_REPO_ID", "value": os.environ["HF_C4_REPO"]},
            {"name": "S3_PREFIX", "value": os.environ["HF_C4_PREFIX"]},
            {"name": "S4_UI_USER",
             "valueFrom": {"secretKeyRef": {"name": "s4-credentials", "key": "UI_USERNAME"}}},
            {"name": "S4_UI_PASSWORD",
             "valueFrom": {"secretKeyRef": {"name": "s4-credentials", "key": "UI_PASSWORD"}}},
            {"name": "AWS_ACCESS_KEY_ID",
             "valueFrom": {"secretKeyRef": {"name": "s4-credentials", "key": "AWS_ACCESS_KEY_ID"}}},
            {"name": "AWS_SECRET_ACCESS_KEY",
             "valueFrom": {"secretKeyRef": {"name": "s4-credentials", "key": "AWS_SECRET_ACCESS_KEY"}}},
          ],
          "volumeMounts": [
            {"name": "script", "mountPath": "/scripts", "readOnly": True},
            {"name": "scratch", "mountPath": "/tmp"},
          ],
          "resources": {
            "requests": {"cpu": "500m", "memory": "2Gi"},
            "limits": {"cpu": "2", "memory": "8Gi"},
          },
        }],
        "volumes": [
          {"name": "script", "configMap": {"name": "s4-seed"}},
          {"name": "scratch", "emptyDir": {"sizeLimit": "40Gi"}},
        ],
      }
    },
  },
}
print(json.dumps(doc, indent=2))
PY
  echo "  Waiting for s4-seed Job (Hugging Face pull of ${HF_C4_REPO}; 15–40 min)..."
  SEED_OK=0
  for i in $(seq 1 270); do
    SUCC="$(oc get job s4-seed -n "${S4_NS}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
    FAIL="$(oc get job s4-seed -n "${S4_NS}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
    ACTIVE="$(oc get job s4-seed -n "${S4_NS}" -o jsonpath='{.status.active}' 2>/dev/null || true)"
    if [ "${SUCC:-0}" = "1" ]; then
      echo "  [OK] C4 prefix seeded"
      SEED_OK=1
      break
    fi
    if [ "${ACTIVE:-0}" = "0" ] && [ -n "${FAIL}" ] && [ "${FAIL}" != "0" ]; then
      echo "  [WARN] s4-seed Job failed (${FAIL} pod failures). Logs:"
      oc logs -n "${S4_NS}" job/s4-seed --tail=80 || true
      break
    fi
    sleep 20
  done
  if [ "${SEED_OK}" -ne 1 ] && [ -z "${FAIL:-}" ]; then
    echo "  [WARN] s4-seed did not complete in time. Logs:"
    oc logs -n "${S4_NS}" job/s4-seed --tail=80 || true
  fi
fi
echo ""

echo "7. Waiting for C4b ModelCar ImageStreamTag (does not block C4)..."
MC_OK=0
for i in $(seq 1 90); do
  REF="$(oc get istag "${HF_C4B_IS}:${HF_C4B_TAG}" -n "${PRESENTER_PROJECT}" \
    -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || true)"
  if [ -n "${REF}" ]; then
    echo "  [OK] ${HF_C4B_IS}:${HF_C4B_TAG}"
    MC_OK=1
    break
  fi
  RUNNING="$(oc get builds -n "${PRESENTER_PROJECT}" -l buildconfig="${HF_C4B_IS}" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  PHASE="$(oc get builds -n "${PRESENTER_PROJECT}" -l buildconfig="${HF_C4B_IS}" \
    -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -vE 'Cancelled|Canceling' | sort | tail -1 | awk '{print $2}')"
  if [ -n "${RUNNING}" ]; then
    echo "  Attempt ${i}/90 — build ${PHASE:-pending} (${RUNNING} running)"
  else
    echo "  Attempt ${i}/90 — build ${PHASE:-pending}"
  fi
  if [ -z "${RUNNING}" ] && [ "${PHASE}" = "Failed" -o "${PHASE}" = "Error" ]; then
    echo "  [WARN] ModelCar build ${PHASE}. oc logs -n ${PRESENTER_PROJECT} -f bc/${HF_C4B_IS}"
    break
  fi
  sleep 20
done
if [ "${MC_OK}" -ne 1 ]; then
  echo "  [WARN] ImageStreamTag not ready yet. C4b can wait on oc start-build."
fi

echo ""
echo "=== S4 / C4 / C4b setup complete ==="
if [ -n "${S4_HOST}" ]; then
  echo "  S4 UI:        https://${S4_HOST}"
fi
echo "  S3 endpoint:  ${S4_ENDPOINT}  (in-cluster only)"
echo "  Bucket/path:  s3://${S4_BUCKET}/${HF_C4_PREFIX}/"
echo "  Connection:   ${S4_CONNECTION_NAME} in ${DS_PROJECTS}"
echo "  C4b OCI:      oci://image-registry.openshift-image-registry.svc:5000/${PRESENTER_PROJECT}/${HF_C4B_IS}:${HF_C4B_TAG}"
echo "  C4b conn:     ${INCLUSTER_OCI_CONNECTION_DISPLAY} (${INCLUSTER_OCI_HOST})"
echo "  Credentials:  setup/.generated-credentials.env"
echo "  Demo only — replace S4 with enterprise object storage outside this lab."
