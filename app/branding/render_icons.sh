#!/usr/bin/env bash
# Rasterize the Ply icon SVGs into the Android + iOS launcher sets. Re-run after editing gen_icon.py.
# Deps: rsvg-convert, ImageMagick (magick). Run from the app/ dir or anywhere (paths are relative to
# this script).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(cd "$DIR/.." && pwd)"
BG="#F3EEE3"
python3 "$DIR/gen_icon.py"

ios="$APP/ios/Runner/Assets.xcassets/AppIcon.appiconset"
res="$APP/android/app/src/main/res"

# --- iOS: flatten (no alpha) composed at each required pixel size --------------------------------
declare -A IOS=(
  [Icon-App-20x20@1x.png]=20 [Icon-App-20x20@2x.png]=40 [Icon-App-20x20@3x.png]=60
  [Icon-App-29x29@1x.png]=29 [Icon-App-29x29@2x.png]=58 [Icon-App-29x29@3x.png]=87
  [Icon-App-40x40@1x.png]=40 [Icon-App-40x40@2x.png]=80 [Icon-App-40x40@3x.png]=120
  [Icon-App-60x60@2x.png]=120 [Icon-App-60x60@3x.png]=180
  [Icon-App-76x76@1x.png]=76 [Icon-App-76x76@2x.png]=152
  [Icon-App-83.5x83.5@2x.png]=167 [Icon-App-1024x1024@1x.png]=1024
)
for f in "${!IOS[@]}"; do
  px=${IOS[$f]}
  rsvg-convert -w "$px" -h "$px" "$DIR/composed.svg" -o /tmp/_ply_ios.png
  magick /tmp/_ply_ios.png -background "$BG" -flatten -alpha off "$ios/$f"
done

# --- Android legacy ic_launcher.png (pre-26) -----------------------------------------------------
declare -A LEG=( [mdpi]=48 [hdpi]=72 [xhdpi]=96 [xxhdpi]=144 [xxxhdpi]=192 )
for d in "${!LEG[@]}"; do
  rsvg-convert -w "${LEG[$d]}" -h "${LEG[$d]}" "$DIR/composed.svg" -o "$res/mipmap-$d/ic_launcher.png"
done

# --- Android adaptive foreground (api 26+) -------------------------------------------------------
declare -A FG=( [mdpi]=108 [hdpi]=162 [xhdpi]=216 [xxhdpi]=324 [xxxhdpi]=432 )
for d in "${!FG[@]}"; do
  rsvg-convert -w "${FG[$d]}" -h "${FG[$d]}" "$DIR/foreground.svg" \
    -o "$res/mipmap-$d/ic_launcher_foreground.png"
done

# --- Adaptive icon XML + background color --------------------------------------------------------
mkdir -p "$res/mipmap-anydpi-v26" "$res/values"
cat > "$res/mipmap-anydpi-v26/ic_launcher.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
XML
cat > "$res/values/ic_launcher_background.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#F3EEE3</color>
</resources>
XML

echo "icons written (iOS ${#IOS[@]}, android legacy ${#LEG[@]} + adaptive ${#FG[@]})"
