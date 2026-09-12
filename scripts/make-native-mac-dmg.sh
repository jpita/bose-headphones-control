#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
version="$(awk -F'"' '/"version"/ {print $4; exit}' "${project_dir}/package.json")"
app_dir="${project_dir}/release/Bose Headphones Control Native.app"
dmg_path="${project_dir}/release/Bose-Headphones-Control-Native-${version}-arm64.dmg"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/bose-native-dmg.XXXXXX")"
trap 'rm -rf "${staging_dir}"' EXIT

"${script_dir}/make-native-mac-app.sh"
cp -R "${app_dir}" "${staging_dir}/Bose Headphones Control.app"
ln -s /Applications "${staging_dir}/Applications"
hdiutil create \
  -volname "Bose Headphones Control" \
  -srcfolder "${staging_dir}" \
  -format UDZO \
  -ov \
  "${dmg_path}"

echo "Built ${dmg_path}"
