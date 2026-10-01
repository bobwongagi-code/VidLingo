#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-build}"

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
ALLOW_ADHOC_SIGNING="${VIDLINGO_ALLOW_ADHOC_SIGNING:-1}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY#"${CODE_SIGN_IDENTITY%%[![:space:]]*}"}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY%"${CODE_SIGN_IDENTITY##*[![:space:]]}"}"
STABLE_SIGNING_REQUIRED=0

cd "$ROOT_DIR"

usage() {
  echo "usage: $0 [build|package|install|run|dev-run|stop|open-existing|debug|logs|telemetry|verify]" >&2
}

build_app() {
  local plist_mode="${1:-local}"
  if [[ "$ALLOW_ADHOC_SIGNING" != "1" || ( -n "$CODE_SIGN_IDENTITY" && "$CODE_SIGN_IDENTITY" != "-" ) ]]; then
    require_stable_signing
  fi
  swift build
  local build_binary
  build_binary="$(swift build --show-bin-path)/$APP_NAME"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$build_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
  cp "$ROOT_DIR/Resources/TranslationSystemPrompt.md" "$APP_RESOURCES/TranslationSystemPrompt.md"

  "$SCRIPT_DIR/write_info_plist.sh" "$INFO_PLIST" "$plist_mode"

  if [[ -n "$CODE_SIGN_IDENTITY" ]]; then
    /usr/bin/codesign --force --deep --timestamp=none --sign "$CODE_SIGN_IDENTITY" "$APP_BUNDLE"
  else
    /usr/bin/codesign --force --deep --timestamp=none --sign - "$APP_BUNDLE"
    echo "warning: no CODE_SIGN_IDENTITY supplied; using ad-hoc signing. Set CODE_SIGN_IDENTITY for stable Keychain/privacy grants." >&2
  fi

  if [[ "$STABLE_SIGNING_REQUIRED" == "1" ]]; then
    verify_stable_signature
  fi
}

package_app() {
  require_stable_signing
  build_app release
  local package_path="$DIST_DIR/${APP_NAME}-${VERSION}.zip"
  rm -f "$package_path"
  ditto -c -k --keepParent "$APP_BUNDLE" "$package_path"
  echo "Packaged: $package_path"
}

install_app() {
  mkdir -p "$USER_APPLICATIONS_DIR"
  rm -rf "$USER_APP_BUNDLE"
  cp -R "$APP_BUNDLE" "$USER_APP_BUNDLE"
}

require_stable_signing() {
  if [[ -z "$CODE_SIGN_IDENTITY" || "$CODE_SIGN_IDENTITY" == "-" ]]; then
    echo "A non-ad-hoc CODE_SIGN_IDENTITY is required for install/run/package/verify. Use 'build' or 'dev-run' for local ad-hoc signing." >&2
    return 1
  fi
  STABLE_SIGNING_REQUIRED=1
}

verify_stable_signature() {
  local signature_details
  if ! signature_details="$(/usr/bin/codesign --display --verbose=4 "$APP_BUNDLE" 2>&1)"; then
    echo "Unable to inspect the built app's codesign identity." >&2
    return 1
  fi
  if grep -Fq "Signature=adhoc" <<<"$signature_details" \
    || ! grep -Eq '^Authority=.+$' <<<"$signature_details"; then
    echo "Stable signing requires a non-ad-hoc codesign identity on the built app." >&2
    return 1
  fi
}

run_app() {
  /usr/bin/open "$USER_APP_BUNDLE"
}

stop_app() {
  /usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

verify_app() {
  [[ -x "$APP_BINARY" ]] || { echo "Build output is missing: $APP_BINARY" >&2; return 1; }
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
  local bundle_id bundle_version build_number
  bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST")"
  bundle_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")"
  build_number="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")"
  [[ "$bundle_id" == "$BUNDLE_ID" ]] || { echo "Unexpected bundle identifier: $bundle_id" >&2; return 1; }
  [[ "$bundle_version" == "$VERSION" ]] || { echo "Unexpected app version: $bundle_version" >&2; return 1; }
  [[ "$build_number" == "$BUILD_NUMBER" ]] || { echo "Unexpected build number: $build_number" >&2; return 1; }
  grep -q "^## $VERSION" "$ROOT_DIR/CHANGELOG.md"
  echo "Verified: $APP_BUNDLE"
}

case "$MODE" in
  build|--build)
    build_app
    ;;
  package|--package)
    package_app
    ;;
  install|--install)
    require_stable_signing
    build_app local
    install_app
    ;;
  run|--run)
    require_stable_signing
    build_app
    install_app
    run_app
    ;;
  dev-run|--dev-run)
    build_app
    install_app
    run_app
    ;;
  stop|--stop)
    stop_app
    ;;
  open-existing|--open-existing)
    [[ -x "$USER_APP_BUNDLE/Contents/MacOS/$APP_NAME" ]] || {
      echo "Installed app bundle not found. Run $0 install first." >&2
      exit 1
    }
    run_app
    ;;
  debug|--debug)
    build_app
    lldb -- "$APP_BINARY"
    ;;
  logs|--logs)
    require_stable_signing
    build_app
    install_app
    run_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  telemetry|--telemetry)
    require_stable_signing
    build_app
    install_app
    run_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  verify|--verify)
    require_stable_signing
    build_app
    verify_app
    ;;
  *)
    usage
    exit 2
    ;;
esac
