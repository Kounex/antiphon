#!/bin/zsh
# Builds the side-by-side dev app (com.kounex.antiphon.dev) for a real device.
# Override ANTIPHON_BUNDLE_ID, not PRODUCT_BUNDLE_IDENTIFIER (that renames the
# AntiphonDesign resource bundle and its colors stop resolving).
setopt pipefail  # fail with xcodebuild, not with grep
cd "$(dirname "$0")/.."
xcodebuild -project Antiphon.xcodeproj -scheme "Antiphon (Debug)" -destination "generic/platform=iOS" \
  -derivedDataPath build/dev ANTIPHON_BUNDLE_ID=com.kounex.antiphon.dev -allowProvisioningUpdates build 2>&1 \
  | grep -E "error:|\*\* BUILD"
