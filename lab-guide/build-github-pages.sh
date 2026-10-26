#!/usr/bin/env bash
# Build Presenter + Playground Antora sites for GitHub Pages.
# Does not write site.url into the in-cluster playbooks; uses `antora --url`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT="${PAGES_OUT:-${REPO_ROOT}/public}"
BASE_URL="${PAGES_BASE_URL:-}"

if [[ -z "${BASE_URL}" ]]; then
  echo "Set PAGES_BASE_URL to the GitHub Pages origin, for example:" >&2
  echo "  PAGES_BASE_URL=https://OWNER.github.io/REPO ${0}" >&2
  exit 1
fi
BASE_URL="${BASE_URL%/}"

if ! command -v antora >/dev/null 2>&1; then
  echo "antora is not on PATH. Install @antora/cli@3.1.10 and @antora/site-generator@3.1.10." >&2
  exit 1
fi

python3 - <<PY
import os, zipfile
root = os.path.join("${REPO_ROOT}", "lab-guide", "ui")
out = os.path.join("${REPO_ROOT}", "lab-guide", "ui-bundle.zip")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for dirpath, _, files in os.walk(root):
        for name in files:
            path = os.path.join(dirpath, name)
            zf.write(path, os.path.relpath(path, root))
print("wrote", out)
PY

cd "${SCRIPT_DIR}"
antora --stacktrace --url "${BASE_URL}/presenter" presenter-site.yml
antora --stacktrace --url "${BASE_URL}/playground" playground-site.yml

rm -rf "${OUT}"
mkdir -p "${OUT}"
cp -a "${SCRIPT_DIR}/www/presenter" "${OUT}/presenter"
cp -a "${SCRIPT_DIR}/www/playground" "${OUT}/playground"
cp "${SCRIPT_DIR}/github-pages-index.html" "${OUT}/index.html"
: > "${OUT}/.nojekyll"

echo "GitHub Pages tree: ${OUT}"
echo "  ${BASE_URL}/"
echo "  ${BASE_URL}/presenter/"
echo "  ${BASE_URL}/playground/"
