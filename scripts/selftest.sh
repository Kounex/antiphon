#!/bin/zsh
# On-device self-test against the real Spotify and Apple Music accounts.
# Builds the dev app, waits for an unlocked phone, installs, runs, and prints
# the [SELFTEST] lines. Full device log: build/logs/selftest.log.
# usage: scripts/selftest.sh [scenario]   (no scenario = all default scenarios)
# Scenarios: twoway sameorder album library undo recheck monitor
#            (only by name: ownam realpreview icon). See SelfTestRunner.swift.
cd "$(dirname "$0")/.."
DEV=${DEVICE_ID:-E027CD50-71A3-550D-B5FA-24BA79C6EA30}
APP=build/dev/Build/Products/Debug-iphoneos/Antiphon.app
LOG=build/logs/selftest.log
mkdir -p build/logs
[[ "$SKIP_BUILD" == 1 ]] || scripts/build-dev.sh
for i in {1..120}; do
  xcrun devicectl device install app --device $DEV $APP > /dev/null 2>&1 && break
  sleep 10
done
ROUTE=selftest${1:+/$1}
xcrun devicectl device process launch --device $DEV --terminate-existing --console com.kounex.antiphon.dev -- \
  -AntiphonScreen $ROUTE -AntiphonSelfTestExit YES > $LOG 2>&1
grep "\[SELFTEST\]" $LOG | sed 's/.*\[SELFTEST\] //'
