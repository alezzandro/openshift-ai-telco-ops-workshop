# Put mise shims and ~/.local/bin on PATH. Source from other setup scripts.
# shellcheck disable=SC1091

_workshop_activate_tools() {
  export PATH="${HOME}/.local/bin:${PATH}"
  local mise_bin=""
  if [ -x "${HOME}/.local/bin/mise" ]; then
    mise_bin="${HOME}/.local/bin/mise"
  elif command -v mise >/dev/null 2>&1; then
    mise_bin="$(command -v mise)"
  fi
  if [ -n "${mise_bin}" ]; then
    eval "$("${mise_bin}" activate bash)" 2>/dev/null || true
  fi
}

_workshop_activate_tools
