#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
if [[ $# -ne 1 || ! -f "$1" ]]; then
    printf '%s\n' 'Usage: ./scripts/publish-release.sh path/to/release-notes.md' >&2
    exit 1
fi
notes="$1"
[[ "$(git branch --show-current)" == main ]] || { printf '%s\n' 'Publish from main.' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { printf '%s\n' 'Commit source changes before publishing.' >&2; exit 1; }
./scripts/check.sh
./scripts/build-app.sh
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/AlmostReset.app/Contents/Info.plist)"
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    printf 'Version tag already exists: v%s. Increment the version and build number.\n' "$version" >&2
    exit 1
fi
./scripts/build-dmg.sh
./scripts/build-appcast.sh
git tag -a "v$version" -m "AlmostReset v$version"
git push origin main "v$version"
gh release create "v$version" --verify-tag --title "AlmostReset v$version" --notes-file "$notes" --latest \
    "dist/AlmostReset-$version-macOS-arm64.dmg" "dist/AlmostReset-$version-macOS-arm64.dmg.sha256" \
    "dist/AlmostReset-$version-macOS-arm64.zip" "dist/AlmostReset-$version-macOS-arm64.zip.sha256"
# Publish the signed feed only after its downloadable assets exist.
git add updates/appcast.xml
git commit -m "chore: publish signed update feed for $version"
git push origin main
