#!/usr/bin/env bash
# bootstrap.sh: fetch and build everything in Vendor/ (not committed), then generate the Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/vendor_grdb.sh
scripts/build_gopenpgp.sh "$@"
xcodegen generate
