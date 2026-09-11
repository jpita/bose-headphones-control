#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
python_bin="${BOSE_UI_PYTHON:-${project_dir}/.venv/bin/python}"

if [[ ! -x "${python_bin}" ]]; then
  echo "Python environment not found: ${python_bin}" >&2
  echo "Create it first: python3 -m venv .venv && .venv/bin/pip install -r requirements-build.txt" >&2
  exit 1
fi

cd "${project_dir}"
"${python_bin}" -m PyInstaller --noconfirm --clean --onedir --name bose-panel \
  --add-data "static:static" \
  --add-data "vendor:vendor" \
  --hidden-import objc \
  --hidden-import Foundation \
  --hidden-import IOBluetooth \
  server.py
