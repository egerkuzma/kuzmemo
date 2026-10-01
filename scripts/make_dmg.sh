#!/usr/bin/env bash
# Builds the disk image of Kuzmemo that is given to other people (the GitHub release), and checks it before it is
# trusted:
#
#   scripts/make_dmg.sh [version]        (the version defaults to the file VERSION)
#
# The app inside comes from `scripts/run_app.sh --dist`: signed ad hoc (there is no Apple Developer ID: the app is not
# notarized, so macOS asks the person to confirm the first launch; HOW-TO-OPEN.txt in the image explains how), built
# with the paths of this machine mapped away and the symbols stripped, with the install scripts of the optional voices
# inside. Apple silicon only, like the speech models it runs.
#
# Before the image is made the bundle is searched for anything that must not be shipped: the name of the account that
# built it, home-folder paths, the signing certificate. The script stops if it finds one.
#
# Output: .build/Kuzmemo-<version>-arm64.dmg and its .sha256 (git-ignored).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:-$(cat "$ROOT/VERSION")}"

KUZMEMO_VERSION="$VERSION" "$ROOT/scripts/run_app.sh" --dist
APP="$ROOT/.build/dist-app/Kuzmemo.app"

echo "== checking the bundle"
fail=0
[ "$(lipo -archs "$APP/Contents/MacOS/Kuzmemo")" = "arm64" ] || { echo "FAIL: the program is not arm64 only: $(lipo -archs "$APP/Contents/MacOS/Kuzmemo")"; fail=1; }
codesign --verify --deep --strict "$APP" || { echo "FAIL: the signature does not verify"; fail=1; }
SIGNATURE="$(codesign -dv "$APP" 2>&1)" # not piped into grep -q: with pipefail its early exit would look like a failure
case "$SIGNATURE" in *"Signature=adhoc"*) ;; *) echo "FAIL: the app is not signed ad hoc (a personal certificate would travel with it)"; fail=1 ;; esac
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] || { echo "FAIL: the bundle version is not $VERSION"; fail=1; }
/usr/libexec/PlistBuddy -c 'Print :KuzmemoSourceRoot' "$APP/Contents/Info.plist" >/dev/null 2>&1 && { echo "FAIL: the bundle names the source folder of this machine"; fail=1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :KuzmemoControlEnabled' "$APP/Contents/Info.plist")" = "false" ] || { echo "FAIL: the control channel is on"; fail=1; }
# what must not be in any file of the bundle (text or binary): the account name, a home folder, the certificate name
ME="$(id -un)"
leaks="$(grep -r -a -l -E "/Users/$ME|/Users/[A-Za-z0-9._-]+/(Projects|Library|Applications|Documents)|/private/var/folders" "$APP" 2>/dev/null || true)"
if [ -n "$leaks" ]; then echo "FAIL: personal paths or names inside:"; echo "$leaks"; fail=1; fi
named="$(grep -r -a -l -i "$ME" "$APP" 2>/dev/null || true)"
if [ -n "$named" ]; then echo "FAIL: the account name '$ME' is inside:"; echo "$named"; fail=1; fi
[ -x "$APP/Contents/Resources/scripts/install_silero.sh" ] && [ -x "$APP/Contents/Resources/scripts/install_omnivoice.sh" ] || { echo "FAIL: the install scripts are missing or not executable"; fail=1; }
[ "$fail" = 0 ] || { echo "the bundle is not fit to ship"; exit 1; }
echo "ok: arm64, ad hoc, no personal paths, version $VERSION"

echo "== making the image"
STAGE="$ROOT/.build/dmg-stage"
OUT="$ROOT/.build/Kuzmemo-$VERSION-arm64.dmg"
rm -rf "$STAGE" "$OUT" "$OUT.sha256"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/scripts/dmg/HOW-TO-OPEN.txt" "$ROOT/LICENSE" "$STAGE/"
hdiutil create -volname "Kuzmemo $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
( cd "$ROOT/.build" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
rm -rf "$STAGE"
echo "== done: $OUT ($(du -h "$OUT" | cut -f1))"
cat "$OUT.sha256"
