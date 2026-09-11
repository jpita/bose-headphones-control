#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${script_dir}/.." && pwd)"
target_dir="${project_dir}/dist/linux-backend"

rm -rf "${target_dir}"
mkdir -p "${target_dir}"
cp "${project_dir}/server.py" "${target_dir}/server.py"
cp -R "${project_dir}/static" "${target_dir}/static"
cp -R "${project_dir}/vendor" "${target_dir}/vendor"
