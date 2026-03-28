resolve_baobab_bash() {
  if [ -n "${BAOBAB_BASH_BIN:-}" ] && [ -x "${BAOBAB_BASH_BIN}" ]; then
    printf '%s\n' "$BAOBAB_BASH_BIN"
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    prefix="$(brew --prefix bash 2>/dev/null || true)"
    if [ -n "$prefix" ] && [ -x "$prefix/bin/bash" ]; then
      printf '%s\n' "$prefix/bin/bash"
      return 0
    fi

    prefix="$(brew --prefix 2>/dev/null || true)"
    if [ -n "$prefix" ] && [ -x "$prefix/bin/bash" ]; then
      printf '%s\n' "$prefix/bin/bash"
      return 0
    fi
  fi

  command -v bash >/dev/null 2>&1 || return 1
  command -v bash
}

ensure_baobab_bash() {
  script_path=$1
  shift

  if [ -z "${BASH_VERSION:-}" ] || [ "${BASH:-}" = "/bin/sh" ] || [ "${POSIXLY_CORRECT:-}" = "y" ]; then
    BAOBAB_BASH_BIN="$(resolve_baobab_bash)" || {
      echo "Failed to locate a usable bash interpreter" >&2
      exit 1
    }
    exec "$BAOBAB_BASH_BIN" "$script_path" "$@"
  fi
}
