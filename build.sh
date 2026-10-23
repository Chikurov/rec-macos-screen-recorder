#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"

INSTALL_DIR="/Applications"
APP="build/Rec.app"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

IDENTITY="${REC_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    for candidate in "Rec Local Signing" "ScrollSnap Local Signing"; do
        if security find-certificate -c "$candidate" >/dev/null 2>&1; then
            IDENTITY="$candidate"
            break
        fi
    done
fi
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="-"
    echo "Сертификат не найден, подпись ad-hoc. macOS будет заново спрашивать разрешения после каждой пересборки."
    echo "Чтобы этого избежать: scripts/create-signing-cert.sh"
fi

BUILD_NUMBER=$(( $(cat BUILD_NUMBER 2>/dev/null || echo 0) + 1 ))

echo "Сборка $BUILD_NUMBER…"
mkdir -p build
if ! swift build -c release --arch arm64 --arch x86_64 > build.log 2>&1; then
    grep -E 'error:' build.log | sort -u
    echo "Сборка не удалась, полный лог: build.log"
    exit 1
fi
echo "$BUILD_NUMBER" > BUILD_NUMBER

[[ -f Support/AppIcon.icns ]] || scripts/make-icon.sh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/Rec "$APP/Contents/MacOS/Rec"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

echo "Подпись…"
codesign --force --options runtime --timestamp=none \
    --entitlements Support/Rec.entitlements \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "Установка в $INSTALL_DIR…"
pkill -x Rec 2>/dev/null || true
rm -rf "$INSTALL_DIR/Rec.app"
ditto "$APP" "$INSTALL_DIR/Rec.app"
echo "Готово: $INSTALL_DIR/Rec.app"

if [[ "${1:-}" == "--dmg" ]]; then
    scripts/make-dmg.sh
fi
