#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_app="$project_dir/dist/AlmostReset.app"
applications_dir="$HOME/Applications"
destination_app="$applications_dir/AlmostReset.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' 'AlmostReset requires macOS.' >&2
    exit 1
fi
if [[ -e "$destination_app" || -L "$destination_app" ]]; then
    printf 'Already installed: %s\n' "$destination_app" >&2
    printf '%s\n' 'Move or rename the existing app yourself before installing a replacement.' >&2
    exit 1
fi
if [[ ! -x "$source_app/Contents/MacOS/AlmostReset" ]]; then
    printf '%s\n' 'Build the app first with ./scripts/build-app.sh.' >&2
    exit 1
fi
codesign --verify --deep --strict "$source_app"
mkdir -p "$applications_dir"
install_staging="$(mktemp -d "$applications_dir/.almostreset-install.XXXXXX")"
trap 'rm -rf -- "$install_staging"' EXIT
ditto "$source_app" "$install_staging/AlmostReset.app"
# -n protects an app installed by another process after the initial check.
mv -n "$install_staging/AlmostReset.app" "$applications_dir/"
if [[ -d "$install_staging/AlmostReset.app" ]]; then
    printf 'Installation stopped because the destination already exists: %s\n' "$destination_app" >&2
    exit 1
fi
printf 'Installed %s\n' "$destination_app"
printf 'Open it with: open "%s"\n' "$destination_app"
