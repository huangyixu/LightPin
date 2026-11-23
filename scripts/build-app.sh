#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIGNING_CONFIG="$HOME/Library/Application Support/LightPin/Signing/identity.txt"
IDENTITY="${LIGHTPIN_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f "$SIGNING_CONFIG" ]]; then IDENTITY="$(cat "$SIGNING_CONFIG")"; fi
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  echo "固定签名尚未配置。先运行 python3 scripts/setup-signing.py；构建不会再回退到临时签名。" >&2
  exit 1
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build --disable-sandbox --cache-path "$PWD/.build/cache" -c release --arch arm64 -debug-info-format none
APP="${LIGHTPIN_APP_OUTPUT:-$PWD/.build/app/LightPin.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" -c release --arch arm64 -debug-info-format none --show-bin-path)"
cp "$BIN_DIR/LightPin" "$APP/Contents/MacOS/LightPin"
cp Artwork/LightPin.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIconFile</key><string>LightPin.icns</string>
<key>CFBundleExecutable</key><string>LightPin</string>
<key>CFBundleIdentifier</key><string>local.lightpin.app</string>
<key>CFBundleName</key><string>LightPin</string>
<key>CFBundleDisplayName</key><string>LightPin 截图</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.7.3</string>
<key>CFBundleVersion</key><string>27</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>LightPin 仅在你主动截图时捕获屏幕，用于标注和本机文字识别。</string>
</dict></plist>
PLIST
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
