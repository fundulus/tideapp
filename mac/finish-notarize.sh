#!/bin/zsh
# Wait on an already-submitted notarization, then staple and package it.
#
# release.sh submits and waits in one process, which means anything that kills that
# process (a closed terminal, an over-eager cleanup) throws away a submission that
# Apple is perfectly happy to finish. The submission lives on Apple's side, so the
# tail of the job can always be re-run separately. That is what this does.
#
#   ./finish-notarize.sh <submission-id> [output-name]
set -e
cd "$(dirname "$0")"

ID="${1:?usage: finish-notarize.sh <submission-id> [output-name]}"
OUT="${2:-FundulusTides-notarized-$(date +%Y%m%d-%H%M).zip}"
PROFILE="tides-notary"
APP="Fundulus Tides.app"
ZIP="FundulusTides.zip"

if [[ ! -d "$APP" ]]; then
  echo "!! $APP is missing. It must be the exact build that was submitted."
  exit 1
fi

# The ticket is issued for a specific code directory hash, so refuse to staple onto
# a build that is not the one Apple looked at.
echo "==> app CDHash: $(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash/{print $2}')"

echo "==> waiting on submission $ID"
while :; do
  STATUS=$(xcrun notarytool info "$ID" --keychain-profile "$PROFILE" 2>&1 | awk -F': ' '/status:/{print $2}')
  [[ -z "$STATUS" ]] && STATUS="(no status returned)"
  echo "    $(date '+%H:%M:%S')  $STATUS"
  case "$STATUS" in
    Accepted) break ;;
    Invalid|Rejected)
      echo "!! notarization failed. Log:"
      xcrun notarytool log "$ID" --keychain-profile "$PROFILE" || true
      exit 1 ;;
  esac
  sleep 60
done

echo "==> stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper, as a stranger's Mac would see it"
spctl -a -vvv -t install "$APP"

echo "==> packaging"
mkdir -p dist
rm -f "dist/$OUT"
ditto -c -k --keepParent "$APP" "dist/$OUT"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> done: mac/dist/$OUT"
