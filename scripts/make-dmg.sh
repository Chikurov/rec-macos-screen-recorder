#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

IDENTITY="${REC_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    for candidate in "Rec Local Signing" "ScrollSnap Local Signing"; do
        if security find-certificate -c "$candidate" >/dev/null 2>&1; then
            IDENTITY="$candidate"
            break
        fi
    done
fi
IDENTITY="${IDENTITY:--}"
APP="build/Rec.app"

if [[ ! -d "$APP" ]]; then
    echo "Нет собранного приложения. Сначала запусти: ./build.sh"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
DMG="build/Rec-$VERSION-build$BUILD.dmg"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/Rec.app"
ln -s /Applications "$STAGING/Applications"
cp scripts/dmg-readme.txt "$STAGING/Как установить.txt"

echo "Упаковка…"
rm -f "$DMG"
hdiutil create -quiet -volname "Rec $VERSION ($BUILD)" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$DMG"
codesign --force --timestamp=none --sign "$IDENTITY" "$DMG"

echo "Готово: $PWD/$DMG"
