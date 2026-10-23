#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

swiftc -O -o "$WORKDIR/make-icon" scripts/make-icon.swift
"$WORKDIR/make-icon" "$WORKDIR/icon.png"
ICONSET="$WORKDIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORKDIR/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$WORKDIR/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Support/AppIcon.icns
echo "Готово: Support/AppIcon.icns"
