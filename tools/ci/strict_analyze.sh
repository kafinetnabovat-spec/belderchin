#!/usr/bin/env bash
# Zero-tolerance analysis for code owned by Belderchin (not inherited from upstream).
# Add new Belderchin directories/files here as they are created.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

targets=(
  lib/features/sources
  lib/features/auto_connect
  lib/features/warp
  lib/features/troubleshoot
  lib/features/onboarding
  lib/core/security
  test/features/sources
  test/features/auto_connect
  test/features/warp
  test/core/security
)

existing=()
for t in "${targets[@]}"; do
  [[ -e "$t" ]] && existing+=("$t")
done

if [[ ${#existing[@]} -eq 0 ]]; then
  echo "strict-analyze: no Belderchin-owned targets exist yet - nothing to do"
  exit 0
fi

echo "strict-analyze: ${existing[*]}"
dart analyze --fatal-infos --fatal-warnings "${existing[@]}"
