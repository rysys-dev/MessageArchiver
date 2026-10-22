#!/bin/bash
# Packages one plug-in (Milestone 17): builds it, signs it with "RYSYS Local Code Signing" (the
# certificate the app pins, PluginTrust.rysysCertificate), and zips it with its plugin.json,
# instructions, license and third-party notices.
#   ./Scripts/release-plugin.sh <folder with plugin.json and instructions.html>
#   →  dist/plugins/<Name>-<version>.maplugin, with its size and SHA-256 for the site's button
# plugin.json names the helper (`executable`) and the Cargo package that builds it
# (`cargo_package`, in the engine/ workspace). Without the certificate it refuses: an ad hoc
# signed plug-in would never install.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$(cd "${1:?usage: release-plugin.sh <plug-in folder>}" && pwd)"
export PATH="/opt/homebrew/opt/rustup/bin:${PATH}"
cd "$REPO"

field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "${SRC}/plugin.json" "$1"; }
ID="$(field id)"; NAME="$(field name)"; VERSION="$(field version)"; EXE="$(field executable)"; PACKAGE="$(field cargo_package)"
[ -f "${SRC}/instructions.html" ] || { echo "no instructions.html in ${SRC}" >&2; exit 1; }

PINNED="$(sed -n 's/.*rysysCertificate = "\(.*\)".*/\1/p' Sources/MessageArchiverCore/Plugins.swift)"
SIGN_ID="$(security find-certificate -c "RYSYS Local Code Signing" -Z 2>/dev/null | awk '/SHA-1/ { print $3; exit }')"
if [ -z "$SIGN_ID" ] || [ "$SIGN_ID" != "$PINNED" ]; then
    echo "the RYSYS Local Code Signing certificate the app pins (${PINNED}) isn't in the login keychain" >&2
    exit 1
fi

# As install.sh builds ma-engine: no path from this Mac in the binary.
(cd engine && MACOSX_DEPLOYMENT_TARGET=27.0 RUSTFLAGS="--remap-path-prefix=${REPO}=. --remap-path-prefix=${HOME}=~" \
    cargo build --release --locked --target aarch64-apple-darwin --quiet -p "$PACKAGE" --bin "$EXE")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="${WORK}/${ID}"
mkdir -p "$STAGE"
cp "engine/target/aarch64-apple-darwin/release/${EXE}" "${STAGE}/${EXE}"
cp "${SRC}/plugin.json" "${SRC}/instructions.html" LICENSE "$STAGE/"
(cd engine && cargo metadata --format-version 1 --locked --filter-platform aarch64-apple-darwin) \
    | MA_PACKAGE="$PACKAGE" python3 -I Scripts/third-party-notices.py > "${STAGE}/THIRD-PARTY-NOTICES.txt"

codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" \
    --identifier "com.rysys.MessageArchiver.plugin.${ID}" "${STAGE}/${EXE}"
codesign --verify --strict -R="certificate leaf = H\"${PINNED}\"" "${STAGE}/${EXE}"

# Nothing from the build machine in what is shared: no home folder, no user name.
if strings -a "${STAGE}/${EXE}" | grep -qiE "${HOME}|/Users/$(id -un)"; then
    echo "${EXE} contains this Mac's paths" >&2
    exit 1
fi

mkdir -p dist/plugins
OUT="${REPO}/dist/plugins/${NAME}-${VERSION}.maplugin"
[ -e "$OUT" ] && /usr/bin/trash "$OUT"
ditto -c -k --keepParent "$STAGE" "$OUT"
echo "plug-in: ${OUT}"
echo "size:    $(stat -f %z "$OUT") bytes"
echo "sha256:  $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
