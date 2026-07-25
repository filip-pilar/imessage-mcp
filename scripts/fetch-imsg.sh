#!/bin/sh
set -eu

VERSION="0.13.3"
SHA256="cee7c160323ff0314ddc136002ee773503ca85da696961f5b7cbff4e0a206608"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST="$ROOT/Vendor/imsg"
ARCHIVE="${TMPDIR:-/tmp}/imsg-macos-$VERSION.zip"
URL="https://github.com/openclaw/imsg/releases/download/v$VERSION/imsg-macos.zip"

if [ -x "$DEST/imsg" ] && [ "$("$DEST/imsg" --version)" = "$VERSION" ]; then
  exit 0
fi

mkdir -p "$DEST"
curl -fL "$URL" -o "$ARCHIVE"
ACTUAL=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "imsg archive checksum mismatch" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
unzip -q "$ARCHIVE" -d "$DEST"
rm -f "$DEST/imsg-bridge-helper.dylib"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$DEST/THIRD_PARTY_NOTICES.md"
"$DEST/imsg" --version
