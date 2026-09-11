Credit: this project builds on the upstream [bosectl](https://github.com/aaronsb/bosectl) project and its `pybmap` library, which reverse-engineered Bose's BMAP protocol.

# BMAP Control Panel

A small local web control panel for compatible Bose headphones.

Change listening modes, noise control, EQ, profile slots, device settings, and more from your browser. The app runs only on your computer and talks to your already-paired headphones over Bluetooth—no Bose account, cloud service, or phone required.

![BMAP Control Panel showing listening mode, noise controls, EQ, profiles, and device settings](docs/panel.png)

## What it can do

- Switch listening modes and control ANC or wind block
- Tune the full three-band equalizer
- Create, edit, activate, and clear supported profile slots
- Rename the headphones and change supported settings such as sidetone and voice prompts
- Show battery, firmware, connection status, and button mapping
- Reconnect after a Bluetooth drop, with every supported write read back from the device for verification
- Send raw BMAP packets for protocol work

![Profile slots, device settings, button mapping, and write verification](docs/advanced-controls.png)

## Install and run

### 1. Get the code

```sh
git clone https://github.com/jpita/bose-web-ui.git
cd bose-web-ui
```

### 2. Create a Python environment

Python 3.10 or newer is recommended.

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

### 3. Pair and connect your headphones

Use your operating system's Bluetooth settings. The headphones must be powered on and connected to the same computer that runs this app.

### 4. Start the panel

```sh
.venv/bin/python server.py
```

Your browser opens at [http://127.0.0.1:8765](http://127.0.0.1:8765). To start without opening a browser:

```sh
.venv/bin/python server.py --no-browser
```

## macOS desktop app (in progress)

The Electron wrapper runs the same panel as a normal macOS window and starts the Bluetooth backend for you.

For local development after completing the Python install above:

```sh
npm install
npm run desktop
```

To produce installable macOS artifacts, install PyInstaller in the virtual environment, then build:

```sh
.venv/bin/pip install -r requirements-build.txt
npm run make:mac
```

The resulting `.dmg` and `.zip` are written under `release/`. The first public build still needs an Apple Developer signing certificate and notarization before it is ready for general distribution.

## Use it

1. Confirm the header shows your headphones as **connected**.
2. Pick a listening mode, adjust EQ, or update a supported setting.
3. Check **Write verification** after an edit. The panel reads the headphones back after each write so it shows what the firmware stored.
4. If status looks wrong after a Bluetooth reconnect, reconnect the headphones in system Bluetooth settings, then select **Reconnect** in the panel.

## Compatibility

The panel uses BMAP over classic Bluetooth RFCOMM. It works only with headphones supported by the vendored upstream `pybmap` device definitions.

| Platform | Status |
| --- | --- |
| macOS | Tested, using IOBluetooth through PyObjC |
| Linux | Supported upstream; requires `bluetoothctl` on `PATH` |
| Windows | Not supported by this project |

This UI was tested with Bose QuietComfort 45 firmware `4.0.4-4360+de6a887`. Device features and writable settings vary by model and firmware; unavailable controls are omitted or shown as read-only.

## Options

| Variable | Default | Purpose |
| --- | --- | --- |
| `BOSE_UI_PORT` | `8765` | Local server port |
| `BOSE_UI_HOST` | `127.0.0.1` | Address to bind; keep this local unless you understand the network implications |
| `BOSE_MAC` | auto-detect | Headphone Bluetooth MAC address |
| `BOSE_DEVICE` | auto-detect | Device config, for example `qc45` |

Example:

```sh
BOSE_DEVICE=qc45 BOSE_MAC=68:F2:1F:XX:XX:XX .venv/bin/python server.py
```

## Upstream and license

The BMAP implementation in [`vendor/pybmap`](vendor/pybmap) originates from [aaronsb/bosectl](https://github.com/aaronsb/bosectl). Its MIT license is retained in [vendor/LICENSE-bosectl](vendor/LICENSE-bosectl).

This project is not affiliated with Bose. Released under the [MIT License](LICENSE).
