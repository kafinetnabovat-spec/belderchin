#!/usr/bin/env bash
# Fails when anything that looks like a credential is tracked by git.
# Runs locally (make secrets-scan) and in CI. Keep the patterns conservative:
# a false positive can be allow-listed below with a comment explaining why.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

status=0

# 1) Forbidden file types / names (keystores, key material, env files).
forbidden_files=$(git ls-files | grep -E '(\.jks|\.keystore|\.p12|\.pfx|\.pem|\.key|\.p8|key\.properties|\.env|\.netrc|id_rsa|id_ed25519|\.private\.hex)$' || true)
if [[ -n "$forbidden_files" ]]; then
  echo "::error::Forbidden secret-like files are tracked by git:"
  echo "$forbidden_files"
  status=1
fi

# 2) Token / key patterns inside tracked text files.
patterns=(
  'ghp_[A-Za-z0-9]{36}'                       # GitHub classic PAT
  'github_pat_[A-Za-z0-9_]{80,}'              # GitHub fine-grained PAT
  'gho_[A-Za-z0-9]{36}'
  'AKIA[0-9A-Z]{16}'                          # AWS access key id
  'AIza[0-9A-Za-z_-]{35}'                     # Google API key
  'sk_live_[0-9a-zA-Z]{20,}'
  'xox[baprs]-[0-9A-Za-z-]{10,}'              # Slack
  '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
  'https://[0-9a-f]{32}@[a-z0-9.]+ingest[a-z0-9.]*sentry\.io' # Sentry DSN
  'storePassword=[^ $][^ ]*'
  'keyPassword=[^ $][^ ]*'
)
allow_regex='^(tools/ci/secrets_scan\.sh|docs/.*\.md|README.*\.md|reports/.*)$'
files=$(git ls-files | grep -Ev "$allow_regex" | grep -Ev '\.(png|jpg|jpeg|ico|ttf|otf|webp|gif|pdf|aar|jar|so|zip|gz)$' || true)
for pattern in "${patterns[@]}"; do
  hits=$(echo "$files" | xargs -r grep -EnI -- "$pattern" 2>/dev/null || true)
  if [[ -n "$hits" ]]; then
    echo "::error::Possible secret matching /$pattern/:"
    echo "$hits"
    status=1
  fi
done

if [[ $status -eq 0 ]]; then
  echo "secrets-scan: OK (no tracked keys, tokens or keystores found)"
fi
exit $status
