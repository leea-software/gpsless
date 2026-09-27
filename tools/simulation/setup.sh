#!/bin/bash
set -euo pipefail
sim_dir="$(cd "$(dirname "$0")" && pwd)"
python3 -m venv "$sim_dir/.venv"
"$sim_dir/.venv/bin/python" -m pip install -r "$sim_dir/requirements.txt"
npm --prefix "$sim_dir/web" ci --ignore-scripts --no-audit --no-fund
"$sim_dir/.venv/bin/python" "$sim_dir/sim.py" build
