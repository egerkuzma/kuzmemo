#!/usr/bin/env bash
# Builds Kuzmemo (release), assembles the .app, signs it by certificate SHA-1 (never ad-hoc: the microphone
# and Input Monitoring grants are bound to the signing certificate), installs it to ~/Applications and
# launches that copy.
#
#   scripts/run_app.sh [--prod] [--no-launch] [--adhoc] [--force]
#
# Two bundles, each with its own data folder:
#   default  app.kuzmemo.dev  "Kuzmemo Dev"  Kuzmemo-Dev  the automation build for scripts/e2e: control socket on,
#                                            muted, ignores Fn and the chord, never opens the real microphone
#   --prod   app.kuzmemo      "Kuzmemo"      Kuzmemo      the daily app for the person, no control socket
# Start the dev bundle only when the daily app is not running (the check below stops you; --force overrides).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FLAVOR=dev
LAUNCH=1
ADHOC=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --prod) FLAVOR=prod ;;
    --force) FORCE=1 ;;
    --no-launch) LAUNCH=0 ;;
    --adhoc) ADHOC=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

AUTOMATION=false
case "$FLAVOR" in
  dev) BUNDLE_ID="app.kuzmemo.dev"; APP_NAME="Kuzmemo Dev"; CONTROL=true; AUTOMATION=true ;;
  *)   BUNDLE_ID="app.kuzmemo";     APP_NAME="Kuzmemo";     CONTROL=false ;;
esac

if [ "$FLAVOR" = dev ] && [ "$FORCE" = 0 ] && [ "$LAUNCH" = 1 ] \
   && pgrep -f "$HOME/Applications/Kuzmemo.app/Contents/MacOS/Kuzmemo" >/dev/null; then
  echo "the daily app (Kuzmemo) is running: quit it first (the dev bundle is for scripts) or use --force." >&2
  exit 3
fi
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)"
GIT_HASH="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# --- signing identity -------------------------------------------------------------------------------
# The existing self-signed "Dev Signing" identity is listed twice in the keychain, so select by hash.
IDENTITY="${KUZMEMO_SIGN_IDENTITY:-<certificate SHA-1>}"
if [ "$ADHOC" = 0 ]; then
  security find-identity -v -p codesigning | grep -q "$IDENTITY" \
    || { echo "signing identity $IDENTITY not found (use --adhoc to sign ad hoc; permissions will reset on every build)" >&2; exit 1; }
else
  IDENTITY="-"
  echo "WARNING: ad-hoc signing: the microphone/Input Monitoring grants will not survive a rebuild." >&2
fi

# --- build ------------------------------------------------------------------------------------------
swift build -c release --product Kuzmemo
BIN="$(swift build -c release --show-bin-path)/Kuzmemo"

APP="$ROOT/.build/app/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kuzmemo"
# SwiftPM resource bundles (for example from dependencies) must live next to the resources
for b in "$(swift build -c release --show-bin-path)"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>Kuzmemo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>ru</string>
    <key>CFBundleLocalizations</key><array><string>ru</string><string>en</string></array>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSMicrophoneUsageDescription</key><string>Kuzmemo записывает вашу речь, чтобы превратить её в записи календаря. Звук обрабатывается на этом Mac и удаляется сразу после расшифровки.</string>
    <key>KuzmemoControlEnabled</key><$CONTROL/>
    <key>KuzmemoAutomation</key><$AUTOMATION/>
    <key>KuzmemoGitCommit</key><string>$GIT_HASH</string>
</dict>
</plist>
PLIST

cat > "$ROOT/.build/app/Kuzmemo.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENT

codesign --force --sign "$IDENTITY" --entitlements "$ROOT/.build/app/Kuzmemo.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "signed: $(codesign -dr - "$APP" 2>&1 | grep -i designated | sed 's/^# //')"

# --- install and launch -----------------------------------------------------------------------------
DEST="$HOME/Applications/$APP_NAME.app"
mkdir -p "$HOME/Applications"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$DEST/Contents/MacOS/Kuzmemo" >/dev/null || break; sleep 0.3; done
pkill -f "$DEST/Contents/MacOS/Kuzmemo" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "installed: $DEST"
if [ "$LAUNCH" = 1 ]; then open "$DEST"; echo "launched"; fi
