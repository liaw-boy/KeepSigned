#!/bin/bash
# Renders design/AppIcon.svg into the AppIcon set (macOS sizes 16–512 @1x/@2x),
# and the menu-bar wax-seal SVGs (from design/menubar.py) into 18pt template images.
set -euo pipefail
cd "$(dirname "$0")/.."
SET="KeepSigned/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sips -s format png design/AppIcon.svg --out "$tmp/1024.png" >/dev/null

entries=()
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((size * scale))
    name="icon_${size}x${size}@${scale}x.png"
    sips -z "$px" "$px" "$tmp/1024.png" --out "$SET/$name" >/dev/null
    entries+=("    { \"idiom\": \"mac\", \"size\": \"${size}x${size}\", \"scale\": \"${scale}x\", \"filename\": \"$name\" }")
  done
done
cat > "$SET/Contents.json" <<JSON
{
  "images": [
$(printf '%s\n' "${entries[@]}" | sed '$!s/$/,/')
  ],
  "info": { "author": "xcode", "version": 1 }
}
JSON
printf '{\n  "info": { "author": "xcode", "version": 1 }\n}\n' > KeepSigned/Assets.xcassets/Contents.json
echo "Wrote $SET"

python3 -I design/menubar.py
for name in MenuBarSeal MenuBarSealWarning; do
  dir="KeepSigned/Assets.xcassets/$name.imageset"
  mkdir -p "$dir"
  sips -s format png "design/$name.svg" --out "$tmp/$name.png" >/dev/null
  for scale in 1 2 3; do
    sips -z $((18 * scale)) $((18 * scale)) "$tmp/$name.png" --out "$dir/$name@${scale}x.png" >/dev/null
  done
  cat > "$dir/Contents.json" <<JSON
{
  "images": [
    { "idiom": "universal", "scale": "1x", "filename": "$name@1x.png" },
    { "idiom": "universal", "scale": "2x", "filename": "$name@2x.png" },
    { "idiom": "universal", "scale": "3x", "filename": "$name@3x.png" }
  ],
  "info": { "author": "xcode", "version": 1 },
  "properties": { "template-rendering-intent": "template" }
}
JSON
  echo "Wrote $dir"
done
