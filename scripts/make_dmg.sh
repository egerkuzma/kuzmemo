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
# Before the image is made everything that goes into it is searched for what must not be shipped: the name of the
# account that built it, home-folder paths, the signing certificate, and every pattern listed in the git-ignored file
# signing/leak-patterns (one extended regular expression per line, "#" starts a comment: names of other projects, clients or
# people that must not travel; they are kept out of the repository on purpose). The script stops if it finds one, and
# also when a search could not be completed (an unreadable file is not "nothing found").
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
[ -x "$APP/Contents/Resources/scripts/install_silero.sh" ] && [ -x "$APP/Contents/Resources/scripts/install_omnivoice.sh" ] || { echo "FAIL: the install scripts are missing or not executable"; fail=1; }
[ -s "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt" ] || { echo "FAIL: the licence notice of the built-in packages is missing"; fail=1; }

# What goes into the image is put together first and searched as a whole (the app and the files next to it)
STAGE="$ROOT/.build/dmg-stage"
OUT="$ROOT/.build/Kuzmemo-$VERSION-arm64.dmg"
rm -rf "$STAGE" "$OUT" "$OUT.sha256"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/scripts/dmg/HOW-TO-OPEN.txt" "$ROOT/LICENSE" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt" "$STAGE/"

# scan WHAT GREP-ARGUMENTS...: lists the files under the stage that match; a search that could not be carried out is a failure
# too, never "nothing found" (grep says 1 for no match and 2 for an error)
scan() {
  local what="$1" out status=0
  shift
  out="$(grep -r -a -l "$@" "$STAGE" 2>&1)" || status=$?
  case "$status" in
    0) echo "FAIL: $what inside:"; echo "$out"; fail=1 ;;
    1) ;;
    *) echo "FAIL: the search for $what could not be completed:"; echo "$out"; fail=1 ;;
  esac
}
ME="$(id -un)"
scan "personal paths" -E -- "/Users/[A-Za-z0-9._-]+/(Projects|Library|Applications|Documents)|/private/var/folders"
scan "the account name '$ME'" -F -i -- "$ME"
if [ -f "$ROOT/signing/leak-patterns" ]; then
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    case "$pattern" in ""|"#"*) continue ;; esac
    scan "a pattern from signing/leak-patterns" -E -i -- "$pattern"
  done < "$ROOT/signing/leak-patterns"
fi
[ "$fail" = 0 ] || { echo "the bundle is not fit to ship"; rm -rf "$STAGE"; exit 1; }
echo "ok: arm64, ad hoc, no personal paths, version $VERSION"

echo "== making the image"
hdiutil create -volname "Kuzmemo $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
( cd "$ROOT/.build" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
rm -rf "$STAGE"
echo "== done: $OUT ($(du -h "$OUT" | cut -f1))"
cat "$OUT.sha256"
