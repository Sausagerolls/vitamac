#!/usr/bin/env bash
# Submits the DMG to Apple's notary service, waits, then staples the ticket to
# the app and the DMG. Requires Apple credentials (you must run this — it needs
# secrets not in the repo).
#
# Easiest setup (once):
#   xcrun notarytool store-credentials monitor-notary \
#     --apple-id you@example.com --team-id J4UJD4Z33J --password <app-specific-password>
# then run:  NOTARY_PROFILE=monitor-notary scripts/notarize.sh
#
# Alternatives instead of NOTARY_PROFILE:
#   App Store Connect API key: NOTARY_KEY=AuthKey_XXX.p8 NOTARY_KEY_ID=XXX NOTARY_ISSUER=uuid
#   Apple ID:                  NOTARY_APPLE_ID=you@example.com NOTARY_TEAM_ID=J4UJD4Z33J NOTARY_PASSWORD=<app-specific>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="${1:-$ROOT/build/MonitorAgent.dmg}"
APP="$ROOT/build/export/VitaMac Agent.app"

[[ -f "$DMG" ]] || { echo "ERROR: $DMG not found — run make-dmg.sh first." >&2; exit 1; }

submit_args=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  submit_args=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY:-}" ]]; then
  submit_args=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
  submit_args=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
else
  echo "ERROR: set NOTARY_PROFILE (or API key / Apple ID env vars) — see header." >&2
  exit 1
fi

echo "==> Submitting $DMG to notary service (waits for result)"
xcrun notarytool submit "$DMG" "${submit_args[@]}" --wait

echo "==> Stapling ticket to app and DMG"
xcrun stapler staple "$APP"
xcrun stapler staple "$DMG"

echo "==> Gatekeeper assessment"
spctl -a -t exec -vv "$APP" || true
echo "==> Notarization complete. Ship $DMG."
