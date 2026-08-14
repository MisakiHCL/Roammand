#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REQUIRED_PUBLIC_FILES=(
  "README.md"
  "README.zh-CN.md"
  "CHANGELOG.md"
  "CHANGELOG.zh-CN.md"
  "CONTRIBUTING.md"
  "SECURITY.md"
  "LICENSES.md"
  "docs/BUILDING.md"
  "docs/BUILDING.zh-CN.md"
  "docs/TESTING.md"
  "docs/TESTING.zh-CN.md"
  "docs/architecture/desktop-identity-ipc-v1.md"
  "docs/architecture/account-free-pairing-v1.md"
  "docs/architecture/reconnect-v1.md"
  "docs/architecture/privileged-session-bridge-v1.md"
  "docs/security/privacy-safe-diagnostics.md"
  "docs/security/privileged-helper-threat-model.md"
  "docs/operations/official-service-profile.md"
  "docs/operations/official-service-profile.zh-CN.md"
  "docs/self-hosting/docker-compose.md"
  "docs/self-hosting/docker-compose.zh-CN.md"
  "licenses/MPL-2.0.txt"
  "licenses/AGPL-3.0-only.txt"
  "licenses/Apache-2.0.txt"
)
readonly FORBIDDEN_PATTERNS=(
  "Documents/Codex"
  "../internal/"
  ".superpowers/brainstorm"
)
readonly FORBIDDEN_PUBLIC_MARKDOWN_PATTERN='\bM[0-9]+\b|test-m[0-9]+|package_m[0-9]+|install_m[0-9]+|uninstall_m[0-9]+|dist[/\\]m[0-9]+|final-product-acceptance|official-infrastructure-plan|docs/testing/|Implementation status|Development status|Developer preview|Release status|current checkout|early development|later milestones?|future AI capability|product roadmap|implementation plan|discussion notes|conversation transcript|decision log|rejected alternatives|work log|实现状态|开发状态|发行状态|当前检出|早期开发|后续里程碑|尚未实现的 AI 功能|产品规划|产品路线图|讨论记录|对话记录|聊天记录|实施计划|工作日志|被否决方案'

is_sensitive_tracked_file() {
  local path="$1"
  local name="${path##*/}"
  case "$name" in
    .env|.env.local|Signing.local.xcconfig|*.local.xcconfig|\
      *.certSigningRequest|*.cer|*.key|*.pem|*.p8|*.p12|*.pfx|\
      *.mobileprovision|*.provisionprofile|*.xcarchive|*.ipa|*.pkg|*.dmg|\
      notarytool*.json|notarization*.json)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

cd "$ROOT_DIR"

for required_file in "${REQUIRED_PUBLIC_FILES[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    printf 'missing public file: %s\n' "$required_file" >&2
    exit 1
  fi
done

for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
  if rg --quiet --hidden --fixed-strings \
    --glob '!.git' \
    --glob '!.git/**' \
    --glob '!scripts/check_public_boundary.sh' \
    "$pattern" .; then
    printf 'forbidden internal reference found\n' >&2
    exit 1
  fi
done

if rg --quiet --hidden --ignore-case \
  --glob '!.git' \
  --glob '!.git/**' \
  --glob '!third_party/**' \
  --glob '!scripts/macos_release_compliance/vetted_notices/**' \
  --glob '*.md' \
  "$FORBIDDEN_PUBLIC_MARKDOWN_PATTERN" .; then
  printf 'public Markdown contains internal process or milestone terminology\n' >&2
  exit 1
fi

while IFS= read -r markdown_file; do
  [[ -f "$markdown_file" ]] || continue
  if rg --quiet --ignore-case \
    '(^|/)(plans?|roadmap|conversations?|chat|.*acceptance.*)\.md$' \
    <<<"$markdown_file"; then
    printf 'internal planning or acceptance document is tracked publicly\n' >&2
    exit 1
  fi
done < <(git ls-files --cached --others --exclude-standard '*.md' '*.MD')

if rg --quiet --hidden \
  --glob '!.git' \
  --glob '!.git/**' \
  --glob '!scripts/check_public_boundary.sh' \
  '(/Users/[^/[:space:]]+/|/home/[^/[:space:]]+/|[A-Za-z]:\\Users\\[^\\[:space:]]+\\)' .; then
  printf 'personal filesystem path found in public files\n' >&2
  exit 1
fi

while IFS= read -r -d '' tracked_file; do
  [[ -f "$tracked_file" ]] || continue
  if is_sensitive_tracked_file "$tracked_file"; then
    printf 'sensitive Apple release file is tracked\n' >&2
    exit 1
  fi
done < <(git ls-files -z --cached --others --exclude-standard)

if git grep --quiet -I -E -- \
  '-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----'; then
  printf 'private key material found in tracked files\n' >&2
  exit 1
fi

readonly LOCAL_SIGNING_CONFIG="apps/client_flutter/apple/Signing.local.xcconfig"
if [[ -f "$LOCAL_SIGNING_CONFIG" ]]; then
  local_team_id="$(awk '
    $1 == "ROAMMAND_APPLE_TEAM_ID" && $2 == "=" && NF == 3 {
      count += 1
      value = $3
    }
    END { if (count == 1) print value }
  ' "$LOCAL_SIGNING_CONFIG")"
  if [[ -n "$local_team_id" ]] && git grep --quiet -I --fixed-strings \
    "$local_team_id"; then
    printf 'local Apple Team ID found in tracked files\n' >&2
    exit 1
  fi
fi

printf 'public boundary ok\n'
