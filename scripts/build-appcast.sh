#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app="$project_dir/dist/AlmostReset.app"
tools_dir="$project_dir/.build/artifacts/sparkle/Sparkle/bin"
account=com.caopulan.AlmostReset.updates
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
test "$("$tools_dir/generate_keys" --account "$account" -p)" = "$(cat "$project_dir/updates/public-key.txt")"
archive="$project_dir/dist/AlmostReset-$version-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
signature="$("$tools_dir/sign_update" --account "$account" -p "$archive")"
"$tools_dir/sign_update" --account "$account" --verify "$archive" "$signature"
python3 - "$archive" "$signature" "$version" "$build" "$project_dir/updates/appcast.xml" <<'PY'
import sys
from pathlib import Path
from email.utils import formatdate
import xml.etree.ElementTree as ET
archive,signature,version,build,output=sys.argv[1:]
ns='http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle',ns)
rss=ET.Element('rss',{'version':'2.0'});channel=ET.SubElement(rss,'channel')
ET.SubElement(channel,'title').text='AlmostReset'
ET.SubElement(channel,'link').text='https://github.com/caopulan/AlmostReset/releases'
ET.SubElement(channel,'description').text='AlmostReset 正式版更新'
item=ET.SubElement(channel,'item')
ET.SubElement(item,'title').text=f'AlmostReset {version}'
ET.SubElement(item,'pubDate').text=formatdate(usegmt=True)
ET.SubElement(item,f'{{{ns}}}version').text=build
ET.SubElement(item,f'{{{ns}}}shortVersionString').text=version
ET.SubElement(item,f'{{{ns}}}minimumSystemVersion').text='14.0'
ET.SubElement(item,'description').text=f'AlmostReset {version}：更新详情见 GitHub Releases。'
ET.SubElement(item,'enclosure',{'url':f'https://github.com/caopulan/AlmostReset/releases/download/v{version}/{Path(archive).name}',
 'length':str(Path(archive).stat().st_size),'type':'application/octet-stream',f'{{{ns}}}edSignature':signature})
ET.indent(rss)
ET.ElementTree(rss).write(output,encoding='utf-8',xml_declaration=True)
PY
"$tools_dir/sign_update" --account "$account" "$project_dir/updates/appcast.xml"
"$tools_dir/sign_update" --account "$account" --verify "$project_dir/updates/appcast.xml"
(cd "$project_dir/dist" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
printf 'Signed update archive: %s\n' "$archive"
