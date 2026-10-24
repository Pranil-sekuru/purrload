#!/bin/zsh
# Regenerate app/Resources/AppIcon.icns from the kitty (run after changing the kitty's look).
set -euo pipefail
ROOT=${0:A:h:h}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
"$ROOT/scripts/build.sh" >/dev/null
"$ROOT/build/Purrload.app/Contents/MacOS/Purrload" --render-icon "$WORK/icon-1024.png"
SET="$WORK/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$WORK/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/app/Resources/AppIcon.icns"
echo "wrote app/Resources/AppIcon.icns"
