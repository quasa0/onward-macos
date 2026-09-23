#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-$PWD/dist/Onward.app}"
OUTPUT="$PWD/.runtime/previews"
mkdir -p "$OUTPUT"
render() {
  "$APP/Contents/MacOS/Onward" --render-preview "$OUTPUT/$1.png" "$2" "$3" "$4" "${5:-980x780}"
}
render ready-light now ready light
render focused-light now focused light
render focused-dark now focused dark
render drifting-compact now drifting light 860x690
render settings-light settings ready light 980x1100
render settings-dark settings ready dark 980x1100
render activity-light activity focused light
render activity-empty activity ready dark
render review-light review focused light 1100x2000
render review-compact review focused light 860x1400
render learned-dark learned focused dark 1100x2000
for state in focused drifting distracted; do
  render "hud-$state" hud "$state" light
  render "glow-$state" glow "$state" dark 1440x900
done
printf 'Offscreen previews: %s\n' "$OUTPUT"
