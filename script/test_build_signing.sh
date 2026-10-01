#!/usr/bin/env bash
set -euo pipefail

case "${0##*/}" in
  swift)
    printf '%s\n' "$*" >>"$TEST_SWIFT_CALLS"
    if [[ "${1:-}" == "build" && "${2:-}" == "--show-bin-path" ]]; then
      printf '%s\n' "$TEST_BUILD_BIN"
    fi
    exit 0
    ;;
  codesign)
    printf '%s\n' "$*" >>"$TEST_CODESIGN_CALLS"
    case "${1:-}" in
      --force|--verify)
        exit 0
        ;;
      --display)
        printf '%s\n' "${TEST_SIGNATURE_DETAILS:-Signature=adhoc}" >&2
        exit "${TEST_SIGNATURE_EXIT_CODE:-0}"
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  PlistBuddy)
    source "$TEST_APP_METADATA"
    case "${2:-}" in
      *CFBundleIdentifier*) printf '%s\n' "$BUNDLE_ID" ;;
      *CFBundleShortVersionString*) printf '%s\n' "$VERSION" ;;
      *CFBundleVersion*) printf '%s\n' "$BUILD_NUMBER" ;;
      *) exit 2 ;;
    esac
    exit 0
    ;;
  open)
    exit 0
    ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vidlingo-signing-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/script" "$TEST_ROOT/Resources" "$TEST_ROOT/bin" "$TEST_ROOT/install"
cp "$REPO_ROOT/script/app_metadata.sh" "$TEST_ROOT/script/app_metadata.sh"
cp "$REPO_ROOT/script/write_info_plist.sh" "$TEST_ROOT/script/write_info_plist.sh"
cp "$REPO_ROOT/Resources/AppIcon.icns" "$TEST_ROOT/Resources/AppIcon.icns"
cp "$REPO_ROOT/Resources/TranslationSystemPrompt.md" "$TEST_ROOT/Resources/TranslationSystemPrompt.md"
cp "$REPO_ROOT/CHANGELOG.md" "$TEST_ROOT/CHANGELOG.md"
perl -pe 's|/usr/bin/codesign|"\$TEST_CODESIGN_STUB"|g; s|/usr/libexec/PlistBuddy|"\$TEST_PLISTBUDDY_STUB"|g; s|/usr/bin/open|"\$TEST_OPEN_STUB"|g; s|USER_APPLICATIONS_DIR="\$HOME/Applications"|USER_APPLICATIONS_DIR="\$TEST_INSTALL_DIR"|' \
  "$REPO_ROOT/script/build_and_run.sh" >"$TEST_ROOT/script/build_and_run.sh"
chmod +x "$TEST_ROOT/script/build_and_run.sh"

TEST_BUILD_BIN="$TEST_ROOT/build-bin"
mkdir -p "$TEST_BUILD_BIN"
cp /usr/bin/true "$TEST_BUILD_BIN/VidLingo"
TEST_SWIFT_CALLS="$TEST_ROOT/swift-calls"
TEST_CODESIGN_CALLS="$TEST_ROOT/codesign-calls"
TEST_APP_METADATA="$TEST_ROOT/script/app_metadata.sh"
TEST_INSTALL_DIR="$TEST_ROOT/install"
TEST_CODESIGN_STUB="$TEST_ROOT/bin/codesign"
TEST_PLISTBUDDY_STUB="$TEST_ROOT/bin/PlistBuddy"
TEST_OPEN_STUB="$TEST_ROOT/bin/open"
cp "${BASH_SOURCE[0]}" "$TEST_ROOT/bin/stub"
chmod +x "$TEST_ROOT/bin/stub"
ln -s stub "$TEST_ROOT/bin/swift"
ln -s stub "$TEST_CODESIGN_STUB"
ln -s stub "$TEST_PLISTBUDDY_STUB"
ln -s stub "$TEST_OPEN_STUB"
export TEST_BUILD_BIN TEST_SWIFT_CALLS TEST_CODESIGN_CALLS TEST_APP_METADATA TEST_INSTALL_DIR
export TEST_CODESIGN_STUB TEST_PLISTBUDDY_STUB TEST_OPEN_STUB

stable_modes=(install run package logs telemetry verify)
invalid_identities=("" "-" " - " "   " $' \t\n')
for mode in "${stable_modes[@]}"; do
  for identity in "${invalid_identities[@]}"; do
    : >"$TEST_SWIFT_CALLS"
    : >"$TEST_CODESIGN_CALLS"
    if PATH="$TEST_ROOT/bin:/usr/bin:/bin" CODE_SIGN_IDENTITY="$identity" \
      "$TEST_ROOT/script/build_and_run.sh" "$mode" >/dev/null 2>&1; then
      printf 'FAIL: %s accepted invalid CODE_SIGN_IDENTITY %q\n' "$mode" "$identity" >&2
      exit 1
    fi
    if [[ -s "$TEST_SWIFT_CALLS" || -s "$TEST_CODESIGN_CALLS" ]]; then
      printf 'FAIL: %s started a build before rejecting CODE_SIGN_IDENTITY %q\n' "$mode" "$identity" >&2
      exit 1
    fi
  done
done

: >"$TEST_SWIFT_CALLS"
: >"$TEST_CODESIGN_CALLS"
if PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
  CODE_SIGN_IDENTITY="Developer ID Application: Test (ABCDE12345)" \
  TEST_SIGNATURE_DETAILS=$'Authority=Developer ID Application: Test (ABCDE12345)\nTeamIdentifier=ABCDE12345' \
  "$TEST_ROOT/script/build_and_run.sh" verify >"$TEST_ROOT/verify-output" 2>&1; then
  :
else
  cat "$TEST_ROOT/verify-output" >&2
  printf 'FAIL: verify rejected a non-ad-hoc codesign authority\n' >&2
  exit 1
fi
if ! grep -q -- '--display --verbose=4' "$TEST_CODESIGN_CALLS"; then
  printf 'FAIL: verify did not inspect the built app signature\n' >&2
  exit 1
fi

: >"$TEST_SWIFT_CALLS"
: >"$TEST_CODESIGN_CALLS"
if PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
  CODE_SIGN_IDENTITY="Developer ID Application: Claimed (ABCDE12345)" \
  TEST_SIGNATURE_DETAILS=$'Signature=adhoc' \
  "$TEST_ROOT/script/build_and_run.sh" verify >/dev/null 2>&1; then
  printf 'FAIL: verify accepted an ad-hoc signature with a non-empty identity setting\n' >&2
  exit 1
fi
if ! grep -q -- '--display --verbose=4' "$TEST_CODESIGN_CALLS"; then
  printf 'FAIL: verify did not inspect the ad-hoc signature\n' >&2
  exit 1
fi

: >"$TEST_SWIFT_CALLS"
: >"$TEST_CODESIGN_CALLS"
if PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
  CODE_SIGN_IDENTITY="Developer ID Application: Claimed (ABCDE12345)" \
  TEST_SIGNATURE_DETAILS=$'Identifier=dev.appcaster.VidLingo\nSignature=non-adhoc-without-authority' \
  "$TEST_ROOT/script/build_and_run.sh" verify >/dev/null 2>&1; then
  printf 'FAIL: verify accepted a signature without a codesign authority\n' >&2
  exit 1
fi
if ! grep -q -- '--display --verbose=4' "$TEST_CODESIGN_CALLS"; then
  printf 'FAIL: verify did not inspect the authority-free signature\n' >&2
  exit 1
fi

: >"$TEST_SWIFT_CALLS"
: >"$TEST_CODESIGN_CALLS"
if PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
  CODE_SIGN_IDENTITY="-" TEST_SIGNATURE_DETAILS='Signature=adhoc' \
  "$TEST_ROOT/script/build_and_run.sh" dev-run >/dev/null 2>&1; then
  :
else
  printf 'FAIL: dev-run no longer supports explicit ad-hoc signing\n' >&2
  exit 1
fi
if ! grep -q -- '--sign -' "$TEST_CODESIGN_CALLS"; then
  printf 'FAIL: dev-run did not use the explicit ad-hoc identity\n' >&2
  exit 1
fi

: >"$TEST_SWIFT_CALLS"
: >"$TEST_CODESIGN_CALLS"
if PATH="$TEST_ROOT/bin:/usr/bin:/bin" VIDLINGO_ALLOW_ADHOC_SIGNING=0 CODE_SIGN_IDENTITY="-" \
  "$TEST_ROOT/script/build_and_run.sh" build >/dev/null 2>&1; then
  printf 'FAIL: build accepted ad-hoc signing when it was disabled\n' >&2
  exit 1
fi
if [[ -s "$TEST_SWIFT_CALLS" || -s "$TEST_CODESIGN_CALLS" ]]; then
  printf 'FAIL: build started before rejecting disabled ad-hoc signing\n' >&2
  exit 1
fi

: >"$TEST_SWIFT_CALLS"
: >"$TEST_CODESIGN_CALLS"
if PATH="$TEST_ROOT/bin:/usr/bin:/bin" VIDLINGO_ALLOW_ADHOC_SIGNING=0 \
  CODE_SIGN_IDENTITY="Developer ID Application: Claimed (ABCDE12345)" \
  TEST_SIGNATURE_DETAILS='Signature=adhoc' \
  "$TEST_ROOT/script/build_and_run.sh" build >/dev/null 2>&1; then
  printf 'FAIL: build trusted CODE_SIGN_IDENTITY without inspecting the produced signature\n' >&2
  exit 1
fi
if ! grep -q -- '--display --verbose=4' "$TEST_CODESIGN_CALLS"; then
  printf 'FAIL: build did not inspect the signature when ad-hoc signing was disabled\n' >&2
  exit 1
fi

: >"$TEST_SWIFT_CALLS"
: >"$TEST_CODESIGN_CALLS"
if PATH="$TEST_ROOT/bin:/usr/bin:/bin" VIDLINGO_ALLOW_ADHOC_SIGNING=1 CODE_SIGN_IDENTITY="" \
  "$TEST_ROOT/script/build_and_run.sh" build >/dev/null 2>&1; then
  :
else
  printf 'FAIL: local build no longer supports explicitly allowed ad-hoc signing\n' >&2
  exit 1
fi

printf 'PASS: stable modes reject empty, whitespace, and ad-hoc identities; stable verification inspects codesign output; local ad-hoc modes remain available.\n'
