#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$project_dir/dist/AlmostReset.app"
if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' 'DMG packaging requires macOS.' >&2
    exit 1
fi
if [[ ! -x "$app_path/Contents/MacOS/AlmostReset" ]]; then
    printf '%s\n' 'Run ./scripts/build-app.sh first.' >&2
    exit 1
fi
codesign --verify --deep --strict "$app_path"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
if [[ ! "$version" =~ ^[0-9A-Za-z._-]+$ ]]; then
    printf '%s\n' 'Invalid bundle version.' >&2
    exit 1
fi
architectures="$(lipo -archs "$app_path/Contents/MacOS/AlmostReset")"
case "$architectures" in
    arm64|x86_64) package_arch="$architectures" ;;
    'x86_64 arm64'|'arm64 x86_64') package_arch=universal ;;
    *) printf 'Unsupported architectures: %s\n' "$architectures" >&2; exit 1 ;;
esac
artifact_name="AlmostReset-$version-macOS-$package_arch.dmg"
staging="$(mktemp -d "$project_dir/dist/.dmg-build.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
mkdir "$staging/content"
ditto "$app_path" "$staging/content/AlmostReset.app"
ln -s /Applications "$staging/content/Applications"
cp "$project_dir/LICENSE" "$staging/content/LICENSE.txt"
cat > "$staging/content/安装说明.txt" <<'INSTALL'
AlmostReset

将 AlmostReset.app 拖入 Applications，然后从应用程序中打开。
更新前请先退出旧版，已有规则会保留。重新打开后需手动启动监听。

需要 macOS 14+、Apple Silicon（arm64 发布包）以及已安装并登录的 Codex CLI。
控制桌面端会话时，请保持 Codex 桌面应用运行。

本发布包采用本地临时签名，尚未经过 Apple Developer ID 签名和公证。
首次打开如被拦截，请先确认来源，再参阅 Apple 官方说明：
https://support.apple.com/zh-cn/102445

项目与使用指南：https://github.com/caopulan/AlmostReset
许可证：MIT（见 LICENSE.txt）
INSTALL
hdiutil create -volname AlmostReset -srcfolder "$staging/content" -format UDZO -fs HFS+ "$staging/$artifact_name"
hdiutil verify "$staging/$artifact_name"
mv -f "$staging/$artifact_name" "$project_dir/dist/$artifact_name"
(cd "$project_dir/dist" && shasum -a 256 "$artifact_name" > "$artifact_name.sha256")
printf 'Built %s\n' "$project_dir/dist/$artifact_name"
