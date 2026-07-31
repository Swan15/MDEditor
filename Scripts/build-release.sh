#!/bin/bash
# Builds MDEditor.app (Release) and packages it as dist/MDEditor-<version>.dmg.
#
# Usage: Scripts/build-release.sh [version]
#   version  e.g. 0.2.0 — defaults to MARKETING_VERSION from project.yml.
#
# The app is ad-hoc signed ("Sign to Run Locally"), matching project.yml.
# If a Developer ID is ever added, sign + notarize between the build and
# hdiutil steps below.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')}"
SCHEME="MDEditor"
DERIVED="build/release-derived"
DIST="dist"
APP="$DERIVED/Build/Products/Release/MDEditor.app"
DMG="$DIST/MDEditor-$VERSION.dmg"

echo "==> Generating project"
xcodegen

echo "==> Building MDEditor $VERSION (Release)"
# No output filtering: a failed build must abort the script (set -o pipefail),
# never package a partial bundle.
xcodebuild -project MDEditor.xcodeproj -scheme "$SCHEME" \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  build

test -d "$APP" || { echo "Build failed: $APP missing" >&2; exit 1; }
test -x "$APP/Contents/MacOS/MDEditor" || { echo "Build failed: app executable missing in $APP" >&2; exit 1; }

echo "==> Staging DMG contents"
rm -rf "$DIST"
mkdir -p "$DIST/staging"
cp -R "$APP" "$DIST/staging/MDEditor.app"
ln -s /Applications "$DIST/staging/Applications"

echo "==> Creating $DMG"
hdiutil create -volname "MDEditor" -srcfolder "$DIST/staging" \
  -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DIST/staging"

echo "==> Done"
shasum -a 256 "$DMG"
ls -lh "$DMG"
