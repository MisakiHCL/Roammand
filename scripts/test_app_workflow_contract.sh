#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TARGETS=(
  help
  bootstrap
  app-check
  app-run-macos
  app-run-ios
  app-run-ios-release
  app-build-macos
  app-build-ios-simulator
  app-build-android
  package-macos
  package-macos-signed
  release-macos
  test-product
)
readonly STEP_TARGETS=(
  bootstrap-steps
  app-check-steps
  release-macos-steps
  test-product-steps
)

cd "$ROOT_DIR"

readonly CI_WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
ios_cocoapods_version="$(awk '$1 == "COCOAPODS:" { print $2 }' \
  apps/client_flutter/ios/Podfile.lock)"
macos_cocoapods_version="$(awk '$1 == "COCOAPODS:" { print $2 }' \
  apps/client_flutter/macos/Podfile.lock)"
if [[ -z "$ios_cocoapods_version" ||
      "$ios_cocoapods_version" != "$macos_cocoapods_version" ]]; then
  printf 'Apple Pod lockfiles must use one explicit CocoaPods version\n' >&2
  exit 1
fi
if ! rg --quiet "^  COCOAPODS_VERSION: ${ios_cocoapods_version}$" "$CI_WORKFLOW" ||
  [[ "$(rg -c 'name: Install locked CocoaPods' "$CI_WORKFLOW")" -ne 2 ]]; then
  printf 'Apple CI builds must install the CocoaPods version from the lockfiles\n' >&2
  exit 1
fi

for target in "${TARGETS[@]}"; do
  rg --quiet "^${target}:" Makefile || {
    printf 'missing product workflow target: %s\n' "$target" >&2
    exit 1
  }
done

for target in "${STEP_TARGETS[@]}"; do
  rg --quiet "^${target}:" Makefile || {
    printf 'missing quiet workflow step target: %s\n' "$target" >&2
    exit 1
  }
done

rg --quiet '^FLUTTER_ARGS \?=' Makefile || {
  printf 'missing optional Flutter argument passthrough\n' >&2
  exit 1
}

rg --quiet '^IOS_DEVICE \?=$' Makefile || {
  printf 'missing explicit iOS device selector\n' >&2
  exit 1
}

rg --quiet 'flutter run -d "\$\(IOS_DEVICE\)" --no-pub' Makefile || {
  printf 'iOS development target does not use the selected device ID\n' >&2
  exit 1
}

rg --quiet 'flutter run --release -d "\$\(IOS_DEVICE\)" --no-pub' Makefile || {
  printf 'iOS performance target is not a Release run\n' >&2
  exit 1
}

if rg --quiet 'flutter run -d ios' Makefile; then
  printf 'iOS platform name must not be used as a physical-device selector\n' >&2
  exit 1
fi

rg --quiet '^app-run-macos: app-prepare-host-macos$' Makefile || {
  printf 'macOS development app does not prepare its managed Host Agent\n' >&2
  exit 1
}

rg --quiet 'ROAMMAND_HOST_AGENT_EXECUTABLE=' Makefile || {
  printf 'macOS development app does not receive the managed Agent path\n' >&2
  exit 1
}

readonly MACOS_DEVELOPMENT_SIGNER="$ROOT_DIR/scripts/sign_macos_development.sh"
if [[ ! -x "$MACOS_DEVELOPMENT_SIGNER" ]]; then
  printf 'macOS development signing helper is missing or not executable\n' >&2
  exit 1
fi
rg --quiet 'sign_macos_development\.sh' Makefile || {
  printf 'managed Debug Agent does not receive a stable development signature\n' >&2
  exit 1
}

rg --quiet '^package-macos-signed: package-macos$' Makefile || {
  printf 'signed macOS package target does not reuse verified staging\n' >&2
  exit 1
}
rg --quiet '^release-macos:$' Makefile || {
  printf 'macOS release target is not a quiet public workflow\n' >&2
  exit 1
}
rg --quiet '^release-macos-steps: package-macos-signed$' Makefile || {
  printf 'macOS release steps do not require a signed installer\n' >&2
  exit 1
}
rg --quiet 'notarize_macos_pkg\.sh' Makefile || {
  printf 'macOS release target does not notarize the installer\n' >&2
  exit 1
}
rg --quiet 'Roammand\.pkg ready:' Makefile || {
  printf 'macOS release target does not highlight the installer path\n' >&2
  exit 1
}

rg --quiet 'applicationShouldHandleReopen' \
  apps/client_flutter/macos/Runner/AppDelegate.swift || {
  printf 'macOS app does not restore its window from the Dock\n' >&2
  exit 1
}
rg --quiet 'onTrayIconRightMouseDown' \
  apps/client_flutter/lib/desktop/tray/flutter_host_tray_port.dart || {
  printf 'macOS tray does not handle a right click\n' >&2
  exit 1
}
rg --quiet 'popUpContextMenu' \
  apps/client_flutter/lib/desktop/tray/flutter_host_tray_port.dart || {
  printf 'macOS tray right click does not open its menu\n' >&2
  exit 1
}

if [[ "$(rg -c 'flutter run .*--no-pub' Makefile)" -ne 3 ]]; then
  printf 'app run targets should reuse bootstrapped Flutter packages\n' >&2
  exit 1
fi

if [[ "$(rg -c 'flutter build .*--no-pub' Makefile)" -ne 3 ]]; then
  printf 'app build targets should reuse bootstrapped Flutter packages\n' >&2
  exit 1
fi

if ! rg --quiet 'flutter analyze --no-pub' Makefile || \
  ! rg --quiet 'flutter test --no-pub' Makefile; then
  printf 'app checks should reuse bootstrapped Flutter packages\n' >&2
  exit 1
fi

rg --quiet '^VERBOSE \?= 0$' Makefile || {
  printf 'missing quiet workflow default\n' >&2
  exit 1
}

readonly QUIET_RUNNER="$ROOT_DIR/scripts/run_quiet_workflow.sh"
if [[ ! -x "$QUIET_RUNNER" ]]; then
  printf 'quiet workflow runner is not executable\n' >&2
  exit 1
fi

success_output="$(
  "$QUIET_RUNNER" sample-success bash -c \
    'printf "hidden success detail\\n"; exit 0'
)"
if [[ "$success_output" != '[PASS] sample-success completed in '* ]] || \
  [[ "$success_output" == *'hidden success detail'* ]]; then
  printf 'quiet workflow runner exposed successful command output\n' >&2
  exit 1
fi

set +e
failure_output="$(
  "$QUIET_RUNNER" sample-failure bash -c \
    'printf "useful failure detail\\n" >&2; exit 9' 2>&1
)"
failure_status="$?"
set -e

if [[ "$failure_status" -ne 9 ]] || \
  [[ "$failure_output" != *'[FAIL] sample-failure failed after '* ]] || \
  [[ "$failure_output" != *'useful failure detail'* ]] || \
  [[ "$failure_output" != *'Full log: '* ]] || \
  [[ "$failure_output" != *'make sample-failure VERBOSE=1'* ]]; then
  printf 'quiet workflow runner did not report failure clearly\n' >&2
  exit 1
fi

failure_log="$(
  printf '%s\n' "$failure_output" | sed -n 's/^Full log: //p'
)"
if [[ -z "$failure_log" ]] || [[ ! -f "$failure_log" ]]; then
  printf 'quiet workflow runner did not preserve the failed log\n' >&2
  exit 1
fi
rm -f "$failure_log"

readonly NATIVE_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/roammand-native-workflow.XXXXXX")"
trap 'rm -rf "$NATIVE_FIXTURE"' EXIT
mkdir -p "$NATIVE_FIXTURE/scripts" "$NATIVE_FIXTURE/bin"
cp Makefile "$NATIVE_FIXTURE/Makefile"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NATIVE_FIXTURE/scripts/check_libwebrtc_assets.sh"
cat > "$NATIVE_FIXTURE/scripts/fetch_libwebrtc.sh" <<'SH'
#!/usr/bin/env bash
if [[ "$ROAMMAND_TEST_FAIL_STEP" -eq 0 ]]; then
  exit 9
fi
printf '/fixture/webrtc\n'
SH
cat > "$NATIVE_FIXTURE/bin/cargo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ROAMMAND_TEST_CALL_LOG"
call_count="$(wc -l < "$ROAMMAND_TEST_CALL_LOG")"
if [[ "$call_count" -eq "$ROAMMAND_TEST_FAIL_STEP" ]]; then
  exit 9
fi
SH
chmod +x "$NATIVE_FIXTURE/scripts/"*.sh "$NATIVE_FIXTURE/bin/cargo"

# A failure in asset fetching or any native test/lint must stop the gate;
# successful later commands must never hide an earlier failure.
for fail_step in 0 1 2 3 4 5; do
  call_log="$NATIVE_FIXTURE/cargo-calls"
  : > "$call_log"
  set +e
  PATH="$NATIVE_FIXTURE/bin:$PATH" \
    ROAMMAND_TEST_FAIL_STEP="$fail_step" ROAMMAND_TEST_CALL_LOG="$call_log" \
    make --no-print-directory -C "$NATIVE_FIXTURE" test-native-webrtc \
    > "$NATIVE_FIXTURE/output" 2>&1
  native_status="$?"
  set -e
  call_count="$(wc -l < "$call_log")"
  if [[ "$fail_step" -lt 5 ]]; then
    if [[ "$native_status" -eq 0 || "$call_count" -ne "$fail_step" ]]; then
      printf 'native workflow did not stop at failed step %s\n' "$fail_step" >&2
      cat "$NATIVE_FIXTURE/output" >&2
      exit 1
    fi
  elif [[ "$native_status" -ne 0 || "$call_count" -ne 4 ]]; then
    printf 'native workflow did not run all successful checks\n' >&2
    cat "$NATIVE_FIXTURE/output" >&2
    exit 1
  fi
done

printf 'app workflow contract ok\n'
