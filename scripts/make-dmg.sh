#!/usr/bin/env bash
# Packages the exported VitaMac Agent.app into a compressed DMG with an
# /Applications drop target.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/export/VitaMac Agent.app"
DMG="$ROOT/build/MonitorAgent.dmg"

[[ -d "$APP" ]] || { echo "ERROR: $APP not found — run build-agent-release.sh first." >&2; exit 1; }

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "VitaMac Agent" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "==> DMG: $DMG"
