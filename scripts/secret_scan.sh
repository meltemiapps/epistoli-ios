#!/usr/bin/env bash
# secret_scan.sh: refuse to publish secrets or personal identifiers. Run by .githooks/pre-push
# (enable once per clone: git config core.hooksPath .githooks) and by hand before anything goes public.
#
# Usage: scripts/secret_scan.sh [<commit-range>]
#   Scans every tracked file, plus the messages and author/committer lines of the commits in
#   <commit-range> (default: all commits not yet on origin/main).
#
# It looks for:
#   - email addresses (any domain can be an Apple ID), except the noreply addresses we use on purpose
#   - device identifiers: UUID-style UDIDs (simulators and older devices) and 8-16 hex device UDIDs
#   - serial numbers and device names as Xcode and Finder print them ("Serial Number: …", "…'s iPhone")
#   - personal home paths (/Users/<name>/)
#   - private keys, tokens and other secrets (gitleaks, if installed)
# Device logs and screenshots belong in build/ (gitignored), never in the repo.
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."

RANGE="${1:-}"
if [[ -z "$RANGE" ]]; then
  if git rev-parse -q --verify origin/main >/dev/null; then RANGE="origin/main..HEAD"; else RANGE="HEAD"; fi
fi

EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
# Addresses that are meant to be public: GitHub noreply identities, Claude's co-author line, and
# the placeholder in CONTRIBUTING.md.
EMAIL_OK='@users\.noreply\.github\.com|noreply@anthropic\.com|you@example\.com|@example\.(com|org)'
UDID='\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b|\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b'
DEVICE='Serial Number:? *[A-Z0-9]{8,}|[A-Za-z]+(’|'"'"')s (iPhone|iPad|Mac|MacBook)|/Users/[A-Za-z0-9._-]+/'

fail=0
report() { echo "secret_scan: $1"; fail=1; }

# 1. Tracked files. Lines may opt out with "secret-scan:allow" only for generated test data, and
# never for a real identifier.
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  [[ "$f" == scripts/secret_scan.sh ]] && continue
  file -b --mime "$f" | grep -q 'charset=binary' && continue
  hits="$(grep -n -E "$EMAIL" "$f" | grep -v -E "$EMAIL_OK" | grep -v 'secret-scan:allow' || true)"
  [[ -n "$hits" ]] && report "email address in $f:"$'\n'"$hits"
  hits="$(grep -n -E "$UDID" "$f" | grep -v 'secret-scan:allow' || true)"
  [[ -n "$hits" ]] && report "device identifier (UDID) in $f:"$'\n'"$hits"
  hits="$(grep -n -E "$DEVICE" "$f" | grep -v 'secret-scan:allow' || true)"
  [[ -n "$hits" ]] && report "device name, serial number or home path in $f:"$'\n'"$hits"
done < <(git ls-files)

# 2. Commit messages, authors and committers of the commits being published.
meta="$(git log --format='%H%n%an <%ae>%n%cn <%ce>%n%B' "$RANGE" 2>/dev/null || true)"
hits="$(printf '%s\n' "$meta" | grep -E "$EMAIL" | grep -v -E "$EMAIL_OK" || true)"
[[ -n "$hits" ]] && report "email address in commit metadata ($RANGE):"$'\n'"$hits"
hits="$(printf '%s\n' "$meta" | grep -v -E '^[0-9a-f]{40}$' | grep -E "$UDID|$DEVICE" || true)"
[[ -n "$hits" ]] && report "device identifier, name or home path in a commit message ($RANGE):"$'\n'"$hits"

# 3. Secrets in the commits being published.
if command -v gitleaks >/dev/null; then
  gitleaks git --no-banner --redact --log-opts="$RANGE" . >/dev/null 2>&1 \
    || report "gitleaks found a secret in $RANGE (run: gitleaks git --redact --log-opts=\"$RANGE\" -v .)"
else
  echo "secret_scan: gitleaks not installed; skipped the secret rules (brew install gitleaks)"
fi

[[ $fail -eq 0 ]] && echo "secret_scan: OK ($RANGE)"
exit $fail
