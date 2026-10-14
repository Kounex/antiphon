#!/bin/zsh
# Screen recordings for the store-shots creative videos (App Store header + search
# results "live images", github.com/Kounex/store-shots, projects/antiphon). Preview
# data only (DEBUG route shell/store-live): the store home while Run Club syncs.
#
# usage: scripts/store_recording.sh [seconds]     (default 20)
#   NO_BUILD=1 skips the build and install.
# Output: build/store_recordings/ios-phone/home_live.mp4 (1320x2868, constant 30 fps)
# Then copy it to the NAS: projects/antiphon/recordings/ios-phone/ (see the README there).
cd "$(dirname "$0")/.."
SIM=${STORE_PHONE_ID:-3ED536FD-EAB9-4774-8EB6-AA44C089AB2A}
BUNDLE=com.kounex.antiphon
APP=build/dd/Build/Products/Debug-iphonesimulator/Antiphon.app
OUT=build/store_recordings/ios-phone
SECONDS_TO_RECORD=${1:-20}
mkdir -p $OUT

# Same simulator setup as the screenshots, so the first frame matches 01_home.png.
xcrun simctl boot $SIM 2>/dev/null
xcrun simctl ui $SIM appearance dark
xcrun simctl ui $SIM content_size large
at="$(date +%Y-%m-%d)T09:41:00.000$(date +%z | sed 's/\(..\)$/:\1/')"
xcrun simctl status_bar $SIM override --time "$at" --batteryLevel 100 --batteryState discharging \
  --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi --operatorName ""

if [[ -z $NO_BUILD ]]; then
  xcodebuild -project Antiphon.xcodeproj -scheme "Antiphon (Debug)" -destination "platform=iOS Simulator,id=$SIM" \
    -derivedDataPath build/dd build 2>&1 | grep -E "error:|\*\* BUILD"
  (( ${pipestatus[1]} == 0 )) || exit 1
  xcrun simctl install $SIM $APP
fi

xcrun simctl terminate $SIM com.apple.Preferences 2>/dev/null
xcrun simctl terminate $SIM $BUNDLE 2>/dev/null
raw=$OUT/home_live.raw.mov
rm -f $raw
xcrun simctl io $SIM recordVideo --codec h264 --force $raw &
rec=$!
sleep 1.5
xcrun simctl launch $SIM $BUNDLE -AntiphonScreen shell/store-live -AntiphonStoreData YES >/dev/null
sleep $SECONDS_TO_RECORD
kill -INT $rec; wait $rec 2>/dev/null

# Constant 30 fps at native size, BT.709 tagged, as store-shots expects.
ffmpeg -loglevel error -y -i $raw -vf "fps=30,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709" \
  -c:v libx264 -preset slow -crf 12 -pix_fmt yuv420p -movflags +faststart $OUT/home_live.mp4 && echo "$OUT/home_live.mp4"
