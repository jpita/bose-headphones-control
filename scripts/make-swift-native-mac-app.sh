#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
app_dir="${project_dir}/release/Bose Headphones Control Swift.app"
version="$(awk -F'"' '/"version"/ {print $4; exit}' "${project_dir}/package.json")"
signing_identity="${BOSE_CODESIGN_IDENTITY:-}"

if [[ -z "${signing_identity}" ]]; then
  signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)"/\1/p' \
    | head -n 1)"
fi

if [[ -z "${signing_identity}" ]]; then
  echo "No Apple Development signing identity found; refusing to build an ad-hoc app." >&2
  exit 1
fi

mkdir -p "${app_dir}/Contents/MacOS" "${app_dir}/Contents/Resources"
swiftc -parse-as-library -D SWIFT_BACKEND \
  "${project_dir}/native-macos/BoseHeadphonesControl.swift" \
  "${project_dir}/native-swift-macos/BoseBMAP.swift" \
  "${project_dir}/native-swift-macos/BoseRFCOMMClient.swift" \
  "${project_dir}/native-swift-macos/NativeBackend.swift" \
  -o "${app_dir}/Contents/MacOS/Bose Headphones Control Swift" \
  -framework SwiftUI -framework AppKit -framework IOBluetooth

cp "${project_dir}/assets/icon.icns" "${app_dir}/Contents/Resources/icon.icns"
cat > "${app_dir}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Bose Headphones Control Swift</string>
<key>CFBundleIdentifier</key><string>com.jpita.bose-headphones-control.swift</string>
<key>CFBundleName</key><string>Bose Headphones Control Swift</string>
<key>CFBundleDisplayName</key><string>Bose Headphones Control Swift</string>
<key>CFBundleIconFile</key><string>icon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Bose Headphones Control uses Bluetooth to communicate directly with your paired headphones.</string>
</dict></plist>
PLIST
plutil -lint "${app_dir}/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "${version}" "${app_dir}/Contents/Info.plist"

codesign --force --timestamp=none --sign "${signing_identity}" "${app_dir}"
codesign --verify --deep --strict --verbose=2 "${app_dir}"
echo "Signed with ${signing_identity}"

echo "Built ${app_dir}"
