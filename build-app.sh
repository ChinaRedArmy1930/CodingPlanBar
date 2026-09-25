#!/bin/bash
# 编译并打包 CodingPlanBar.app
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift build (release)"
swift build -c release
BIN=".build/release/CodingPlanBar"

APP="build/CodingPlanBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/CodingPlanBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 图标（首次生成后缓存到 Resources/AppIcon.icns）
if [ ! -f Resources/AppIcon.icns ]; then
    if [ -x /usr/bin/iconutil ]; then
        echo "==> generating app icon"
        rm -rf /tmp/CodingPlanBar.iconset
        swift Scripts/make-icon.swift /tmp/CodingPlanBar.iconset
        iconutil -c icns /tmp/CodingPlanBar.iconset -o Resources/AppIcon.icns
        rm -rf /tmp/CodingPlanBar.iconset
    fi
fi
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> built: $APP"
