#!/usr/bin/env bash
# Archives the iOS app (Release) and exports an App Store .ipa. Requires an
# "Apple Distribution" cert + provisioning (automatic signing handles it with a
# logged-in Xcode account). The upload step needs App Store Connect credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/Monitor-iOS.xcarchive"
EXPORT="$BUILD/ios-export"

rm -rf "$ARCHIVE" "$EXPORT"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"

echo "==> Archiving Monitor (iOS, Release)"
xcodebuild -project "$ROOT/Monitor.xcodeproj" -scheme Monitor \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" archive

echo "==> Exporting App Store .ipa"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions-appStore.plist"

echo "==> IPA in $EXPORT"
echo "    Upload with Transporter.app, or:"
echo "    xcrun altool --upload-app -f \"$EXPORT/VitaMac.ipa\" -t ios \\"
echo "      --apiKey <KEY_ID> --apiIssuer <ISSUER_UUID>"
