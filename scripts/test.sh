#!/bin/zsh
# Unit tests on the simulator. Prints only failures and the summary.
# usage: scripts/test.sh [extra xcodebuild args, e.g. -only-testing:AntiphonTests/TrackOrderTests]
cd "$(dirname "$0")/.."
SIM_NAME=${SIM_NAME:-"iPhone 17 Pro"}
mkdir -p build/logs
xcodebuild test -project Antiphon.xcodeproj -scheme "Antiphon (Debug)" -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -derivedDataPath build/dd "$@" > build/logs/test.log 2>&1
grep -E "error:|warning: |✘|Test run with|\*\* TEST" build/logs/test.log | grep -v "deprecated in iOS 26" | head -40
