#!/usr/bin/env bash
# build_gopenpgp.sh: build Vendor/EpistoliPGP.xcframework from Bridge/ (GopenPGP v3, MIT) with gomobile.
#
# Pins:
#   - Go toolchain: GO_VERSION below (the script refuses any other version).
#   - GopenPGP, go-crypto and every other Go module: Bridge/go.mod + Bridge/go.sum (checked with `go mod verify`).
#   - gomobile/gobind: the `tool` lines in Bridge/go.mod (golang.org/x/mobile at a fixed commit).
#
# Output checksum: a SHA-256 over every file in the xcframework is written to
# Vendor/EpistoliPGP.xcframework.sha256 and compared with scripts/gopenpgp.lock, which holds one
# expected checksum per Xcode build (the C/Objective-C glue is compiled by Xcode's clang, so the
# output differs between Xcode versions).
#
# Usage:
#   scripts/build_gopenpgp.sh            build, then verify against the lock (warn if no entry)
#   scripts/build_gopenpgp.sh --strict   build, fail if no lock entry for this Xcode or a mismatch
#   scripts/build_gopenpgp.sh --record   build, then record this Xcode's checksum in the lock
set -euo pipefail

GO_VERSION="1.27.4"
GOPENPGP_VERSION="v3.5.2"
MIN_OS="26.0"
NAME="EpistoliPGP"

MODE="${1:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$ROOT/Bridge"
OUT_DIR="$ROOT/Vendor"
OUT="$OUT_DIR/$NAME.xcframework"
TOOLS="$ROOT/.tools"
LOCK="$ROOT/scripts/gopenpgp.lock"

have_go="$(go env GOVERSION 2>/dev/null || true)"
if [[ "$have_go" != "go$GO_VERSION" ]]; then
  echo "build_gopenpgp: need Go $GO_VERSION, found '${have_go:-none}'" >&2
  exit 1
fi

cd "$BRIDGE"
pinned="$(go list -m -f '{{.Version}}' github.com/ProtonMail/gopenpgp/v3)"
if [[ "$pinned" != "$GOPENPGP_VERSION" ]]; then
  echo "build_gopenpgp: Bridge/go.mod pins GopenPGP $pinned, script expects $GOPENPGP_VERSION" >&2
  exit 1
fi
go mod verify

echo "build_gopenpgp: building gomobile and gobind from Bridge/go.mod pins"
mkdir -p "$TOOLS"
go build -o "$TOOLS/" golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
export PATH="$TOOLS:$PATH"

# Reproducibility: zero archive member dates (honoured by Apple's libtool/ar).
export ZERO_AR_DATE=1

echo "build_gopenpgp: binding $NAME (GopenPGP $GOPENPGP_VERSION) for ios, iossimulator, macos"
rm -rf "$OUT"
mkdir -p "$OUT_DIR"
gomobile bind \
  -target ios,iossimulator,macos \
  -iosversion "$MIN_OS" \
  -macosversion "$MIN_OS" \
  -trimpath \
  -ldflags "-s -w -buildid=" \
  -o "$OUT" \
  ./pgpbridge

# Reproducibility: gomobile stamps the build time into each framework's version and lists the
# xcframework's libraries in a random order. Set a fixed version and sort the list.
python3 -I - "$OUT" "${GOPENPGP_VERSION#v}" <<'PY'
import pathlib, plistlib, sys
out, version = pathlib.Path(sys.argv[1]), sys.argv[2]
top = out / "Info.plist"
d = plistlib.loads(top.read_bytes())
d["AvailableLibraries"].sort(key=lambda lib: lib["LibraryIdentifier"])
for lib in d["AvailableLibraries"]:
    lib.get("SupportedArchitectures", []).sort()
top.write_bytes(plistlib.dumps(d, fmt=plistlib.FMT_XML, sort_keys=True))
for p in out.glob("*/*.framework/**/Info.plist"):
    f = plistlib.loads(p.read_bytes())
    f["CFBundleShortVersionString"] = version
    f["CFBundleVersion"] = version
    p.write_bytes(plistlib.dumps(f, fmt=plistlib.FMT_XML, sort_keys=True))
PY

# Checksum: SHA-256 of the sorted list of "<sha256>  <relative path>" for every file.
sum="$(cd "$OUT" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
xcode_build="$(xcodebuild -version | awk '/Build version/ {print $3}')"
echo "$sum" > "$OUT.sha256"
echo "build_gopenpgp: Xcode $xcode_build checksum $sum"

touch "$LOCK"
expected="$(awk -v x="$xcode_build" '$1 == x {print $2}' "$LOCK")"
if [[ "$MODE" == "--record" ]]; then
  grep -v "^$xcode_build " "$LOCK" > "$LOCK.tmp" || true
  echo "$xcode_build $sum" >> "$LOCK.tmp"
  LC_ALL=C sort "$LOCK.tmp" > "$LOCK" && rm "$LOCK.tmp"
  echo "build_gopenpgp: recorded checksum for Xcode $xcode_build in scripts/gopenpgp.lock"
elif [[ -z "$expected" ]]; then
  echo "build_gopenpgp: no checksum recorded for Xcode $xcode_build in scripts/gopenpgp.lock" >&2
  [[ "$MODE" == "--strict" ]] && exit 1
elif [[ "$expected" != "$sum" ]]; then
  echo "build_gopenpgp: CHECKSUM MISMATCH for Xcode $xcode_build: expected $expected, got $sum" >&2
  exit 1
else
  echo "build_gopenpgp: checksum matches scripts/gopenpgp.lock"
fi
