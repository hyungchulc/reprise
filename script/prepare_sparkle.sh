#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=2.10.0
SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
ARCHIVE="$ROOT/.build/Sparkle-$VERSION.tar.xz"
mkdir -p "$ROOT/.build/sparkle-tools"
if [[ ! -f "$ARCHIVE" ]]; then
  TEMP="$(mktemp "$ROOT/.build/sparkle-download.XXXXXX")"
  trap 'rm -f "$TEMP"' EXIT
  curl --fail --location --retry 2 "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$TEMP"
  ACTUAL="$(shasum -a 256 "$TEMP" | awk '{print $1}')"
  [[ "$ACTUAL" == "$SHA256" ]] || { printf 'Sparkle checksum mismatch.\n' >&2; exit 1; }
  mv "$TEMP" "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$SHA256" ]] || { printf 'Sparkle checksum mismatch.\n' >&2; exit 1; }
tar -xJf "$ARCHIVE" -C "$ROOT/.build/sparkle-tools" bin LICENSE
printf 'Verified Sparkle %s tools: %s\n' "$VERSION" "$ROOT/.build/sparkle-tools/bin"
