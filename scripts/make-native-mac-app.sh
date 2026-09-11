#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
app_dir="${project_dir}/release/Bose Headphones Control Native.app"

"${script_dir}/build-backend.sh"
mkdir -p "${app_dir}/Contents/MacOS" "${app_dir}/Contents/Resources/backend"
swiftc -parse-as-library \
  "${project_dir}/native-macos/BoseHeadphonesControl.swift" \
  "${project_dir}/native-macos/NativeBackend.swift" \
  -o "${app_dir}/Contents/MacOS/Bose Headphones Control" \
  -framework SwiftUI -framework AppKit
cp -R "${project_dir}/dist/bose-panel/." "${app_dir}/Contents/Resources/backend/"
cp "${project_dir}/assets/icon.icns" "${app_dir}/Contents/Resources/icon.icns"
cat > "${app_dir}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Bose Headphones Control</string>
<key>CFBundleIdentifier</key><string>com.jpita.bose-headphones-control.native</string>
<key>CFBundleName</key><string>Bose Headphones Control</string>
<key>CFBundleDisplayName</key><string>Bose Headphones Control</string>
<key>CFBundleIconFile</key><string>icon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Bose Headphones Control uses Bluetooth to communicate with your paired Bose headphones.</string>
<key>NSLocalNetworkUsageDescription</key><string>Bose Headphones Control talks to its bundled local Bluetooth service on this Mac.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
plutil -lint "${app_dir}/Contents/Info.plist"
echo "Built ${app_dir}"
