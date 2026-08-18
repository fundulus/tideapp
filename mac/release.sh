#!/bin/zsh
# Signs, notarizes and staples the app so it opens cleanly on other people's Macs.
#
# WHY THIS IS SEPARATE FROM build.sh
# build.sh ad-hoc signs, which is fine on the machine that compiled it and nowhere
# else. To hand the app to someone, macOS wants a "Developer ID Application"
# certificate (paid Apple Developer Program) plus notarization by Apple. An
# "Apple Development" certificate is NOT sufficient: it is for running on your own
# registered devices during development.
#
# ONE-TIME SETUP
#   1. Enrol in the Apple Developer Program, then in Xcode:
#      Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. Store notarization credentials once (uses an app-specific password from
#      appleid.apple.com, NOT your Apple ID password):
#      xcrun notarytool store-credentials "tides-notary" \
#          --apple-id "you@example.com" --team-id "YOURTEAMID"
#
# THEN
#   ./release.sh                 sign + notarize + staple + zip
#   ./release.sh --sign-only     sign only, skip Apple round trip
set -e
cd "$(dirname "$0")"

APP="Fundulus Tides.app"
# No space in what gets sent: the .app carries the display name, the archive around
# it travels through mail and downloads more cleanly without one.
ZIP="FundulusTides.zip"
PROFILE="tides-notary"
SIGN_ONLY=0
[[ "$1" == "--sign-only" ]] && SIGN_ONLY=1

IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')

if [[ -z "$IDENTITY" ]]; then
  echo "No 'Developer ID Application' certificate found in your keychain."
  echo
  echo "You currently have:"
  security find-identity -v -p codesigning | sed 's/^/  /'
  echo
  echo "An 'Apple Development' certificate only covers your own machines. To share"
  echo "the app you need a Developer ID certificate, which requires the paid Apple"
  echo "Developer Program. See the setup notes at the top of this script."
  exit 1
fi
echo "==> identity: $IDENTITY"

echo "==> building fresh"
./build.sh >/dev/null

# Hardened runtime is mandatory for notarization. No extra entitlements are needed:
# WKWebView renders in a system-provided out-of-process WebContent service that
# carries its own, and plain outbound HTTPS needs no entitlement unless sandboxed.
echo "==> signing"
codesign --force --deep --options runtime --timestamp \
         --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/   /'

if [[ $SIGN_ONLY -eq 1 ]]; then
  echo "==> signed only (skipping notarization)"
  exit 0
fi

echo "==> submitting to Apple for notarization (usually 1-5 min)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait; then
  echo
  echo "Notarization failed. To see exactly what Apple objected to:"
  echo "  xcrun notarytool history --keychain-profile $PROFILE"
  echo "  xcrun notarytool log <submission-id> --keychain-profile $PROFILE"
  exit 1
fi

echo "==> stapling the ticket to the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> repackaging the stapled app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "==> done. $ZIP is ready to send."
echo "    Verify it will pass Gatekeeper on someone else's Mac:"
echo "      spctl -a -vvv -t install '$APP'"
