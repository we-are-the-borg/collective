#!/bin/sh
# Renders the template menu bar SVGs into the app's asset catalog as template
# PNGs on a 22 x 18 pt canvas (@1x 22x18, @2x 44x36, @3x 66x54): idle and
# warning. The working and needs-permission states are a colored cube the
# app draws at runtime, not assets. Uses rsvg-convert (brew install librsvg):
# macOS's own SVG renderer rasterizes the masks blurry.
#   sh Design/icons/render-menubar.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
assets="$here/../../App/Collective/Assets.xcassets"

# render <svg basename> <image set name>
render() {
    svg="$here/$1.svg"
    name="$2"
    set="$assets/$name.imageset"
    mkdir -p "$set"
    for scale in 1 2 3; do
        rsvg-convert -w $((22 * scale)) -h $((18 * scale)) -o "$set/$name@${scale}x.png" "$svg"
    done
    cat > "$set/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "$name@1x.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "$name@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "$name@3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
JSON
}

for state in idle warning; do
    render "menubar-$state" "MenuBar$(printf '%s' "$state" | cut -c1 | tr a-z A-Z)$(printf '%s' "$state" | cut -c2-)"
done
