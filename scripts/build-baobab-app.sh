#!/bin/bash

POSIX_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$POSIX_SCRIPT_DIR/lib/baobab-bash-bootstrap.sh"
ensure_baobab_bash "$0" "$@"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/baobab-build-common.sh"

VERSION=${BAOBAB_VERSION}
SOURCE_SHA256=${BAOBAB_SHA256}
SOURCE_URL=${BAOBAB_SOURCE_URL}
APP_NAME=${BAOBAB_APP_NAME}
BUNDLE_ID=${BAOBAB_BUNDLE_ID}
SIGN_IDENTITY=${BAOBAB_SIGN_IDENTITY:-"-"}
SOURCE_TARBALL=${BAOBAB_SOURCE_TARBALL:-}
SOURCE_DIR=${BAOBAB_SOURCE_DIR:-}
OUTPUT_DIR=${BAOBAB_OUTPUT_DIR:-"$BAOBAB_REPO_ROOT/out"}
BAOBAB_BREW_PREFIX=${BAOBAB_BREW_PREFIX:-}
DEBUG_BUILD=${BAOBAB_DEBUG:-0}

usage() {
  cat <<'EOF'
Usage: ./build-baobab-app.sh [options]

Build a host-local Baobab.app from a release tarball by default.

Options:
  --debug
  --version <version>
  --sha256 <sha256>
  --source-url <url>
  --source-tarball <path>
  --source-dir <path>
  --output-dir <path>
  --brew-prefix <path>
  --sign-identity <identity>
  --help
EOF
}

normalize_debug_flag() {
  case "${1:-0}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      printf '1\n'
      ;;
    0|false|FALSE|False|no|NO|No|off|OFF|Off|'')
      printf '0\n'
      ;;
    *)
      return 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      DEBUG_BUILD=1
      shift
      ;;
    --version)
      VERSION=$2
      shift 2
      ;;
    --sha256)
      SOURCE_SHA256=$2
      shift 2
      ;;
    --source-url)
      SOURCE_URL=$2
      shift 2
      ;;
    --source-tarball)
      SOURCE_TARBALL=$2
      shift 2
      ;;
    --source-dir)
      SOURCE_DIR=$2
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR=$2
      shift 2
      ;;
    --brew-prefix)
      BAOBAB_BREW_PREFIX=$2
      shift 2
      ;;
    --sign-identity)
      SIGN_IDENTITY=$2
      shift 2
      ;;
    --help)
      usage
      print_usage_common
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

DEBUG_BUILD="$(normalize_debug_flag "$DEBUG_BUILD")" || die "Invalid debug flag value: $DEBUG_BUILD"
if [[ "$DEBUG_BUILD" == "1" ]]; then
  BUILD_FLAVOR=debug
  MESON_BUILDTYPE=debugoptimized
else
  BUILD_FLAVOR=release
  MESON_BUILDTYPE=release
fi

OUTPUT_DIR="$(abspath "$OUTPUT_DIR")"
WORK_DIR="$OUTPUT_DIR/work"
DOWNLOAD_DIR="$OUTPUT_DIR/downloads"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_DIR/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
BUILD_DIR="$WORK_DIR/build"
STAGE_DIR="$WORK_DIR/stage"
SOURCE_EXTRACT_DIR="$WORK_DIR/source"
ICONSET_DIR="$WORK_DIR/Baobab.iconset"
ICON_ICNS_NAME="Baobab.icns"

require_tool curl
require_tool shasum
require_tool tar
require_tool meson
require_tool ninja
require_tool pkg-config
require_tool install_name_tool
require_tool codesign
require_tool otool
require_tool ditto
require_tool rsvg-convert

GLIB_COMPILE_SCHEMAS="$(detect_glib_compile_schemas || true)"
[[ -n "$GLIB_COMPILE_SCHEMAS" ]] || die "Required tool not found: glib-compile-schemas"

if [[ -n "$BAOBAB_BREW_PREFIX" ]]; then
  BAOBAB_BREW_PREFIX="$(abspath "$BAOBAB_BREW_PREFIX")"
else
  BAOBAB_BREW_PREFIX="$(detect_brew_prefix || true)"
fi

BAOBAB_BASH_BIN="${BAOBAB_BASH_BIN:-$BASH}"
ICONUTIL_BIN="$(command -v iconutil || true)"
MAKEICNS_BIN="$(command -v makeicns || true)"
BREW_SHARE_DIR=

if [[ -z "$ICONUTIL_BIN" && -z "$MAKEICNS_BIN" ]]; then
  die "Required icon packager not found: install iconutil or makeicns"
fi

log "Using output directory: $OUTPUT_DIR"
[[ -n "$BAOBAB_BREW_PREFIX" ]] || die "Homebrew prefix could not be detected; pass --brew-prefix explicitly"
BREW_SHARE_DIR="$BAOBAB_BREW_PREFIX/share"
[[ -d "$BREW_SHARE_DIR" ]] || die "Homebrew share directory not found: $BREW_SHARE_DIR"
log "Detected Homebrew prefix: $BAOBAB_BREW_PREFIX"
log "Using build flavor: $BUILD_FLAVOR"

ensure_dir "$OUTPUT_DIR"
rm -rf "$WORK_DIR" "$APP_DIR"
ensure_dir "$WORK_DIR"
ensure_dir "$DOWNLOAD_DIR"

resolve_source_tree() {
  if [[ -n "$SOURCE_DIR" ]]; then
    SOURCE_DIR="$(abspath "$SOURCE_DIR")"
    [[ -d "$SOURCE_DIR" ]] || die "Source directory not found: $SOURCE_DIR"
    printf '%s\n' "$SOURCE_DIR"
    return 0
  fi

  local archive_path
  if [[ -n "$SOURCE_TARBALL" ]]; then
    archive_path="$(abspath "$SOURCE_TARBALL")"
  else
    archive_path="$DOWNLOAD_DIR/baobab-$VERSION.tar.xz"
    if [[ ! -f "$archive_path" ]]; then
      log "Downloading $SOURCE_URL"
      curl -L --fail --output "$archive_path" "$SOURCE_URL"
    else
      log "Reusing downloaded archive: $archive_path"
    fi
  fi

  [[ -f "$archive_path" ]] || die "Source tarball not found: $archive_path"
  local actual_sha
  actual_sha="$(sha256_file "$archive_path")"
  if [[ "$actual_sha" != "$SOURCE_SHA256" ]]; then
    die "sha256 mismatch for $archive_path: expected $SOURCE_SHA256, got $actual_sha"
  fi
  log "Verified sha256 for $archive_path"

  rm -rf "$SOURCE_EXTRACT_DIR"
  ensure_dir "$SOURCE_EXTRACT_DIR"
  tar -xf "$archive_path" -C "$SOURCE_EXTRACT_DIR" --strip-components 1
  printf '%s\n' "$SOURCE_EXTRACT_DIR"
}

generate_info_plist() {
  local plist_path=$1
  cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_ICNS_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF
}

generate_app_icon() {
  local source_root=$1
  local svg_path="$source_root/data/icons/hicolor/scalable/apps/org.gnome.baobab.svg"
  local icon_output_path="$APP_RESOURCES/$ICON_ICNS_NAME"
  local icon_master_png="$WORK_DIR/Baobab-1024.png"
  local size

  [[ -f "$svg_path" ]] || die "Baobab app icon SVG not found: $svg_path"

  rsvg-convert \
    --keep-aspect-ratio \
    --background-color=transparent \
    --width 1024 \
    --height 1024 \
    -o "$icon_master_png" \
    "$svg_path"
  [[ -f "$icon_master_png" ]] || die "Failed to render master app icon PNG: $icon_master_png"

  rm -rf "$ICONSET_DIR"
  ensure_dir "$ICONSET_DIR"

  for size in 16 32 128 256 512; do
    rsvg-convert \
      --keep-aspect-ratio \
      --background-color=transparent \
      --width "$size" \
      --height "$size" \
      -o "$ICONSET_DIR/icon_${size}x${size}.png" \
      "$svg_path"

    rsvg-convert \
      --keep-aspect-ratio \
      --background-color=transparent \
      --width "$((size * 2))" \
      --height "$((size * 2))" \
      -o "$ICONSET_DIR/icon_${size}x${size}@2x.png" \
      "$svg_path"
  done

  if [[ -n "$ICONUTIL_BIN" ]] && "$ICONUTIL_BIN" -c icns "$ICONSET_DIR" -o "$icon_output_path" >/dev/null 2>&1; then
    :
  elif [[ -n "$MAKEICNS_BIN" ]]; then
    log "iconutil rejected the iconset; falling back to makeicns"
    "$MAKEICNS_BIN" -in "$icon_master_png" -out "$icon_output_path" >/dev/null
  else
    die "iconutil rejected the generated iconset and makeicns is not available"
  fi

  [[ -f "$icon_output_path" ]] || die "Failed to generate app icon: $icon_output_path"
}

generate_launcher() {
  local launcher_path=$1
  local brew_prefix=$2
  local brew_share_dir=$3
  local build_flavor=$4
  cat >"$launcher_path" <<EOF
#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
APP_CONTENTS="\$(cd "\$SCRIPT_DIR/.." && pwd)"
RESOURCES_DIR="\$APP_CONTENTS/Resources"
BAOBAB_BINARY="\$RESOURCES_DIR/bin/baobab"
BREW_PREFIX="$brew_prefix"
BREW_SHARE_DIR="$brew_share_dir"
BUILD_FLAVOR="$build_flavor"
LOG_DIR="\${HOME}/Library/Logs/Baobab"
LOG_FILE="\$LOG_DIR/baobab.log"

export PATH="\$RESOURCES_DIR/bin\${PATH:+:\$PATH}"
export XDG_DATA_DIRS="\$RESOURCES_DIR/share:\$BREW_SHARE_DIR\${XDG_DATA_DIRS:+:\$XDG_DATA_DIRS}"

if mkdir -p "\$LOG_DIR" 2>/dev/null; then
  if exec >>"\$LOG_FILE" 2>&1; then
    printf '\n[%s] launch pid=%s flavor=%s app=%s brew_prefix=%s brew_share=%s\n' \
      "\$(date '+%Y-%m-%d %H:%M:%S %z')" \
      "\$\$" \
      "\$BUILD_FLAVOR" \
      "\$APP_CONTENTS" \
      "\$BREW_PREFIX" \
      "\$BREW_SHARE_DIR"
  fi
fi

exec "\$BAOBAB_BINARY" "\$@"
EOF
  chmod +x "$launcher_path"
}

patch_binary_load_paths() {
  local binary=$1
  local dep
  local dep_dir
  local dep_name
  local existing=()
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    existing+=("$dep")
  done < <(read_otool_rpaths "$binary")

  while read -r dep; do
    [[ -n "$dep" ]] || continue

    if is_macos_system_path "$dep"; then
      continue
    fi

    if [[ "$dep" == @* ]]; then
      continue
    fi

    dep_dir="$(dirname "$dep")"
    dep_name="$(basename "$dep")"

    install_name_tool -change "$dep" "@rpath/$dep_name" "$binary"

    if ! append_unique "$dep_dir" "${existing[@]-}"; then
      install_name_tool -add_rpath "$dep_dir" "$binary"
      existing+=("$dep_dir")
    fi
  done < <(read_otool_deps "$binary")
}

compile_schemas_if_present() {
  local schema_dir=$1
  if [[ -d "$schema_dir" ]]; then
    "$GLIB_COMPILE_SCHEMAS" "$schema_dir"
  fi
}

source_root="$(resolve_source_tree)"
log "Using source tree: $source_root"

meson setup "$BUILD_DIR" "$source_root" \
  --buildtype="$MESON_BUILDTYPE" \
  -Db_ndebug=false \
  --prefix=/ \
  --bindir=bin \
  --datadir=share \
  --localedir=share/locale
meson compile -C "$BUILD_DIR"
meson install -C "$BUILD_DIR" --destdir "$STAGE_DIR"

ensure_dir "$APP_MACOS"
ensure_dir "$APP_RESOURCES"
ditto "$STAGE_DIR" "$APP_RESOURCES"
rm -rf "$APP_RESOURCES/share/dbus-1/services"

generate_info_plist "$APP_CONTENTS/Info.plist"
generate_launcher "$APP_MACOS/$APP_NAME" "$BAOBAB_BREW_PREFIX" "$BREW_SHARE_DIR" "$BUILD_FLAVOR"
generate_app_icon "$source_root"

BAOBAB_BINARY="$APP_RESOURCES/bin/baobab"
[[ -x "$BAOBAB_BINARY" ]] || die "Expected installed binary not found: $BAOBAB_BINARY"

compile_schemas_if_present "$APP_RESOURCES/share/glib-2.0/schemas"
patch_binary_load_paths "$BAOBAB_BINARY"

validate_args=(
  --app "$APP_DIR"
  --reject-prefix "$WORK_DIR"
)
if [[ -n "$BAOBAB_BREW_PREFIX" ]]; then
  validate_args+=(--brew-prefix "$BAOBAB_BREW_PREFIX")
fi
"$BAOBAB_BASH_BIN" "$SCRIPT_DIR/validate-baobab-app.sh" "${validate_args[@]}"

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

log "Build complete: $APP_DIR"
