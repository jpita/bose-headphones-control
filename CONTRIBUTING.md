# Contributing

Thanks for helping improve Bose Headphones Control.

## Set up the project

```sh
git clone https://github.com/jpita/bose-headphones-control.git
cd bose-headphones-control
python3 -m venv .venv
.venv/bin/pip install -r requirements-build.txt
npm install
npm test
```

The full test suite runs on macOS because the native app and macOS Bluetooth transport require Apple frameworks.

## Make a change

1. Open an issue for larger changes or support for a new headphone model.
2. Keep Bluetooth protocol changes separate from UI changes where practical.
3. Add or update tests using a fake connection; automated tests must never require a real headset.
4. Run `npm test` before opening a pull request.
5. Describe the headphone model, firmware, operating system, and manual test performed when Bluetooth behavior changes.

Do not commit device identifiers, Bluetooth addresses, account data, proprietary firmware, build directories, or packaged applications.

## Upstream protocol work

The vendored `pybmap` code originates from [bosectl](https://github.com/aaronsb/bosectl). Preserve its license and attribution when changing or updating the vendored library.
