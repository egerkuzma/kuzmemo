#!/usr/bin/env bash
# Builds Kuzmemo (release), assembles the .app, signs it with a stable certificate (never ad hoc: the microphone
# and Input Monitoring grants are bound to the signing certificate), installs it to ~/Applications and
# launches that copy.
#
#   scripts/run_app.sh [--prod|--dist] [--no-launch] [--adhoc] [--force]
#
# Two bundles, each with its own data folder:
#   default  app.kuzmemo.dev  "Kuzmemo Dev"  Kuzmemo-Dev  the automation build for scripts/e2e: control socket on,
#                                            muted, ignores Fn and the chord, never opens the real microphone
#   --prod   app.kuzmemo      "Kuzmemo"      Kuzmemo      the daily app for the person, no control socket
#   --dist   app.kuzmemo      "Kuzmemo"                   a build to give to other people (scripts/make_dmg.sh): signed ad hoc, built in its
#                                                        own scratch folder with the paths of this machine mapped away and the symbols
#                                                        stripped, the install scripts inside, nothing installed or launched
# KUZMEMO_VERSION overrides the version string of the bundle (VERSION is the default).
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
    --dist) FLAVOR=dist ;;
    --force) FORCE=1 ;;
    --no-launch) LAUNCH=0 ;;
    --adhoc) ADHOC=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ "$FLAVOR" = dist ]; then LAUNCH=0; ADHOC=1; fi

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
VERSION="${KUZMEMO_VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)}"
# A build number that changes with every commit: system caches (the icon in notifications, for one) are keyed by it
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
GIT_HASH="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# --- signing identity -------------------------------------------------------------------------------
# Sign with a stable code-signing identity, never ad hoc: the microphone and Input Monitoring grants are bound to the
# signing certificate, so an ad-hoc build loses them on every rebuild. The identity (a certificate name or SHA-1 hash)
# comes from $KUZMEMO_SIGN_IDENTITY, else from the first line of the git-ignored file signing/identity, else it is
# the only code-signing identity in the keychain. To make one: Keychain Access > Certificate Assistant > Create a
# Certificate (Identity Type: Self Signed Root, Certificate Type: Code Signing). If a certificate is listed twice,
# select it by hash.
IDENTITY="${KUZMEMO_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f "$ROOT/signing/identity" ]; then
  IDENTITY="$(head -n 1 "$ROOT/signing/identity" | tr -d '[:space:]')"
fi
if [ "$ADHOC" = 0 ]; then
  if [ -z "$IDENTITY" ]; then
    available="$(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) .*/\1/p' | sort -u)"
    case "$(printf '%s\n' "$available" | grep -c .)" in
      1) IDENTITY="$available" ;;
      0) echo "no code-signing identity found: create one (see the comment above) or use --adhoc" >&2; exit 1 ;;
      *) echo "several code-signing identities found: set KUZMEMO_SIGN_IDENTITY or put one in signing/identity" >&2; exit 1 ;;
    esac
  fi
  security find-identity -v -p codesigning | grep -q "$IDENTITY" \
    || { echo "signing identity $IDENTITY not found (use --adhoc to sign ad hoc; permissions will reset on every build)" >&2; exit 1; }
else
  IDENTITY="-"
  [ "$FLAVOR" = dist ] || echo "WARNING: ad-hoc signing: the microphone/Input Monitoring grants will not survive a rebuild." >&2
fi

# --- build ------------------------------------------------------------------------------------------
EXTRA=()
APPDIR="$ROOT/.build/app"
if [ "$FLAVOR" = dist ]; then
  # An own scratch folder (the flags below change every object file), and no path of this machine in what is shipped
  EXTRA=(--scratch-path "$ROOT/.build/dist" -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/kuzmemo" -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/kuzmemo")
  APPDIR="$ROOT/.build/dist-app"
fi
swift build -c release --product Kuzmemo ${EXTRA[@]+"${EXTRA[@]}"}
BINDIR="$(swift build -c release --show-bin-path ${EXTRA[@]+"${EXTRA[@]}"})"
BIN="$BINDIR/Kuzmemo"

APP="$APPDIR/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kuzmemo"
[ "$FLAVOR" = dist ] && strip -S -x "$APP/Contents/MacOS/Kuzmemo"
# SwiftPM resource bundles (for example from dependencies) must live next to the resources
for b in "$BINDIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

# Alert sounds: the app's own chimes, and copies of the macOS system sounds (the notification system finds a sound
# by its file name inside the app bundle).
[ -e "$ROOT/Resources/Sounds/Kuzmemo-bell.wav" ] || python3 "$ROOT/scripts/make_sounds.py" # generated, not committed
cp "$ROOT"/Resources/Sounds/*.wav "$APP/Contents/Resources/"
# The app icon is drawn by scripts/make_icon.swift (generated, not committed); the automation build gets a grey one
{ [ -e "$ROOT/Resources/AppIcon.icns" ] && [ -e "$ROOT/Resources/AppIcon.icon/icon.json" ]; } || swift "$ROOT/scripts/make_icon.swift"
if [ "$FLAVOR" = dev ]; then ICON="AppIconDev.icns"; else ICON="AppIcon.icns"; fi
cp "$ROOT/Resources/$ICON" "$APP/Contents/Resources/AppIcon.icns"
# The icon in the layered format of macOS 26 as well, compiled into Assets.car (CFBundleIconName names it). A notification
# banner takes its icon from there: with only an .icns file the banner showed a blank white square. The layered document
# (Resources/AppIcon.icon) is drawn by scripts/make_icon.swift; if Xcode's actool cannot compile it, the same pictures go
# in as a plain asset catalog, and failing that the build carries on with the .icns alone.
ICON_DOC="$ROOT/Resources/${ICON%.icns}.icon"
ASSETS="$APPDIR/icon-assets"
rm -rf "$ASSETS"
mkdir -p "$ASSETS/out"
ICON_NAME_ENTRY=""
compile_icon() { xcrun actool "$1" --compile "$ASSETS/out" --platform macosx --minimum-deployment-target 26.0 \
                   --app-icon AppIcon --output-partial-info-plist "$ASSETS/out/partial.plist" >/dev/null 2>&1 && [ -s "$ASSETS/out/Assets.car" ]; }
if [ -d "$ICON_DOC" ] && compile_icon "$ICON_DOC"; then
  :
else
  mkdir -p "$ASSETS/Assets.xcassets/AppIcon.appiconset"
  iconutil -c iconset "$ROOT/Resources/$ICON" -o "$ASSETS/AppIcon.iconset"
  cp "$ASSETS"/AppIcon.iconset/*.png "$ASSETS/Assets.xcassets/AppIcon.appiconset/"
  python3 - "$ASSETS/Assets.xcassets" <<'PY'
import json, sys
root = sys.argv[1]
images = [{"filename": "icon_%dx%d%s.png" % (s, s, "@2x" if k == 2 else ""), "idiom": "mac", "scale": "%dx" % k, "size": "%dx%d" % (s, s)}
          for s in (16, 32, 128, 256, 512) for k in (1, 2)]
json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, open(root + "/AppIcon.appiconset/Contents.json", "w"), indent=2)
json.dump({"info": {"author": "xcode", "version": 1}}, open(root + "/Contents.json", "w"))
PY
  compile_icon "$ASSETS/Assets.xcassets" || rm -f "$ASSETS/out/Assets.car"
fi
if [ -s "$ASSETS/out/Assets.car" ]; then
  cp "$ASSETS/out/Assets.car" "$APP/Contents/Resources/Assets.car"
  ICON_NAME_ENTRY="    <key>CFBundleIconName</key><string>AppIcon</string>
"
else
  echo "note: the layered icon could not be compiled (Xcode's actool is needed); notifications may show a blank icon" >&2
fi
# The Silero voice runs in a small Python helper (see scripts/install_silero.sh)
cp "$ROOT/Resources/Silero/silero_helper.py" "$APP/Contents/Resources/"
if [ "$FLAVOR" = dist ]; then
  # Nobody who downloads the app has the source folder: the commands the settings pages show point here instead
  mkdir -p "$APP/Contents/Resources/scripts"
  cp "$ROOT/scripts/install_silero.sh" "$ROOT/scripts/install_omnivoice.sh" "$APP/Contents/Resources/scripts/"
fi
for f in /System/Library/Sounds/*.aiff; do cp "$f" "$APP/Contents/Resources/System-$(basename "$f")"; done

SOURCE_ROOT_ENTRY="    <key>KuzmemoSourceRoot</key><string>$ROOT</string>
"
[ "$FLAVOR" = dist ] && SOURCE_ROOT_ENTRY=""
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>Kuzmemo</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
$ICON_NAME_ENTRY    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSMicrophoneUsageDescription</key><string>Kuzmemo records your speech to turn it into calendar entries. The audio is processed on this Mac and deleted as soon as it has been recognized.</string>
    <key>KuzmemoControlEnabled</key><$CONTROL/>
    <key>KuzmemoAutomation</key><$AUTOMATION/>
    <key>KuzmemoGitCommit</key><string>$GIT_HASH</string>
$SOURCE_ROOT_ENTRY</dict>
</plist>
PLIST

# The system permission prompt follows the language of macOS, so the usage text is translated here.
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/ru.lproj"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STR'
"NSMicrophoneUsageDescription" = "Kuzmemo records your speech to turn it into calendar entries. The audio is processed on this Mac and deleted as soon as it has been recognized.";
STR
cat > "$APP/Contents/Resources/ru.lproj/InfoPlist.strings" <<'STR'
"NSMicrophoneUsageDescription" = "Kuzmemo записывает твою речь, чтобы превратить её в записи календаря. Звук обрабатывается на этом Mac и удаляется сразу после расшифровки.";
STR

cat > "$APPDIR/Kuzmemo.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENT

codesign --force --sign "$IDENTITY" --entitlements "$APPDIR/Kuzmemo.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "signed: $(codesign -dr - "$APP" 2>&1 | grep -i designated | sed 's/^# //')"

if [ "$FLAVOR" = dist ]; then echo "built: $APP"; exit 0; fi

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
