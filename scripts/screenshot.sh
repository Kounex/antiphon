#!/bin/zsh
# Screenshot a DEBUG route in the simulator (see Antiphon/Debug/DebugRouter.swift).
# usage: scripts/screenshot.sh <route> <light|dark> <name> [content_size] [contrast:enabled|disabled]
#   e.g. scripts/screenshot.sh shell/library light library
#        scripts/screenshot.sh shell/settings/matching dark matching accessibility-extra-extra-extra-large
# Build and install first: scripts/screenshot.sh --install
cd "$(dirname "$0")/.."
SIM=${SIM_ID:-D6F98034-F7A7-4574-967C-A9E182A7ED3A}
OUT=build/shots
mkdir -p $OUT
if [[ "$1" == "--install" ]]; then
  xcodebuild -project Antiphon.xcodeproj -scheme "Antiphon (Debug)" -destination "platform=iOS Simulator,id=$SIM" \
    -derivedDataPath build/dd build 2>&1 | grep -E "error:|\*\* BUILD"
  (( ${pipestatus[1]} == 0 )) || exit 1  # don't install the previous build
  xcrun simctl install $SIM build/dd/Build/Products/Debug-iphonesimulator/Antiphon.app
  exit
fi
xcrun simctl ui $SIM appearance $2
xcrun simctl ui $SIM content_size ${4:-large}
xcrun simctl ui $SIM increase_contrast ${5:-disabled}
xcrun simctl terminate $SIM com.kounex.antiphon 2>/dev/null
xcrun simctl launch $SIM com.kounex.antiphon -AntiphonScreen "$1" >/dev/null
sleep ${WAIT:-4}
xcrun simctl io $SIM screenshot $OUT/$3.png >/dev/null 2>&1
xcrun simctl ui $SIM content_size large
echo $OUT/$3.png
