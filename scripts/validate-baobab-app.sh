#!/bin/bash

POSIX_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$POSIX_SCRIPT_DIR/lib/baobab-bash-bootstrap.sh"
ensure_baobab_bash "$0" "$@"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/baobab-build-common.sh"

APP_PATH=
BREW_PREFIX_OVERRIDE=${BAOBAB_BREW_PREFIX:-}
REJECT_PREFIXES=()
INFO_PLIST_KEY=
BREW_SHARE_DIR=
GSETTINGS_BIN=

usage() {
  cat <<'EOF'
Usage: scripts/validate-baobab-app.sh --app /path/to/Baobab.app [options]

Options:
  --brew-prefix <path>   Override detected Homebrew prefix
  --info-plist-key <key> Override expected CFBundleIconFile value
  --reject-prefix <path> Reject library references into this path
  --help                 Show help
EOF
  print_usage_common
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH=$2
      shift 2
      ;;
    --brew-prefix)
      BREW_PREFIX_OVERRIDE=$2
      shift 2
      ;;
    --info-plist-key)
      INFO_PLIST_KEY=$2
      shift 2
      ;;
    --reject-prefix)
      REJECT_PREFIXES+=("$(abspath "$2")")
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$APP_PATH" ]] || die "--app is required"
APP_PATH="$(abspath "$APP_PATH")"
[[ -d "$APP_PATH" ]] || die "App bundle not found: $APP_PATH"

BAOBAB_BINARY="$APP_PATH/Contents/Resources/bin/baobab"
[[ -x "$BAOBAB_BINARY" ]] || die "Baobab binary not found at: $BAOBAB_BINARY"
ICON_FILE="$APP_PATH/Contents/Resources/Baobab.icns"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$ICON_FILE" ]] || die "App icon not found at: $ICON_FILE"
[[ -f "$INFO_PLIST" ]] || die "Info.plist not found at: $INFO_PLIST"
require_tool gsettings
GSETTINGS_BIN="$(command -v gsettings)"

if [[ -z "$INFO_PLIST_KEY" ]]; then
  INFO_PLIST_KEY="Baobab.icns"
fi

if [[ -n "$BREW_PREFIX_OVERRIDE" ]]; then
  BAOBAB_BREW_PREFIX="$(abspath "$BREW_PREFIX_OVERRIDE")"
else
  BAOBAB_BREW_PREFIX="$(detect_brew_prefix || true)"
fi
[[ -n "$BAOBAB_BREW_PREFIX" ]] || die "Homebrew prefix could not be detected; pass --brew-prefix explicitly"
BREW_SHARE_DIR="$BAOBAB_BREW_PREFIX/share"
[[ -d "$BREW_SHARE_DIR" ]] || die "Homebrew share directory not found: $BREW_SHARE_DIR"

RPATHS=()
while IFS= read -r rpath; do
  [[ -n "$rpath" ]] || continue
  RPATHS+=("$rpath")
done < <(read_otool_rpaths "$BAOBAB_BINARY")

DYLIBS=()
while IFS= read -r dylib; do
  [[ -n "$dylib" ]] || continue
  DYLIBS+=("$dylib")
done < <(read_otool_deps "$BAOBAB_BINARY")

[[ ${#RPATHS[@]} -gt 0 ]] || die "No LC_RPATH entries found on $BAOBAB_BINARY"

errors=()
bundle_share_dir="$APP_PATH/Contents/Resources/share"
runtime_xdg_data_dirs="$bundle_share_dir:$BREW_SHARE_DIR"
actual_icon_file="$(/usr/bin/plutil -extract CFBundleIconFile raw -o - "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$actual_icon_file" != "$INFO_PLIST_KEY" ]]; then
  errors+=("unexpected CFBundleIconFile value: expected $INFO_PLIST_KEY, got ${actual_icon_file:-<missing>}")
fi

if [[ ${#REJECT_PREFIXES[@]} -gt 0 ]]; then
  for reject_prefix in "${REJECT_PREFIXES[@]}"; do
    for dep in "${DYLIBS[@]}"; do
      if [[ "$dep" == "$reject_prefix"* ]]; then
        errors+=("dependency still points into rejected prefix: $dep")
      fi
    done
  done
fi

for dep in "${DYLIBS[@]}"; do
  if is_macos_system_path "$dep" || is_app_path "$dep" "$APP_PATH"; then
    continue
  fi

  if [[ "$dep" == @rpath/* ]]; then
    dylib_name="${dep#@rpath/}"
    found=0
    for rpath in "${RPATHS[@]}"; do
      if [[ -f "$rpath/$dylib_name" ]]; then
        found=1
        break
      fi
    done
    if [[ $found -eq 0 ]]; then
      errors+=("unresolved @rpath dependency: $dep")
    fi
    continue
  fi

  if [[ "$dep" == @loader_path/* || "$dep" == @executable_path/* ]]; then
    continue
  fi

  if [[ "$dep" == /* ]]; then
    if [[ -n "$BAOBAB_BREW_PREFIX" && "$dep" == "$BAOBAB_BREW_PREFIX/"* ]]; then
      errors+=("unexpected absolute Homebrew reference left on executable: $dep")
      continue
    fi
    errors+=("unexpected absolute library reference: $dep")
    continue
  fi

  errors+=("unexpected dependency form: $dep")
done

for rpath in "${RPATHS[@]}"; do
  if [[ ${#REJECT_PREFIXES[@]} -gt 0 ]]; then
    for reject_prefix in "${REJECT_PREFIXES[@]}"; do
      if [[ "$rpath" == "$reject_prefix"* ]]; then
        errors+=("rpath points into rejected prefix: $rpath")
        continue 2
      fi
    done
  fi

  if [[ "$rpath" == *"/out/work/"* || "$rpath" == *"/tmp/"* || "$rpath" == *"/private/tmp/"* ]]; then
    errors+=("rpath points into a temporary build location: $rpath")
    continue
  fi

  if [[ ! -d "$rpath" ]]; then
    errors+=("rpath directory does not exist: $rpath")
    continue
  fi

  if [[ -n "$BAOBAB_BREW_PREFIX" && "$rpath" != "$BAOBAB_BREW_PREFIX/"* ]]; then
    errors+=("rpath is outside detected Homebrew prefix: $rpath")
  fi
done

for required_schema in \
  org.gnome.baobab \
  org.gnome.baobab.preferences \
  org.gtk.gtk4.Settings.FileChooser
do
  if ! env -i \
    HOME="${HOME:-/tmp}" \
    PATH="$(dirname "$GSETTINGS_BIN"):/usr/bin:/bin" \
    XDG_DATA_DIRS="$runtime_xdg_data_dirs" \
    "$GSETTINGS_BIN" list-schemas 2>/dev/null | grep -Fx "$required_schema" >/dev/null; then
    errors+=("missing schema in clean runtime environment: $required_schema")
  fi
done

if ! env -i \
  HOME="${HOME:-/tmp}" \
  PATH="$(dirname "$GSETTINGS_BIN"):/usr/bin:/bin" \
  XDG_DATA_DIRS="$runtime_xdg_data_dirs" \
  "$GSETTINGS_BIN" list-recursively org.gtk.gtk4.Settings.FileChooser >/dev/null 2>&1; then
  errors+=("failed to query org.gtk.gtk4.Settings.FileChooser in clean runtime environment")
fi

if [[ ${#errors[@]} -gt 0 ]]; then
  printf '[baobab-build] runtime validation failed:\n' >&2
  printf '  - %s\n' "${errors[@]}" >&2
  exit 1
fi

log "Runtime validation passed for $APP_PATH"
