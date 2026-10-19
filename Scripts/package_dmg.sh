#!/usr/bin/env bash
# Builds a Release NeoBar.app and wraps it in a drag-to-Applications DMG under dist/.
# Usage: Scripts/package_dmg.sh [version]   (defaults to the project's MARKETING_VERSION)
set -euo pipefail

APP_NAME="NeoBar"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/NeoBar.xcodeproj"
DERIVED_DATA_DIR="$ROOT_DIR/build/ReleaseDerivedData"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME.app"

VERSION="${1:-$(xcodebuild -project "$PROJECT_PATH" -scheme "$APP_NAME" -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION = / { print $2; exit }')}"
# DMG_SUFFIX lets CI tag the file with the commit, e.g. NeoBar-1.0.0-abc1234.dmg.
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION${DMG_SUFFIX:-}.dmg"

# Release builds every architecture (ONLY_ACTIVE_ARCH is off), so the app is universal.
# The project signs ad hoc (CODE_SIGN_IDENTITY = "-"); there is no Developer ID to notarize with.
xcodebuild -project "$PROJECT_PATH" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$DERIVED_DATA_DIR" clean build

codesign --verify --deep --strict "$APP_BUNDLE"

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -fs HFS+ -format UDZO -ov "$DMG_PATH"

echo "$DMG_PATH"
