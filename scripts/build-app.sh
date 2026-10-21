#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$project_dir/build}"
app_dir="$output_dir/Choice.app"
resource_dir="$app_dir/Contents/Resources"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$resource_dir" "$app_dir/Contents/MacOS" "$work_dir/Choice.iconset"
cp "$project_dir/Assets/Info.plist" "$app_dir/Contents/Info.plist"

source_dir="$project_dir/Sources/Choice"
stage_dir="$source_dir/StageManagerFill"
sdk_dir="$(xcrun --sdk macosx --show-sdk-path)"
for architecture in arm64 x86_64; do
  swiftc -O -target "${architecture}-apple-macos13.0" -sdk "$sdk_dir" \
    "$source_dir"/*.swift "$stage_dir"/*.swift \
    -framework IOBluetooth -framework UserNotifications -framework Carbon -framework ColorSync \
    -o "$work_dir/Choice-$architecture"
done
lipo -create "$work_dir/Choice-arm64" "$work_dir/Choice-x86_64" \
  -output "$app_dir/Contents/MacOS/Choice"

icon_source="$project_dir/Assets/Choice.png"
iconset_dir="$work_dir/Choice.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_source" \
    --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$icon_source" \
    --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
sips -z 1024 1024 "$icon_source" --out "$resource_dir/Choice.png" >/dev/null
iconutil -c icns "$iconset_dir" -o "$resource_dir/Choice.icns"

# Developers can supply a Developer ID identity for their own signed builds.
identity="${CODESIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
  # An ad hoc signature's default requirement is its exact code hash, so macOS drops the
  # Accessibility grant whenever Homebrew rebuilds the app. Requiring only the bundle
  # identifier keeps the grant across upgrades. Any ad hoc app claiming this identifier
  # would also satisfy it; a Developer ID build keeps its stronger default requirement.
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_dir/Contents/Info.plist")"
  codesign --force --sign - -r="designated => identifier \"$bundle_id\"" "$app_dir"
else
  codesign --force --sign "$identity" "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist"
printf 'Built %s\n' "$app_dir"
