#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/script"
# shellcheck source=app_metadata.sh
source "$SCRIPT_DIR/app_metadata.sh"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
USER_APPLICATIONS_DIR="$HOME/Applications"
USER_APP_BUNDLE="$USER_APPLICATIONS_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"

cd "$ROOT_DIR"

if [[ "$MODE" == "--open-existing" || "$MODE" == "open-existing" ]]; then
  if [[ ! -x "$APP_BINARY" ]]; then
    echo "Existing app bundle not found. Run ./script/build_and_run.sh once first." >&2
    exit 1
  fi
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x VidLingo >/dev/null 2>&1 || true
  /usr/bin/open -n "$APP_BUNDLE"
  exit 0
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x VidLingo >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
cp "$ROOT_DIR/Resources/TranslationSystemPrompt.md" "$APP_RESOURCES/TranslationSystemPrompt.md"

"$SCRIPT_DIR/write_info_plist.sh" "$INFO_PLIST" local

select_code_sign_identity() {
  if [[ -n "$CODE_SIGN_IDENTITY" ]]; then
    printf '%s\n' "$CODE_SIGN_IDENTITY"
    return
  fi

  /usr/bin/security find-identity -v -p codesigning 2>/dev/null |
    /usr/bin/awk -F'"' '/"Apple Development:|Developer ID Application:|Mac Developer:/{ print $2; exit }'
}

SIGN_IDENTITY="$(select_code_sign_identity)"
if [[ -n "$SIGN_IDENTITY" ]]; then
  /usr/bin/codesign --force --deep --timestamp=none --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
  /usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
  echo "warning: no persistent code signing identity found; macOS privacy grants may reset after rebuilds" >&2
fi

open_app() {
  mkdir -p "$USER_APPLICATIONS_DIR"
  rm -rf "$USER_APP_BUNDLE"
  cp -R "$APP_BUNDLE" "$USER_APP_BUNDLE"
  /usr/bin/open -n "$USER_APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--open-existing|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
