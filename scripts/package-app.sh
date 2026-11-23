#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/.build/app/LightPin.app"
PACKAGE="${LIGHTPIN_PACKAGE_OUTPUT:-$PWD/dist/LightPin.pkg}"
./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/lightpin-package.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$(dirname "$PACKAGE")"
pkgbuild --analyze --root "$PWD/.build/app" "$STAGING/components.plist"
/usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$STAGING/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleOverwriteAction upgrade' "$STAGING/components.plist"
pkgbuild --root "$PWD/.build/app" --component-plist "$STAGING/components.plist" \
  --identifier local.lightpin.installer --version "$VERSION" \
  --install-location /Applications --ownership recommended "$PACKAGE"
printf 'Installer: %s\n' "$PACKAGE"
