#!/usr/bin/env bash
# vendor_grdb.sh: fetch GRDB (MIT) at a pinned commit into Vendor/GRDB.swift and apply the
# SQLCipher edits GRDB documents for SwiftPM ("GRDB+SQLCipher" comments in its Package.swift).
# SQLCipher.swift (BSD-3-Clause) is pinned exactly in the patch; SwiftPM verifies its binary checksum.
set -euo pipefail

GRDB_TAG="v7.12.0"
GRDB_COMMIT="92a554cd0d5e8d67cb18993c6054e73fe42c066c"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/GRDB.swift"
PATCH="$ROOT/scripts/patches/grdb-7.12.0-sqlcipher.patch"

if [[ -d "$DEST/.git" ]] && [[ "$(git -C "$DEST" rev-parse HEAD)" == "$GRDB_COMMIT" ]] \
   && git -C "$DEST" diff --quiet -- . ':!Package.swift' \
   && [[ "$(git -C "$DEST" diff -- Package.swift)" == "$(cat "$PATCH")" ]]; then
  echo "vendor_grdb: GRDB $GRDB_TAG with SQLCipher patch already in place"
  exit 0
fi

rm -rf "$DEST"
mkdir -p "$ROOT/Vendor"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$GRDB_TAG" https://github.com/groue/GRDB.swift.git "$DEST"
actual="$(git -C "$DEST" rev-parse HEAD)"
if [[ "$actual" != "$GRDB_COMMIT" ]]; then
  echo "vendor_grdb: tag $GRDB_TAG is $actual, expected $GRDB_COMMIT. Refusing to continue." >&2
  exit 1
fi
git -C "$DEST" apply "$PATCH"
echo "vendor_grdb: GRDB $GRDB_TAG ($GRDB_COMMIT) with SQLCipher patch"
