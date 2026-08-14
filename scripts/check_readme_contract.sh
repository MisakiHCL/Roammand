#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ENGLISH_README="README.md"
readonly CHINESE_README="README.zh-CN.md"
readonly CLIENT_README="apps/client_flutter/README.md"
readonly BUILDING_DOC="docs/BUILDING.md"
readonly CHINESE_BUILDING_DOC="docs/BUILDING.zh-CN.md"
readonly BRAND_README="brand/README.md"
readonly CHINESE_BRAND_README="brand/README.zh-CN.md"
readonly CHANGELOG="CHANGELOG.md"
readonly CHINESE_CHANGELOG="CHANGELOG.zh-CN.md"
readonly ENTRY_DOCS=(
  "$ENGLISH_README"
  "$CHINESE_README"
  "$CLIENT_README"
  "$BUILDING_DOC"
  "$CHINESE_BUILDING_DOC"
  "packaging/macos/README.md"
  "packaging/windows/README.md"
)
readonly DOC_INDEXES=(
  "docs/architecture/README.md"
  "docs/architecture/README.zh-CN.md"
  "docs/security/README.md"
  "docs/security/README.zh-CN.md"
)
readonly TECHNICAL_DOCS=(
  "docs/TESTING.md"
  "docs/TESTING.zh-CN.md"
  "docs/architecture/account-free-pairing-v1.md"
  "docs/architecture/desktop-identity-ipc-v1.md"
  "docs/architecture/desktop-webrtc-v1.md"
  "docs/architecture/mobile-controller-v1.md"
  "docs/architecture/protocol-v1.md"
  "docs/architecture/reconnect-v1.md"
  "docs/architecture/signaling-v1.md"
  "docs/architecture/privileged-session-bridge-v1.md"
  "docs/security/privacy-safe-diagnostics.md"
  "docs/security/privileged-helper-threat-model.md"
  "docs/self-hosting/docker-compose.md"
  "docs/self-hosting/docker-compose.zh-CN.md"
  "docs/operations/official-service-profile.md"
  "docs/operations/official-service-profile.zh-CN.md"
)

require_file() {
  local path="$1"
  [[ -f "$path" ]] || { printf 'missing public documentation: %s\n' "$path" >&2; exit 1; }
}

require_text() {
  local path="$1"
  local expected="$2"
  rg --quiet --fixed-strings -- "$expected" "$path" || {
    printf 'missing public documentation text in %s: %s\n' "$path" "$expected" >&2
    exit 1
  }
}

cd "$ROOT_DIR"

for path in \
  "${ENTRY_DOCS[@]}" \
  "$BRAND_README" \
  "$CHINESE_BRAND_README" \
  "$CHANGELOG" \
  "$CHINESE_CHANGELOG" \
  "${DOC_INDEXES[@]}" \
  "${TECHNICAL_DOCS[@]}"; do
  require_file "$path"
done

for expected in \
  '[简体中文](README.zh-CN.md)' \
  'Leave the desk. Keep work moving.' \
  '## What you can do' \
  '## How it works' \
  '## Start from source' \
  '## Security by design' \
  '[Build, run, package, and verify](docs/BUILDING.md)' \
  '[Brand design guidelines](brand/README.md)' \
  '[Architecture](docs/architecture/README.md)' \
  '[Security](docs/security/README.md)' \
  '[Official signaling and STUN service profile](docs/operations/official-service-profile.md)' \
  '[Testing and verification](docs/TESTING.md)'; do
  require_text "$ENGLISH_README" "$expected"
done

for expected in \
  '[English](README.md)' \
  '离开桌面，工作仍在继续。' \
  '## 你可以做什么' \
  '## 如何使用' \
  '## 从源码开始' \
  '## 安全设计' \
  '[构建、运行、打包和验证](docs/BUILDING.zh-CN.md)' \
  '[品牌设计规范](brand/README.zh-CN.md)' \
  '[架构](docs/architecture/README.zh-CN.md)' \
  '[安全](docs/security/README.zh-CN.md)' \
  '[官方 signaling 与 STUN 服务配置](docs/operations/official-service-profile.zh-CN.md)' \
  '[测试与验证](docs/TESTING.zh-CN.md)'; do
  require_text "$CHINESE_README" "$expected"
done

if rg -n '\]\(docs/(architecture|security|operations|testing)/\)' \
  "$ENGLISH_README" "$CHINESE_README"; then
  printf 'public README links to a documentation directory instead of an index\n' >&2
  exit 1
fi

for readme in "$ENGLISH_README" "$CHINESE_README"; do
  for expected in \
    'Roammand' \
    'make bootstrap' \
    'make app-check' \
    'make app-run-macos' \
    'docs/security/privacy-safe-diagnostics.md' \
    'LICENSES.md'; do
    require_text "$readme" "$expected"
  done
done

require_text "$ENGLISH_README" 'docs/self-hosting/docker-compose.md'
require_text "$CHINESE_README" 'docs/self-hosting/docker-compose.zh-CN.md'
require_text "$ENGLISH_README" 'iOS / iPadOS 15 or later'
require_text "$CHINESE_README" 'iOS / iPadOS 15 或更高版本'
require_text "$BUILDING_DOC" \
  'The iOS and iPadOS deployment target is 15.0 or later.'
require_text "$CHINESE_BUILDING_DOC" \
  'iOS 与 iPadOS 的最低部署版本为 15.0。'

for expected in \
  'Roammand Flutter app' \
  'make app-check' \
  'flutter run -d YOUR_ANDROID_DEVICE_ID' \
  'flutter run -d YOUR_IOS_DEVICE_ID' \
  'Mobile Controller V1' \
  'Diagnostics'; do
  require_text "$CLIENT_README" "$expected"
done

for expected in \
  'make bootstrap' \
  'make app-check' \
  'make app-build-macos' \
  'make app-build-ios-simulator' \
  'make package-macos' \
  'make test-product' \
  'scripts/configure_apple_signing.sh' \
  'scripts/package_windows.ps1'; do
  require_text "$BUILDING_DOC" "$expected"
  require_text "$CHINESE_BUILDING_DOC" "$expected"
done

require_text "$BRAND_README" 'Night Aurora'
require_text "$CHINESE_BRAND_README" '夜极光'
require_text "$BUILDING_DOC" '[简体中文](BUILDING.zh-CN.md)'
require_text "$CHINESE_BUILDING_DOC" '[English](BUILDING.md)'
require_text "$BRAND_README" '[简体中文](README.zh-CN.md)'
require_text "$CHINESE_BRAND_README" '[English](README.md)'
require_text "$CHANGELOG" '[简体中文](CHANGELOG.zh-CN.md)'
require_text "$CHINESE_CHANGELOG" '[English](CHANGELOG.md)'

for index_dir in architecture security; do
  require_text "docs/$index_dir/README.md" '[简体中文](README.zh-CN.md)'
  require_text "docs/$index_dir/README.zh-CN.md" '[English](README.md)'
done

for doc_name in \
  account-free-pairing-v1.md \
  desktop-identity-ipc-v1.md \
  desktop-webrtc-v1.md \
  mobile-controller-v1.md \
  privileged-session-bridge-v1.md \
  protocol-v1.md \
  reconnect-v1.md \
  signaling-v1.md; do
  require_text "docs/architecture/README.md" "$doc_name"
  require_text "docs/architecture/README.zh-CN.md" "$doc_name"
done

for doc_name in privacy-safe-diagnostics.md privileged-helper-threat-model.md; do
  require_text "docs/security/README.md" "$doc_name"
  require_text "docs/security/README.zh-CN.md" "$doc_name"
done

require_text "docs/TESTING.md" '[简体中文](TESTING.zh-CN.md)'
require_text "docs/TESTING.zh-CN.md" '[English](TESTING.md)'
require_text "docs/TESTING.md" 'make test-product'
require_text "docs/TESTING.zh-CN.md" 'make test-product'
require_text "docs/operations/official-service-profile.md" \
  '[简体中文](official-service-profile.zh-CN.md)'
require_text "docs/operations/official-service-profile.zh-CN.md" \
  '[English](official-service-profile.md)'
require_text "docs/operations/official-service-profile.md" \
  'TURN relay: not provided'
require_text "docs/operations/official-service-profile.zh-CN.md" \
  'TURN 中继：不提供'

if rg -n '\bM[0-8]\b|Pending|Development status|Developer preview|Release status|开发状态|发行状态|截至 M[0-8]' \
  "${ENTRY_DOCS[@]}"; then
  printf 'public entry documentation contains development-stage copy\n' >&2
  exit 1
fi

require_text "docs/architecture/reconnect-v1.md" "per-attempt delays of 1, 2, 4, 8, and 8 seconds"
require_text "docs/architecture/reconnect-v1.md" "final 7-second policy grace"
require_text "docs/architecture/reconnect-v1.md" "not a hard 30-second end-to-end latency"
require_text "docs/architecture/reconnect-v1.md" "separate 45-second fail-closed retention deadline"
require_text "docs/architecture/reconnect-v1.md" "fresh 32-byte nonce"
require_text "docs/security/privacy-safe-diagnostics.md" "roammand-diagnostics/v1"
require_text "docs/security/privacy-safe-diagnostics.md" "never uploaded automatically"
require_text "docs/self-hosting/docker-compose.md" "docker compose --env-file .env -f compose.yaml up -d --build"
require_text "docs/architecture/privileged-session-bridge-v1.md" "15 seconds"
require_text "docs/architecture/privileged-session-bridge-v1.md" "user_session_only"
require_text "docs/security/privileged-helper-threat-model.md" "long-term private key"
require_text "docs/security/privileged-helper-threat-model.md" "fail closed"
require_text "docs/TESTING.md" "Emergency stop"
require_text "docs/TESTING.zh-CN.md" "紧急停止"

printf 'README contract ok\n'
