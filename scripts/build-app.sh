#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$project_dir/dist"
app_path="$dist_dir/AlmostReset.app"
icon_source="$project_dir/assets/AppIcon.png"

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' 'AlmostReset requires macOS.' >&2
    exit 1
fi
for tool in swift sips iconutil codesign plutil ditto; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Required tool is missing: %s\n' "$tool" >&2
        exit 1
    fi
done
if [[ ! -f "$icon_source" ]]; then
    printf 'App icon is missing: %s\n' "$icon_source" >&2
    exit 1
fi

cd "$project_dir"
swift build --configuration release --product AlmostReset
build_dir="$(swift build --configuration release --show-bin-path)"
mkdir -p "$dist_dir"
staging_dir="$(mktemp -d "$dist_dir/.almostreset-build.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT
staged_app="$staging_dir/AlmostReset.app"
contents_dir="$staged_app/Contents"
iconset_dir="$staging_dir/AppIcon.iconset"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$iconset_dir"
cp "$build_dir/AlmostReset" "$contents_dir/MacOS/AlmostReset"
chmod 755 "$contents_dir/MacOS/AlmostReset"

# Resize copies only; keep the imagegen source at its original resolution.
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$icon_source" \
        --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -s format png -z "$retina_size" "$retina_size" "$icon_source" \
        --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns --output "$contents_dir/Resources/AppIcon.icns" "$iconset_dir"

# Preserve any resources added to the Swift package in future revisions.
for resource_bundle in "$build_dir"/*.bundle; do
    [[ -d "$resource_bundle" ]] || continue
    ditto "$resource_bundle" "$contents_dir/Resources/$(basename "$resource_bundle")"
done

cat > "$contents_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
    <key>CFBundleDisplayName</key><string>AlmostReset</string>
    <key>CFBundleExecutable</key><string>AlmostReset</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.caopulan.AlmostReset</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>AlmostReset</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.7.5</string>
    <key>CFBundleVersion</key><string>12</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$contents_dir/Info.plist"
codesign --force --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"

# Replace only this script's generated build output, after a successful build.
if [[ -L "$app_path" ]]; then
    printf 'Refusing to replace a symlink: %s\n' "$app_path" >&2
    exit 1
fi
if [[ -e "$app_path" && ! -d "$app_path" ]]; then
    printf 'Build destination is not an app directory: %s\n' "$app_path" >&2
    exit 1
fi
if [[ -d "$app_path" ]]; then
    rm -rf -- "$app_path"
fi
mv "$staged_app" "$app_path"
printf 'Built %s\n' "$app_path"
printf '%s\n' 'This local build is ad-hoc signed; it is not notarized.'
