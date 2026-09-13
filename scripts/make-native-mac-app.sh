#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
app_dir="${project_dir}/release/Bose Headphones Control Native.app"
version="$(awk -F'"' '/"version"/ {print $4; exit}' "${project_dir}/package.json")"
signing_identity="${BOSE_CODESIGN_IDENTITY:-}"

if [[ -z "${signing_identity}" ]]; then
  signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)"/\1/p' \
    | head -n 1)"
fi

"${script_dir}/build-backend.sh"
mkdir -p "${app_dir}/Contents/MacOS" "${app_dir}/Contents/Resources/backend"
swiftc -parse-as-library \
  "${project_dir}/native-macos/BoseHeadphonesControl.swift" \
  "${project_dir}/native-macos/NativeBackend.swift" \
  "${project_dir}/native-macos/BackendProcessController.swift" \
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
plutil -replace CFBundleShortVersionString -string "${version}" "${app_dir}/Contents/Info.plist"

if [[ -n "${signing_identity}" ]]; then
  while IFS= read -r -d '' candidate; do
    if file -b "${candidate}" | grep -q '^Mach-O'; then
      codesign --force --timestamp=none --sign "${signing_identity}" "${candidate}"
    fi
  done < <(find "${app_dir}/Contents/Resources/backend" -type f -print0)

  codesign --force --timestamp=none --sign "${signing_identity}" "${app_dir}"
  codesign --verify --deep --strict --verbose=2 "${app_dir}"
  echo "Signed with ${signing_identity}"
else
  echo "No Apple Development identity found; leaving the app ad-hoc signed."
fi

echo "Built ${app_dir}"
