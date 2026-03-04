#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Notchi Release Script
# Usage: ./scripts/create-release.sh <version>
# Example: ./scripts/create-release.sh 1.1.0
# =============================================================================

# --- Configuration ---
TEAM_ID="SXT98GH5HN"
BUNDLE_ID="com.ruban.notchi"
SCHEME="notchi"
PROJECT_PATH="notchi/notchi.xcodeproj"
APPCAST_OUTPUT="docs/appcast.xml"
APP_NAME="Notchi"

# TODO: Set your notarytool keychain profile name.
# Create one with: xcrun notarytool store-credentials "notchi-notarize" --apple-id "you@example.com" --team-id "SXT98GH5HN"
NOTARYTOOL_PROFILE="notchi-notarize"

# Sparkle tools directory — override with SPARKLE_BIN_DIR env var.
# Falls back to searching DerivedData for the Sparkle build artifacts.
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-}"

BUILD_DIR="build/release"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"

# --- Helpers ---
step() {
    echo ""
    echo "===> $1"
    echo ""
}

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

find_sparkle_bin_dir() {
    if [[ -n "$SPARKLE_BIN_DIR" ]]; then
        echo "$SPARKLE_BIN_DIR"
        return
    fi

    local derived_data="${HOME}/Library/Developer/Xcode/DerivedData"
    local found
    found=$(find "$derived_data" -path "*/Sparkle.framework/../bin" -type d 2>/dev/null | head -n 1)

    if [[ -z "$found" ]]; then
        found=$(find "$derived_data" -name "sign_update" -type f 2>/dev/null | head -n 1)
        if [[ -n "$found" ]]; then
            found=$(dirname "$found")
        fi
    fi

    if [[ -z "$found" ]]; then
        fail "Could not find Sparkle tools. Set SPARKLE_BIN_DIR to the directory containing sign_update and generate_appcast."
    fi

    echo "$found"
}

# --- Step 1: Validate version argument ---
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    fail "Usage: $0 <version>  (e.g. $0 1.1.0)"
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "Version must be in semver format (e.g. 1.1.0), got: $VERSION"
fi

ZIP_NAME="${APP_NAME}-${VERSION}.zip"
ZIP_PATH="${BUILD_DIR}/${ZIP_NAME}"

step "Starting release build for ${APP_NAME} v${VERSION}"

# --- Step 2: Clean and archive ---
step "Step 1/6: Clean and archive (Developer ID distribution)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild clean archive \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE="Manual" \
    | xcpretty || xcodebuild clean archive \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE="Manual"

echo "Archive created at ${ARCHIVE_PATH}"

# --- Step 3: Export the archive ---
step "Step 2/6: Export archive"

EXPORT_OPTIONS_PLIST="${BUILD_DIR}/ExportOptions.plist"
cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -exportPath "$EXPORT_DIR" \
    | xcpretty || xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -exportPath "$EXPORT_DIR"

if [[ ! -d "$APP_PATH" ]]; then
    fail "Export failed: ${APP_PATH} not found"
fi

echo "Exported ${APP_PATH}"

# --- Step 4: Notarize and staple ---
step "Step 3/6: Notarize and staple"

echo "Submitting for notarization..."
xcrun notarytool submit "$APP_PATH" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

echo "Notarization complete and stapled into ${APP_PATH}"

# --- Step 5: Create zip ---
step "Step 4/6: Create distribution zip"

pushd "$EXPORT_DIR" > /dev/null
ditto -c -k --keepParent "${APP_NAME}.app" "../${ZIP_NAME}"
popd > /dev/null

if [[ ! -f "$ZIP_PATH" ]]; then
    fail "Zip creation failed: ${ZIP_PATH} not found"
fi

echo "Created ${ZIP_PATH}"

# --- Step 6: Sign with Sparkle ---
step "Step 5/6: Sign zip with Sparkle"

SPARKLE_BIN_DIR=$(find_sparkle_bin_dir)
SIGN_UPDATE="${SPARKLE_BIN_DIR}/sign_update"
GENERATE_APPCAST="${SPARKLE_BIN_DIR}/generate_appcast"

if [[ ! -x "$SIGN_UPDATE" ]]; then
    fail "sign_update not found or not executable at ${SIGN_UPDATE}"
fi

if [[ ! -x "$GENERATE_APPCAST" ]]; then
    fail "generate_appcast not found or not executable at ${GENERATE_APPCAST}"
fi

echo "Using Sparkle tools from: ${SPARKLE_BIN_DIR}"

SIGNATURE=$("$SIGN_UPDATE" "$ZIP_PATH")
echo "Sparkle signature:"
echo "$SIGNATURE"

# --- Step 7: Generate appcast ---
step "Step 6/6: Generate appcast"

mkdir -p "$(dirname "$APPCAST_OUTPUT")"

# generate_appcast expects a directory containing the signed zips
"$GENERATE_APPCAST" "$BUILD_DIR" -o "$APPCAST_OUTPUT"

echo "Appcast written to ${APPCAST_OUTPUT}"

# --- Done ---
step "Release v${VERSION} built successfully!"

echo "Files:"
echo "  Zip:     ${ZIP_PATH}"
echo "  Appcast: ${APPCAST_OUTPUT}"
echo ""
echo "Next steps:"
echo "  1. Create a GitHub Release tagged v${VERSION}"
echo "  2. Upload ${ZIP_PATH} to the GitHub Release"
echo "  3. Commit ${APPCAST_OUTPUT} and push to main"
echo "  4. Verify the appcast download URL matches your GitHub Release asset URL"
