#!/usr/bin/env bash
# Archives Monitor Agent (Release) and exports a Developer ID-signed app,
# ready for notarization. Hardened Runtime is set on the target.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/MonitorAgent.xcarchive"
EXPORT="$BUILD/export"

rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$BUILD"

echo "==> Regenerating Xcode project"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"

echo "==> Archiving MonitorAgent (Release)"
xcodebuild -project "$ROOT/Monitor.xcodeproj" -scheme MonitorAgent \
  -configuration Release -archivePath "$ARCHIVE" archive

echo "==> Exporting Developer ID app"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions-developerID.plist"

APP="$EXPORT/VitaMac Agent.app"
echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|flags=|Identifier=" || true
echo "==> Exported: $APP"
echo "    Next: scripts/make-dmg.sh, then scripts/notarize.sh"
