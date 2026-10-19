#!/bin/bash
# Builds the release binary and assembles MessageArchiver.app. SwiftPM cannot emit a bundle, so
# we assemble one: a bare executable gets no Dock icon, no menu bar and no window focus.
#
# Stops at the staged copy in build/ unless DEST is given:
#   DEST=/Applications/RYSYS ./Scripts/install.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-build}"
[ "$DEST" = "build" ] && DEST="${REPO}/build"
APP="${DEST}/MessageArchiver.app"
STAGING="${REPO}/build/MessageArchiver.app"
# The Rust engine (Milestone 2): arm64 only, macOS 27 (decision 2026-10-18).
ENGINE="${REPO}/engine/target/aarch64-apple-darwin/release/ma-engine"

cd "$REPO"

VERSION="$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/MessageArchiverCore/Version.swift)"
[ -n "$VERSION" ] || { echo "no version in Version.swift" >&2; exit 1; }
# The build code (decision Q6): the commit this was built from, "-modified" if the tree wasn't
# clean, so a transcript names the exact source that made it.
BUILD_CODE="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ] && BUILD_CODE="${BUILD_CODE}-modified"

# A copy still running from build/ would keep running the old code, and `open` would only bring
# it to the front: quit it first, as its Quit would.
if pgrep -xq MessageArchiver; then
    echo "quitting the running MessageArchiver…"
    osascript -e 'tell application id "com.rysys.MessageArchiver" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do pgrep -xq MessageArchiver || break; sleep 0.5; done
fi

echo "building release v${VERSION} (${BUILD_CODE})…"
# Source paths are compiled into both binaries (assertions, panics): name them relative to the
# repo, so a release doesn't carry the path of the Mac it was built on.
swift build -c release --product MessageArchiverApp \
    -Xswiftc -file-prefix-map -Xswiftc "${REPO}=." -Xswiftc -file-prefix-map -Xswiftc "${HOME}=~"

# Rust from Homebrew's keg-only rustup, by full path: it isn't on the PATH (decision Q5).
echo "building ma-engine…"
(cd engine && PATH="/opt/homebrew/opt/rustup/bin:${PATH}" MACOSX_DEPLOYMENT_TARGET=27.0 \
    RUSTFLAGS="--remap-path-prefix=${REPO}=. --remap-path-prefix=${HOME}=~" \
    cargo build --release --locked --target aarch64-apple-darwin --quiet)

rm -rf "$STAGING"
mkdir -p "${STAGING}/Contents/MacOS" "${STAGING}/Contents/Resources" "${STAGING}/Contents/Helpers"
cp ".build/release/MessageArchiverApp" "${STAGING}/Contents/MacOS/MessageArchiver"
cp "$ENGINE" "${STAGING}/Contents/Helpers/ma-engine"
cp LICENSE "${STAGING}/Contents/Resources/LICENSE"
cp THIRD-PARTY-NOTICES.txt "${STAGING}/Contents/Resources/THIRD-PARTY-NOTICES.txt"
# Conversation styles (decision Q3): Styles/<name>/style.css + page.html.
cp -R Styles "${STAGING}/Contents/Resources/Styles"

# Icon Composer document → Assets.car + AppIcon.icns. actool ships only with Xcode.
if [ -d "Icon/AppIcon.icon" ]; then
    xcrun actool "Icon/AppIcon.icon" --compile "${STAGING}/Contents/Resources" \
        --platform macosx --minimum-deployment-target 27.0 --app-icon AppIcon \
        --output-partial-info-plist "${REPO}/build/icon-partial.plist" \
        --output-format human-readable-text --errors --warnings >/dev/null
fi

cat > "${STAGING}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>MessageArchiver</string>
    <key>CFBundleDisplayName</key>         <string>MessageArchiver</string>
    <key>CFBundleIdentifier</key>          <string>com.rysys.MessageArchiver</string>
    <key>CFBundleExecutable</key>          <string>MessageArchiver</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>${VERSION}</string>
    <key>CFBundleVersion</key>             <string>${VERSION}</string>
    <key>RYSYSBuildCode</key>              <string>${BUILD_CODE}</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundleIconName</key>            <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>      <string>27.0</string>
    <key>LSApplicationCategoryType</key>   <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSHumanReadableCopyright</key>    <string>© 2026 RYSYS · GPL-3.0</string>
    <key>NSContactsUsageDescription</key>  <string>MessageArchiver shows the names of the people in your conversations instead of their phone numbers and email addresses. Contacts are only read, on this Mac.</string>
</dict>
</plist>
PLIST

# Hardened Runtime, signed by "RYSYS Local Code Signing" when that certificate is in the login
# keychain (playbook §6.5), so each build keeps the same identity and its Full Disk Access.
# Ad hoc otherwise. The nested engine is signed first: a bundle whose subcomponent is unsigned
# fails verification. Developer ID + notarisation for other Macs later.
SIGN_ID="$(security find-certificate -c "RYSYS Local Code Signing" -Z 2>/dev/null | awk '/SHA-1/ { print $3; exit }')"
SIGN_ID="${SIGN_ID:--}"
[ "$SIGN_ID" = "-" ] && echo "signing ad hoc (no RYSYS Local Code Signing certificate)" || echo "signing with RYSYS Local Code Signing"
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" \
    --identifier com.rysys.MessageArchiver.engine "${STAGING}/Contents/Helpers/ma-engine"
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" \
    --entitlements "${REPO}/Scripts/MessageArchiver.entitlements" "${STAGING}"
codesign --verify --strict "${STAGING}"

if [ "$DEST" != "${REPO}/build" ]; then
    mkdir -p "$DEST"
    [ -d "$APP" ] && /usr/bin/trash "$APP"
    cp -R "$STAGING" "$APP"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi

echo
echo "built:  ${APP}"
