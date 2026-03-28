#!/usr/bin/env bash

set -euo pipefail

readonly BAOBAB_BUILD_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BAOBAB_REPO_ROOT="$(cd "$BAOBAB_BUILD_COMMON_DIR/../.." && pwd)"
readonly BAOBAB_RELEASE_CONFIG="$BAOBAB_REPO_ROOT/config/baobab-release.conf"

if [[ ! -f "$BAOBAB_RELEASE_CONFIG" ]]; then
  echo "Missing release config: $BAOBAB_RELEASE_CONFIG" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$BAOBAB_RELEASE_CONFIG"

log() {
  printf '[baobab-build] %s\n' "$*" >&2
}

die() {
  printf '[baobab-build] ERROR: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  local tool=$1
  command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: $tool"
}

ensure_dir() {
  mkdir -p "$1"
}

abspath() {
  local path=$1
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd)
  else
    local parent
    parent="$(cd "$(dirname "$path")" && pwd)"
    printf '%s/%s\n' "$parent" "$(basename "$path")"
  fi
}

trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

is_macos_system_path() {
  local path=$1
  [[ "$path" == /usr/lib/* || "$path" == /System/Library/* ]]
}

is_app_path() {
  local path=$1
  local app_root=$2
  [[ "$path" == "$app_root/"* ]]
}

read_otool_deps() {
  local binary=$1
  otool -L "$binary" | tail -n +2 | awk '{print $1}'
}

read_otool_rpaths() {
  local binary=$1
  otool -l "$binary" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { waiting = 1; next }
    waiting && $1 == "path" { print $2; waiting = 0 }
  '
}

append_unique() {
  local value=$1
  shift
  local existing
  for existing in "$@"; do
    [[ "$existing" == "$value" ]] && return 0
  done
  return 1
}

detect_brew_prefix() {
  if [[ -n "${BAOBAB_BREW_PREFIX:-}" ]]; then
    printf '%s\n' "$BAOBAB_BREW_PREFIX"
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    brew --prefix
    return 0
  fi
  return 1
}

detect_glib_compile_schemas() {
  if command -v glib-compile-schemas >/dev/null 2>&1; then
    command -v glib-compile-schemas
    return 0
  fi

  local brew_prefix
  if brew_prefix="$(detect_brew_prefix 2>/dev/null)"; then
    if [[ -x "$brew_prefix/bin/glib-compile-schemas" ]]; then
      printf '%s\n' "$brew_prefix/bin/glib-compile-schemas"
      return 0
    fi
  fi

  return 1
}

print_usage_common() {
  cat <<'EOF'
Supported overrides:
  --version <version>
  --sha256 <sha256>
  --source-url <url>
  --source-tarball <path>
  --source-dir <path>
  --output-dir <path>
  --brew-prefix <path>
  --sign-identity <identity>
EOF
}
