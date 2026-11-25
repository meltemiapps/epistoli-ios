#!/usr/bin/env bash
# brand_check.sh: every brand string the app binary uses must live only in Config/Base.xcconfig.
# Runs on macOS and Linux. Exit code 1 on any violation.
set -euo pipefail
export LC_ALL=C.UTF-8 2>/dev/null || true
cd "$(dirname "$0")/.."

GREEK_BRAND='Επιστολή'
ASCII_BRAND='[Ee][Pp][Ii][Ss][Tt][Oo][Ll][Ii]'
OLD_BRAND='[Ee][Tt][Ee][Ss][Ii][Aa]|Ετησία|ΕΤΗΣΙΑ'

# Files allowed to contain the brand as text (documentation, config, tests, this script).
ALLOW='^(Config/Base\.xcconfig|README\.md|CONTRIBUTING\.md|CLA\.md|LICENSE|docs/.*|AppTests/.*|Packages/[^/]+/Tests/.*|scripts/brand_check\.sh|\.github/.*)$'

files() { git ls-files --cached --others --exclude-standard; }
fail=0

# 1. The Greek brand may only appear in allow-listed files.
while IFS= read -r f; do
  [[ "$f" =~ $ALLOW ]] && continue
  if grep -nF "$GREEK_BRAND" "$f" 2>/dev/null; then
    echo "brand_check: '$GREEK_BRAND' hard-coded in $f (use Config/Base.xcconfig)"; fail=1
  fi
done < <(files)

# 2. The ASCII brand may not appear inside a string literal in app or package sources.
while IFS= read -r f; do
  [[ "$f" == *.swift ]] || continue
  [[ "$f" =~ ^(App/Sources|Packages/[^/]+/Sources)/ ]] || continue
  if grep -nE "\"[^\"]*${ASCII_BRAND}[^\"]*\"" "$f"; then
    echo "brand_check: ASCII brand in a string literal in $f (use Brand / Info.plist)"; fail=1
  fi
done < <(files)

# 3. The old working name must not appear anywhere.
while IFS= read -r f; do
  [[ "$f" == scripts/brand_check.sh ]] && continue
  if grep -nE "$OLD_BRAND" "$f" 2>/dev/null; then
    echo "brand_check: old working name found in $f"; fail=1
  fi
done < <(files)

# 4. The display name in Base.xcconfig must be the Greek brand.
grep -qE "^BRAND_DISPLAY_NAME = ${GREEK_BRAND}\$" Config/Base.xcconfig \
  || { echo "brand_check: BRAND_DISPLAY_NAME in Config/Base.xcconfig is not '$GREEK_BRAND'"; fail=1; }

[[ $fail -eq 0 ]] && echo "brand_check: OK"
exit $fail
