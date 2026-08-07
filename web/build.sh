#!/bin/zsh
# Assembles ../docs/, which is what GitHub Pages serves.
#
# Same pattern as the macOS and iOS builds: ../index.html is the single source and is
# copied in at build time, so the published site can never drift from the app the
# native shells bundle. Nothing in docs/ should be edited by hand.
#
#   ./build.sh          assemble docs/
#   ./build.sh serve    assemble, then serve it locally for testing
set -e
cd "$(dirname "$0")"

OUT="../docs"
WEB="../index.html"

[[ -f "$WEB" ]] || { echo "error: $WEB not found"; exit 1; }

echo "==> cleaning $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/icons"

echo "==> copying app and PWA assets"
cp "$WEB" "$OUT/index.html"
cp manifest.webmanifest "$OUT/"
cp sw.js "$OUT/"
cp icons/*.png "$OUT/icons/"

# Tells GitHub Pages not to run the files through Jekyll, which would otherwise
# ignore anything it considers a special filename.
touch "$OUT/.nojekyll"

# Bump the service worker cache version on every build so returning visitors pick up
# the new shell instead of being pinned to the cached one.
STAMP=$(date +%Y%m%d%H%M%S)
sed -i '' "s/const CACHE_VERSION = \".*\"/const CACHE_VERSION = \"tides-$STAMP\"/" "$OUT/sw.js"
echo "==> service worker cache version: tides-$STAMP"

echo "==> built $OUT ($(du -sh "$OUT" | cut -f1))"
ls -1 "$OUT" | sed 's/^/   /'

if [[ "$1" == "serve" ]]; then
  PORT=8888
  echo
  echo "==> serving http://localhost:$PORT  (ctrl-C to stop)"
  cd "$OUT" && python3 -m http.server $PORT
fi
