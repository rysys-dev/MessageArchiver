#!/bin/bash
# Packages MessageArchiver for friends (Milestone 12): a clean build of the current commit,
# signed with "RYSYS Local Code Signing" (decision 2026-10-18: no Developer ID; friends approve
# it once in System Settings), zipped so the bundle and its signature survive.
#   ./Scripts/release.sh   →  dist/MessageArchiver-<version>-macos.zip
# It refuses to package without the public source link (GPL-3.0, decision Q4) or from a tree
# with uncommitted changes (the build code must name a commit anyone can fetch).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

VERSION="$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/MessageArchiverCore/Version.swift)"
if grep -q 'sourceURL: URL? = nil' Sources/MessageArchiverCore/Version.swift; then
    echo "AppVersion.sourceURL isn't set: the GPL needs the public source link before the app is given to anyone." >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "uncommitted changes: commit first, so the build code names a published commit." >&2
    exit 1
fi

./Scripts/install.sh
APP="${REPO}/build/MessageArchiver.app"
codesign --verify --strict --deep "$APP"

# Nothing from the build machine in what friends get: no home folder, no user name.
for bin in "${APP}/Contents/MacOS/MessageArchiver" "${APP}/Contents/Helpers/ma-engine"; do
    if strings -a "$bin" | grep -qiE "${HOME}|/Users/$(id -un)"; then
        echo "$(basename "$bin") contains this Mac's paths:" >&2
        strings -a "$bin" | grep -iE "${HOME}|/Users/$(id -un)" | sort -u | head -5 >&2
        exit 1
    fi
done

mkdir -p dist
ZIP="${REPO}/dist/MessageArchiver-${VERSION}-macos.zip"
[ -e "$ZIP" ] && /usr/bin/trash "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

BYTES="$(stat -f %z "$ZIP")"
# apps.rysys.net serves files up to 25 MiB.
[ "$BYTES" -lt $((25 * 1024 * 1024)) ] || echo "warning: over 25 MiB, too big for apps.rysys.net" >&2

echo
echo "packaged: ${ZIP} ($(du -h "$ZIP" | cut -f1))"
echo "sha256:   $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "commit:   $(git rev-parse --short HEAD) — tag it: git tag v${VERSION}"
