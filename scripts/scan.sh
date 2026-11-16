#!/bin/bash
# Pre-push privacy scan: gitleaks over the whole history + a grep for personal markers.
# Personal terms come from the git-ignored file scripts/scan-terms.local (one regex per line),
# so the list of private names never lands in the repo itself.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
gitleaks detect --source . --redact --no-banner || fail=1
gitleaks detect --source . --no-git --redact --no-banner || fail=1
TERMS=scripts/scan-terms.local
PATTERNS=('192\.168\.' '10\.[0-9]+\.[0-9]+\.[0-9]+' 'BEGIN (RSA|EC|OPENSSH) PRIVATE KEY' 'eyJ[A-Za-z0-9_-]{20,}' 'ahmcp_[A-Za-z0-9_-]{20,}')
[ -f "$TERMS" ] && while IFS= read -r t; do [ -n "$t" ] && PATTERNS+=("$t"); done < "$TERMS"
for p in "${PATTERNS[@]}"; do
  # LICENSE carries the author's name by design; everything else must be clean.
  hits=$(git grep -n -i -E "$p" -- . ':!scripts/scan.sh' ':!LICENSE' 2>/dev/null; git log --all -p -- . ':!LICENSE' ':!scripts/scan.sh' 2>/dev/null | grep '^[+-]' | grep -i -E -c "$p" | grep -v '^0$' | sed "s/^/history matches: /")
  if [ -n "$hits" ]; then echo "== pattern: $p"; echo "$hits"; fail=1; fi
done
[ $fail -eq 0 ] && echo "scan clean" || echo "scan found matches above - fix before pushing"
exit $fail
