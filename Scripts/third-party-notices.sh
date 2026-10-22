#!/bin/bash
# Writes THIRD-PARTY-NOTICES.txt: every crate compiled into ma-engine, with its license text as
# the crate ships it, plus SQLite and the imessage-exporter CSS the Traditional style builds on.
# Run it after changing the engine's dependencies; install.sh copies the file into the app.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO}/engine"
PATH="/opt/homebrew/opt/rustup/bin:${PATH}" cargo metadata --format-version 1 --locked --filter-platform aarch64-apple-darwin \
    | python3 -I "${REPO}/Scripts/third-party-notices.py" > "${REPO}/THIRD-PARTY-NOTICES.txt"

echo "wrote ${REPO}/THIRD-PARTY-NOTICES.txt"
