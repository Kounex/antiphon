#!/bin/zsh
# App Store screenshot captures for the store-shots composer (github.com/Kounex/store-shots,
# projects/antiphon). Preview data only (DEBUG routes, -AntiphonStoreData): no real accounts.
#
# usage: scripts/store_screenshots.sh [phone|tablet|all] [slot ...]
#   e.g. scripts/store_screenshots.sh all            every slot on both simulators
#        scripts/store_screenshots.sh phone 01 07    two slots on the iPhone
#   NO_BUILD=1 skips the build and install.
#
# Simulators (dedicated, they get a pinned locale and status bar): "Store iPhone 6.9"
# (iPhone 17 Pro Max, 1320x2868) and "Store iPad 13" (iPad Pro 13", 2064x2752 portrait).
# Output: build/store_screenshots/<ios-phone|ios-tablet>/<NN>_<name>.png
cd "$(dirname "$0")/.."
PHONE=${STORE_PHONE_ID:-3ED536FD-EAB9-4774-8EB6-AA44C089AB2A}
TABLET=${STORE_TABLET_ID:-1AF38F8C-5011-49CE-95B5-7F0517A0C1B2}
BUNDLE=com.kounex.antiphon
APP=build/dd/Build/Products/Debug-iphonesimulator/Antiphon.app

# slot  route                        file name
SLOTS=(
  "01 shell/store                 01_home"
  "02 onboarding/connect-spotify  02_connect"
  "03 onboarding/twins            03_twins"
  "04 shell/newseam/rules         04_direction"
  "05 shell/preview               05_preview"
  "06 shell/review                06_review"
  "07 shell/activity-new          07_activity"
)

which=${1:-all}; shift 2>/dev/null
wanted=("$@")
case $which in
  phone) devices=("$PHONE ios-phone") ;;
  tablet) devices=("$TABLET ios-tablet") ;;
  all) devices=("$PHONE ios-phone" "$TABLET ios-tablet") ;;
  *) echo "usage: $0 [phone|tablet|all] [slot ...]"; exit 1 ;;
esac

prepare() {  # boot with an en_US locale, dark mode and Apple's 9:41 status bar
  local sim=$1
  xcrun simctl boot $sim 2>/dev/null
  if [[ $(xcrun simctl spawn $sim defaults read -g AppleLocale 2>/dev/null) != en_US ]]; then
    xcrun simctl spawn $sim defaults write -g AppleLanguages -array en-US
    xcrun simctl spawn $sim defaults write -g AppleLocale en_US
    xcrun simctl shutdown $sim; xcrun simctl boot $sim; sleep 8
  fi
  xcrun simctl ui $sim appearance dark
  xcrun simctl ui $sim content_size large
  # ISO time with milliseconds and the Mac's offset, or simctl refuses it; iPad shows today's date next to it
  local at="$(date +%Y-%m-%d)T09:41:00.000$(date +%z | sed 's/\(..\)$/:\1/')"
  xcrun simctl status_bar $sim override --time "$at" --batteryLevel 100 --batteryState discharging \
    --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi --operatorName ""
}


if [[ -z $NO_BUILD ]]; then
  xcodebuild -project Antiphon.xcodeproj -scheme "Antiphon (Debug)" -destination "platform=iOS Simulator,id=$PHONE" \
    -derivedDataPath build/dd build 2>&1 | grep -E "error:|\*\* BUILD"
  (( ${pipestatus[1]} == 0 )) || exit 1
fi

for entry in "${devices[@]}"; do
  sim=${entry%% *}; source=${entry##* }
  out=build/store_screenshots/$source
  mkdir -p $out
  prepare $sim
  [[ -z $NO_BUILD ]] && xcrun simctl install $sim $APP
  # `ui appearance` goes through Settings, and the next launch gets a "◀ Settings" back link: launch once to use it up
  xcrun simctl terminate $sim com.apple.Preferences 2>/dev/null
  xcrun simctl launch $sim $BUNDLE >/dev/null; sleep 3; xcrun simctl terminate $sim $BUNDLE
  for slot in "${SLOTS[@]}"; do
    parts=(${=slot}); n=$parts[1]; route=$parts[2]; name=$parts[3]
    (( ${#wanted} )) && [[ ${wanted[(Ie)$n]} == 0 ]] && continue
    xcrun simctl terminate $sim $BUNDLE 2>/dev/null
    xcrun simctl launch $sim $BUNDLE -AntiphonScreen $route -AntiphonStoreData YES >/dev/null
    sleep ${WAIT:-7}
    xcrun simctl io $sim screenshot $out/$name.png >/dev/null 2>&1 && echo "$out/$name.png"
  done
done
