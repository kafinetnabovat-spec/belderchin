#!/usr/bin/env bash
# Pushes the full history (upstream hiddify-app up to v4.1.2 + Belderchin commits)
# to the public repository. The token is read from the environment ONLY and is
# passed to git through a one-off HTTP header - it is never written to disk.
#
#   GITHUB_TOKEN=ghp_xxx bash tools/ci/push_to_github.sh [--force] [--reshallow]
#
# --force      needed when the target was created with GitHub's Fork button
#              (its main is ahead of v4.1.2 and must be replaced).
# --reshallow  shrink the local clone back to a shallow history afterwards.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

TARGET="${TARGET_REPO:-https://github.com/kafinetnabovat-spec/belderchin.git}"
UPSTREAM="https://github.com/hiddify/hiddify-app.git"
: "${GITHUB_TOKEN:?set GITHUB_TOKEN in the environment (repo + workflow scopes)}"

FORCE=""; RESHALLOW=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE="--force-with-lease=main" ;;
    --reshallow) RESHALLOW=1 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM"
git remote get-url origin >/dev/null 2>&1 && git remote set-url origin "$TARGET" || git remote add origin "$TARGET"

if [ -f .git/shallow ]; then
  echo "==> fetching full upstream history (shallow clone detected)"
  git fetch --unshallow upstream
fi

export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
echo "==> pushing main to $TARGET"
git push $FORCE origin main
# Tags are deliberately NOT pushed: upstream tags would trigger release builds.

if [ "$RESHALLOW" = 1 ]; then
  echo "==> re-shallowing local clone"
  git fetch --depth=20 origin main
  git reflog expire --expire=now --all
  git gc --prune=now --quiet
fi
echo "==> done. Remote URL contains no credentials: $(git remote get-url origin)"
