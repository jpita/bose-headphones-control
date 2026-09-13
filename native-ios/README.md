# Bose Headphones Control for iPhone

Native SwiftUI controller using Bose BMAP directly over encrypted Bluetooth LE.
It connects to the BLE side of headphones already paired for audio, so it does
not require Bose Music's second setup flow and does not replace the audio bond.

## Included controls

- Battery, firmware, and current listening mode
- Listening-mode activation and spoken-mode toggle
- Noise cancellation level and wind block
- Three-band equalizer and presets
- Editable listening-mode slots
- Device name, voice prompts, auto-pause, auto-answer, and sidetone where supported
- Pairing-mode and power-off actions behind confirmation dialogs

The original feasibility probe remains in `native-ios-probe/`.

## Build for the connected iPhone

```bash
xcodebuild -project native-ios/BoseHeadphonesControl.xcodeproj \
  -scheme BoseHeadphonesControl -configuration Debug \
  -destination 'id=<YOUR_IPHONE_UDID>' \
  -derivedDataPath /tmp/BoseHeadphonesControl-iPhone \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```
