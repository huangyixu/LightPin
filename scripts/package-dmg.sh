#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "LightPin: $*" >&2; exit 1; }
: "${TEAM_ID:?Set TEAM_ID to the company Apple Developer Team ID}"
: "${BUNDLE_ID:?Set BUNDLE_ID to the permanent company bundle identifier}"
profile="${NOTARY_PROFILE:-LightPin-Notary}"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "Invalid Team ID"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "Invalid bundle ID"

# Match only a valid Developer ID Application identity belonging to this team.
identities=$(security find-identity -v -p codesigning | awk -v team="$TEAM_ID" \
    'index($0,"\"Developer ID Application: ") && index($0,"(" team ")\"") {print $2}')
identity=${SIGNING_SHA1:-$identities}
[[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]] && grep -Fixq "$identity" <<<"$identities" ||
    die "Select one valid Developer ID Application certificate for $TEAM_ID with SIGNING_SHA1"
xcrun notarytool history --keychain-profile "$profile" >/dev/null

mkdir -p dist
stage=$(mktemp -d "$PWD/dist/dmg-release.XXXXXXXX")
# Keep failed jobs and the submission receipt for diagnosis or resumption.
echo "Release workspace: $stage"
archive="$stage/LightPin.xcarchive"
xcodebuild -project LightPin.xcodeproj -scheme LightPin -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" \
    -derivedDataPath "$stage/DerivedData" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGNING_ALLOWED=NO archive
mkdir "$stage/payload"
app="$stage/payload/LightPin.app"
ditto "$archive/Products/Applications/LightPin.app" "$app"
codesign --force --sign "$identity" --timestamp --options runtime \
    --entitlements Store/LightPin.entitlements "$app"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")
name="LightPin-${version}-${build}-arm64.dmg"
[[ ! -e "dist/$name" ]] || die "Release already exists: dist/$name"
ln -s /Applications "$stage/payload/Applications"
dmg="$stage/$name"
hdiutil create -volname LightPin -srcfolder "$stage/payload" -format UDZO "$dmg"
codesign --sign "$identity" --timestamp "$dmg"
receipt="$stage/notary.json"
result=0
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json > "$receipt" || result=$?
status=$(plutil -extract status raw -o - "$receipt" 2>/dev/null || true)
if [[ "$result" != 0 || "$status" != Accepted ]]; then
    submission=$(plutil -extract id raw -o - "$receipt" 2>/dev/null || true)
    if [[ -n "$submission" ]]; then
        xcrun notarytool log "$submission" --keychain-profile "$profile" "$stage/notary-log.json" || true
    fi
    die "Notarization incomplete ($status); inspect $stage"
fi
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
# Both paths are on the same volume; never overwrite an existing final release.
ln "$dmg" "dist/$name"
echo "Ready: $PWD/dist/$name"
