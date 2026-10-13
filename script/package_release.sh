#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Reprise.app"
REPOSITORY="${REPRISE_GITHUB_REPOSITORY:-hyungchulc/reprise}"
ACCOUNT="${REPRISE_SPARKLE_ACCOUNT:-reprise-updates}"
TOOLS="$ROOT/.build/sparkle-tools/bin"
[[ -x "$TOOLS/generate_appcast" ]] || { printf 'Run script/prepare_sparkle.sh first.\n' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$APP"
SIGNATURE="$(/usr/bin/codesign -dv --verbose=2 "$APP" 2>&1)"
[[ "$SIGNATURE" == *"Authority=Apple Development:"* || "$SIGNATURE" == *"Authority=Developer ID Application:"* ]] || {
  printf 'Public releases require an Apple signing identity, not ad-hoc signing.\n' >&2; exit 1;
}
if [[ "$SIGNATURE" == *"Authority=Apple Development:"* ]]; then
  [[ "${REPRISE_ALLOW_DEVELOPMENT_RELEASE:-0}" == "1" ]] || {
    printf 'Development signing is not Gatekeeper approval. For an explicitly unnotarized alpha, set REPRISE_ALLOW_DEVELOPMENT_RELEASE=1 and disclose the installation limitation.\n' >&2
    exit 1
  }
  printf 'WARNING: development-signed alpha; macOS can reject downloaded installation. No notarization or Gatekeeper acceptance is claimed.\n' >&2
else
  /usr/bin/xcrun stapler validate "$APP"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
fi
"$APP/Contents/MacOS/Reprise" --check-package
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+[-a-zA-Z0-9.]*$ ]] || { printf 'Invalid release version.\n' >&2; exit 1; }
ARCH="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/Reprise")"
case "$ARCH" in arm64|x86_64) ;; *"arm64"*"x86_64"*|*"x86_64"*"arm64"*) ARCH=universal ;; *) printf 'Unsupported architectures.\n' >&2; exit 1 ;; esac
OUTPUT="$ROOT/dist/releases/v$VERSION"
[[ ! -e "$OUTPUT" ]] || { printf 'Release directory already exists; keep published artifacts immutable: %s\n' "$OUTPUT" >&2; exit 1; }
mkdir -p "$OUTPUT"
STAGE="$(mktemp -d "$ROOT/.build/reprise-package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/image" "$STAGE/feed"
/usr/bin/ditto --noextattr --noqtn "$APP" "$STAGE/image/Reprise.app"
/usr/bin/codesign --verify --deep --strict "$STAGE/image/Reprise.app"
ln -s /Applications "$STAGE/image/Applications"
BASE="Reprise-$VERSION-$ARCH"
/usr/bin/ditto -c -k --keepParent --noextattr --norsrc "$STAGE/image/Reprise.app" "$OUTPUT/$BASE.zip"
/usr/bin/hdiutil create -volname Reprise -srcfolder "$STAGE/image" -format UDZO "$OUTPUT/$BASE.dmg"
cp "$OUTPUT/$BASE.zip" "$STAGE/feed/"
if [[ -f "$ROOT/appcast.xml" ]]; then cp "$ROOT/appcast.xml" "$STAGE/feed/appcast.xml"; fi
"$TOOLS/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
  --full-release-notes-url "https://github.com/$REPOSITORY/releases/tag/v$VERSION" \
  --link "https://github.com/$REPOSITORY" "$STAGE/feed"
cp "$STAGE/feed/appcast.xml" "$OUTPUT/appcast.xml"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$OUTPUT/appcast.xml"
(
  cd "$OUTPUT"
  shasum -a 256 "$BASE.zip" "$BASE.dmg" > SHA256SUMS
)
printf 'Release files ready: %s\nPublish assets before promoting appcast.xml. No installed app was changed.\n' "$OUTPUT"
