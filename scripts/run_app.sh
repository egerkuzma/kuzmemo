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
if [ "$FLAVOR" = prod ] && [ "$ADHOC" = 1 ]; then
  echo "--prod needs a stable signing identity: an ad-hoc build loses the microphone and Input Monitoring grants (--adhoc is for --dist and throwaway dev builds)" >&2
  exit 2
fi

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
# A build number that changes with every commit, so that two builds of the same version can be told apart
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
  # only the ends are trimmed: the name of a certificate may contain spaces
  IDENTITY="$(head -n 1 "$ROOT/signing/identity" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
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
  # A hash is compared whole and without regard to case; a name is compared whole too (a part of a name or a hash would
  # match some other certificate). The listing goes through a variable: `grep -q` closing the pipe early would fail under pipefail.
  listing="$(security find-identity -v -p codesigning)"
  if [[ "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    IDENTITY="$(printf '%s' "$IDENTITY" | tr 'a-f' 'A-F')"
    grep -q "^ *[0-9]*) $IDENTITY " <<<"$listing" || found=no
  else
    grep -qF "\"$IDENTITY\"" <<<"$listing" || found=no
  fi
  [ "${found:-yes}" = yes ] \
    || { echo "signing identity $IDENTITY not found (use --adhoc to sign ad hoc; permissions will reset on every build)" >&2; exit 1; }
else
  IDENTITY="-"
  [ "$FLAVOR" = dist ] || echo "WARNING: ad-hoc signing: the microphone/Input Monitoring grants will not survive a rebuild." >&2
fi

# --- generated assets -------------------------------------------------------------------------------
# Made first: they are quick, and a missing tool or folder shows up now and not after the long build. None of them is
# committed (a fresh clone has none).
# The app's own alert chimes (all of them: a partial set is made again)
python3 "$ROOT/scripts/make_sounds.py" --missing >/dev/null 2>&1 || python3 "$ROOT/scripts/make_sounds.py"
# The app icon is drawn by scripts/make_icon.swift; the automation build gets a grey one
if [ "$FLAVOR" = dev ]; then ICON="AppIconDev.icns"; else ICON="AppIcon.icns"; fi
[ -e "$ROOT/Resources/$ICON" ] || swift "$ROOT/scripts/make_icon.swift"

# --- build ------------------------------------------------------------------------------------------
EXTRA=()
SCRATCH=""
APPDIR="$ROOT/.build/app"
if [ "$FLAVOR" = dist ]; then
  # An own scratch folder (the flags below change every object file), and no path of this machine in what is shipped
  SCRATCH="$ROOT/.build/dist"
  EXTRA=(--scratch-path "$SCRATCH" -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/kuzmemo" -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/kuzmemo")
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

# Alert sounds: the app's own chimes (made above). The macOS system sounds are Apple's and are not copied in: the app
# copies the one in use from the system's folder into the person's ~/Library/Sounds (see SystemSoundLibrary).
cp "$ROOT"/Resources/Sounds/*.wav "$APP/Contents/Resources/"
cp "$ROOT/Resources/$ICON" "$APP/Contents/Resources/AppIcon.icns"
# The licences of what is built in travel with the app (the disk image passes them on)
python3 "$ROOT/scripts/make_notices.py" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt" ${SCRATCH:+--scratch-path "$SCRATCH"}
# The Silero voice runs in a small Python helper (see scripts/install_silero.sh)
cp "$ROOT/Resources/Silero/silero_helper.py" "$APP/Contents/Resources/"
if [ "$FLAVOR" = dist ]; then
  # Nobody who downloads the app has the source folder: the commands the settings pages show point here instead
  mkdir -p "$APP/Contents/Resources/scripts"
  cp "$ROOT/scripts/install_silero.sh" "$ROOT/scripts/install_omnivoice.sh" "$APP/Contents/Resources/scripts/"
fi

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
    <key>CFBundlePackageType</key><string>APPL</string>
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
# The new copy is made and checked beside the installed one, and only then swapped in, the old one kept until the swap
# has worked: a copy that fails half-way (a full disk) must not leave the person without their app. The names do not end in
# ".app", so that nothing takes the half-made copy for an application.
STAGED="$HOME/Applications/.$APP_NAME.installing"
PREVIOUS="$HOME/Applications/.$APP_NAME.previous"
rm -rf "$STAGED" "$PREVIOUS"
cp -R "$APP" "$STAGED"
codesign --verify --deep --strict "$STAGED"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$DEST/Contents/MacOS/Kuzmemo" >/dev/null || break; sleep 0.3; done
pkill -f "$DEST/Contents/MacOS/Kuzmemo" 2>/dev/null || true
if [ -e "$DEST" ]; then mv "$DEST" "$PREVIOUS"; fi
if mv "$STAGED" "$DEST"; then
  rm -rf "$PREVIOUS"
else
  if [ -e "$PREVIOUS" ]; then mv "$PREVIOUS" "$DEST"; fi
  echo "could not put the new app in place; the previous one was put back" >&2
  exit 1
fi
echo "installed: $DEST"
if [ "$LAUNCH" = 1 ]; then open "$DEST"; echo "launched"; fi
