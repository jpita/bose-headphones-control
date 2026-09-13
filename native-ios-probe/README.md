# Bose BLE Probe

Read-only iPhone feasibility probe for discovering the BLE management surface
advertised by Bose headphones. Its optional status test sends BMAP `GET`
requests, but never sends a setter, pairing command, reset, or audio-routing
command.

## Run on the connected iPhone

1. On the iPhone, enable **Settings → Privacy & Security → Developer Mode**.
2. Restart the iPhone and confirm Developer Mode after it boots.
3. Keep the iPhone unlocked and connected to this Mac.
4. Build and install `BoseBLEProbe` from Xcode or with `xcodebuild` and
   `devicectl`.
5. Allow Bluetooth access when prompted.
6. Let the probe auto-connect to a likely Bose advertisement, or tap Connect.
7. Tap **Read Bose status** to request the BMAP version, battery, and current
   listening-mode index without changing them.
8. Use **Copy report** to capture the discovered service and characteristic
   UUIDs. Read buttons only appear for characteristics that advertise read
   support.

The first milestone is finding a writable/notify BLE characteristic that can
carry the existing BMAP frames. The status test uses the encrypted Bose
characteristic and sends only the same BMAP `GET` frames used by the Mac app.
