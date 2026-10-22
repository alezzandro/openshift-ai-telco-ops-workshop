#!/bin/bash
# Install workstation CLIs: mise (kubectl, jq) plus oc, openshift-install,
# lego, and htpasswd. gcloud is the Google Cloud SDK (preinstalled or separate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=defaults.sh
source "${SCRIPT_DIR}/defaults.sh"
# shellcheck source=env-tools.sh
source "${SCRIPT_DIR}/env-tools.sh"

OCP_VERSION="${OCP_VERSION:-4.22.18}"
OCP_CLIENTS_ARCH="${OCP_CLIENTS_ARCH:-x86_64}"
MIRROR_BASE="https://mirror.openshift.com/pub/openshift-v4/${OCP_CLIENTS_ARCH}/clients/ocp"
INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "${INSTALL_DIR}"

echo "=== Installing workstation tools ==="
echo ""

ensure_mise() {
  if command -v mise >/dev/null 2>&1 || [ -x "${HOME}/.local/bin/mise" ]; then
    echo "  [OK] mise: $(command -v mise 2>/dev/null || echo "${HOME}/.local/bin/mise")"
    return 0
  fi
  echo "  Installing mise into ${HOME}/.local/bin ..."
  curl -fsSL https://mise.run | sh
  export PATH="${HOME}/.local/bin:${PATH}"
  if ! command -v mise >/dev/null 2>&1; then
    echo "  ERROR: mise install finished but mise is not on PATH." >&2
    return 1
  fi
  echo "  [OK] mise $(mise --version)"
}

mirror_url_ok() {
  local url="$1"
  curl -fsI -o /dev/null -w "%{http_code}" "${url}" | grep -q '^200$'
}

resolve_ocp_version() {
  local ver="$1"
  if mirror_url_ok "${MIRROR_BASE}/${ver}/openshift-install-linux.tar.gz"; then
    echo "${ver}"
    return 0
  fi
  echo "  [WARN] ${ver} is not on the mirror; trying latest-4.22" >&2
  if mirror_url_ok "${MIRROR_BASE}/latest-4.22/openshift-install-linux.tar.gz"; then
    echo "latest-4.22"
    return 0
  fi
  echo "  ERROR: cannot find OpenShift 4.22 clients on ${MIRROR_BASE}" >&2
  return 1
}

client_version() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    return 1
  fi
  case "${bin}" in
    oc)
      oc version --client -o json 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('releaseClientVersion') or d.get('clientVersion',{}).get('gitVersion',''))" \
        2>/dev/null || oc version --client 2>/dev/null | head -1
      ;;
    openshift-install)
      openshift-install version 2>/dev/null | awk 'NR==1{print $2; exit}'
      ;;
    *)
      return 1
      ;;
  esac
}

install_tarball_bin() {
  local name="$1"
  local tarball="$2"
  local url="$3"
  local want_ver="$4"
  local have
  have="$(client_version "${name}" || true)"
  if [ -n "${have}" ] && echo "${have}" | grep -q "${want_ver}"; then
    echo "  [OK] ${name} already ${have}"
    return 0
  fi
  if [ -n "${have}" ] && [ "${want_ver}" = "latest-4.22" ]; then
    echo "  [OK] ${name} present (${have}); leaving in place"
    return 0
  fi
  echo "  Downloading ${name} (${want_ver})..."
  local tmp
  tmp="$(mktemp -d)"
  curl -fL --retry 3 -o "${tmp}/${tarball}" "${url}"
  tar -C "${tmp}" -xzf "${tmp}/${tarball}" "${name}"
  install -m 0755 "${tmp}/${name}" "${INSTALL_DIR}/${name}"
  rm -rf "${tmp}"
  echo "  [OK] ${name} -> ${INSTALL_DIR}/${name}"
}

ensure_mise
# shellcheck source=env-tools.sh
source "${SCRIPT_DIR}/env-tools.sh"

echo "1. mise packages (kubectl, jq)..."
if [ -f "${REPO_ROOT}/.mise.toml" ]; then
  mise trust "${REPO_ROOT}/.mise.toml" </dev/null 2>/dev/null || true
fi
(cd "${REPO_ROOT}" && mise install)
mise reshim 2>/dev/null || true
# shellcheck source=env-tools.sh
source "${SCRIPT_DIR}/env-tools.sh"
echo "  [OK] kubectl $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
echo "  [OK] jq $(jq --version)"
echo ""

echo "2. OpenShift clients from mirror.openshift.com (OCP_VERSION=${OCP_VERSION})..."
RESOLVED_VERSION="$(resolve_ocp_version "${OCP_VERSION}")"
echo "  Using ${MIRROR_BASE}/${RESOLVED_VERSION}/"
install_tarball_bin oc \
  "openshift-client-linux.tar.gz" \
  "${MIRROR_BASE}/${RESOLVED_VERSION}/openshift-client-linux.tar.gz" \
  "${RESOLVED_VERSION}"
install_tarball_bin openshift-install \
  "openshift-install-linux.tar.gz" \
  "${MIRROR_BASE}/${RESOLVED_VERSION}/openshift-install-linux.tar.gz" \
  "${RESOLVED_VERSION}"
echo ""

echo "3. gcloud, htpasswd, lego..."
if command -v gcloud >/dev/null 2>&1; then
  echo "  [OK] gcloud $(gcloud version 2>/dev/null | head -1)"
else
  echo "  ERROR: gcloud not found. Install the Google Cloud SDK:" >&2
  echo "         https://cloud.google.com/sdk/docs/install" >&2
  exit 1
fi
if command -v htpasswd >/dev/null 2>&1; then
  echo "  [OK] htpasswd $(command -v htpasswd)"
else
  echo "  Installing httpd-tools (htpasswd)..."
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y httpd-tools
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y httpd-tools
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y apache2-utils
  else
    echo "  ERROR: install htpasswd (httpd-tools / apache2-utils) and re-run." >&2
    exit 1
  fi
fi
install_lego() {
  local want="${LEGO_VERSION:-v4.25.2}"
  local have=""
  if command -v lego >/dev/null 2>&1; then
    have="$(lego --version 2>/dev/null | awk '{print $NF; exit}' || true)"
    if echo "${have}" | grep -q "${want#v}"; then
      echo "  [OK] lego ${have}"
      return 0
    fi
  fi
  echo "  Downloading lego ${want}..."
  local tmp arch tarball
  tmp="$(mktemp -d)"
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "  ERROR: unsupported arch ${arch} for lego" >&2; rm -rf "${tmp}"; return 1 ;;
  esac
  tarball="lego_${want}_linux_${arch}.tar.gz"
  curl -fL --retry 3 -o "${tmp}/lego.tgz" \
    "https://github.com/go-acme/lego/releases/download/${want}/${tarball}"
  tar -C "${tmp}" -xzf "${tmp}/lego.tgz" lego
  install -m 0755 "${tmp}/lego" "${INSTALL_DIR}/lego"
  rm -rf "${tmp}"
  echo "  [OK] lego -> ${INSTALL_DIR}/lego"
}
install_lego
echo ""

echo "4. Versions:"
echo "  gcloud            $(gcloud version 2>/dev/null | head -1)"
echo "  oc                $(oc version --client 2>/dev/null | head -1)"
echo "  kubectl           $(kubectl version --client 2>/dev/null | head -1)"
echo "  openshift-install $(openshift-install version 2>/dev/null | head -1)"
echo "  jq                $(jq --version)"
echo "  lego              $(lego --version 2>/dev/null | head -1)"
echo "  htpasswd          $(command -v htpasswd)"
echo ""
echo "=== Tools ready ==="
echo "  If this is a new shell, add ~/.local/bin to PATH or:"
echo "    eval \"\$(mise activate bash)\""
echo "  Next: ./setup/01-install-cluster.sh"
