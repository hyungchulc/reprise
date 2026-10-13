#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
MODE="${1:-run}"
case "$MODE" in run|--verify|--install|--build|--debug|--logs|--telemetry) ;; *) printf 'Unknown mode: %s\n' "$MODE" >&2; exit 2 ;; esac
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/Reprise"
STAGE="$(mktemp -d "$ROOT/.build/reprise-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Reprise.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Reprise"
cp "$BIN_DIR/RepriseMCP" "$APP/Contents/MacOS/RepriseMCP"
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
/usr/bin/ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
/usr/bin/install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Reprise"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
BUILD="${REPRISE_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
if [[ -f "$APP/Contents/Resources/apply-update.sh" ]]; then rm "$APP/Contents/Resources/apply-update.sh"; fi
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
/usr/bin/ditto "$ROOT/Resources/Licenses" "$APP/Contents/Resources/Licenses"
cp "$ROOT/Resources/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"
ICONSET="$ROOT/.build/Reprise.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  /usr/bin/sips -z "$doubled" "$doubled" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${REPRISE_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Apple Development:/{print $2; exit}')"
fi
if [[ -z "$IDENTITY" ]]; then
  if [[ "${REPRISE_ALLOW_ADHOC:-0}" != "1" ]]; then
    printf 'A stable signing identity is required. Refusing to replace a permission-bearing app with an ad-hoc build.\n' >&2
    exit 1
  fi
  IDENTITY="-"
  printf 'Explicit ad-hoc build: macOS permissions will not survive rebuilding.\n' >&2
fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
SIGN_OPTIONS=(--options runtime)
if [[ "$IDENTITY" == "-" ]]; then SIGN_OPTIONS=(--options 0); fi
for item in "$FRAMEWORK/XPCServices/Downloader.xpc" "$FRAMEWORK/XPCServices/Installer.xpc" "$FRAMEWORK/Updater.app" "$FRAMEWORK/Autoupdate"; do
  /usr/bin/codesign --force "${SIGN_OPTIONS[@]}" --sign "$IDENTITY" "$item"
done
/usr/bin/codesign --force "${SIGN_OPTIONS[@]}" --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
/usr/bin/codesign --force "${SIGN_OPTIONS[@]}" --sign "$IDENTITY" "$APP/Contents/MacOS/RepriseMCP"
/usr/bin/codesign --force "${SIGN_OPTIONS[@]}" --entitlements "$ROOT/Resources/Reprise.entitlements" --sign "$IDENTITY" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/Reprise" --check-package
mkdir -p "$ROOT/dist"
if [[ -e "$ROOT/dist/Reprise.app" ]]; then
  mv "$ROOT/dist/Reprise.app" "$STAGE/previous.app"
fi
if ! mv "$APP" "$ROOT/dist/Reprise.app"; then
  if [[ -e "$STAGE/previous.app" ]]; then mv "$STAGE/previous.app" "$ROOT/dist/Reprise.app"; fi
  exit 1
fi
APP="$ROOT/dist/Reprise.app"
case "$MODE" in
  --build) printf '%s\n' "$APP" ;;
  --install)
    if /usr/bin/pgrep -x Reprise >/dev/null; then printf 'Quit Reprise before installing to preserve active recordings.\n' >&2; exit 1; fi
    DEST="$HOME/Applications/Reprise.app"
    mkdir -p "$HOME/Applications"
    /usr/bin/ditto "$APP" "$DEST"
    /usr/bin/codesign --verify --strict "$DEST"
    printf '%s\n' "$DEST"
    /usr/bin/open "$DEST" ;;
  --debug) /usr/bin/open -n "$APP"; /usr/bin/lldb -n Reprise ;;
  --logs|--telemetry) /usr/bin/open -n "$APP"; /usr/bin/log stream --info --style compact --predicate 'process == "Reprise"' ;;
  --verify) /usr/bin/open -n "$APP"; sleep 2; /usr/bin/pgrep -x Reprise ;;
  run) /usr/bin/open -n "$APP" ;;
esac
