#!/bin/zsh
# Builds the Debug app for a real device, as the normal app
# (com.kounex.antiphon): it installs over the one on the phone and keeps its
# data, sign-ins and permissions. There is no separate dev app any more; the
# person deletes it (2026-11-11).
# Install: xcrun devicectl device install app --device <id> build/device/Build/Products/Debug-iphoneos/Antiphon.app
setopt pipefail  # fail with xcodebuild, not with grep
cd "$(dirname "$0")/.."
xcodebuild -project Antiphon.xcodeproj -scheme "Antiphon (Debug)" -destination "generic/platform=iOS" \
  -derivedDataPath build/device -allowProvisioningUpdates build 2>&1 \
  | grep -E "error:|\*\* BUILD"
