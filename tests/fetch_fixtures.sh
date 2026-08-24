#!/usr/bin/env bash
# ==============================================================================
# Helper script to download/populate test fixtures for CI and local test runs
# ==============================================================================
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "[*] Resolving and populating test ROM fixtures..."
python3 "$DIR/tests/fetch_rom_jars.py" --fetch all
