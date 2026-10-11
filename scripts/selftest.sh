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
if [[ "$SKIP_BUILD" != 1 ]]; then
  scripts/build-dev.sh || { echo "Build failed; not running the self-test." >&2; exit 1; }
fi
installed=0
for i in {1..120}; do
  xcrun devicectl device install app --device $DEV $APP > /dev/null 2>&1 && { installed=1; break; }
  sleep 10
done
(( installed )) || { echo "Couldn't install on the phone (locked or disconnected?); not running the self-test." >&2; exit 1; }
ROUTE=selftest${1:+/$1}
# A locked phone refuses the launch: wait for it to be unlocked.
for i in {1..60}; do
  xcrun devicectl device process launch --device $DEV --terminate-existing --console com.kounex.antiphon.dev -- \
    -AntiphonScreen $ROUTE -AntiphonSelfTestExit YES > $LOG 2>&1
  grep -q "could not be, unlocked" $LOG || break
  (( i == 1 )) && echo "The phone is locked; unlock it to start the self-test." >&2
  sleep 10
done
grep "\[SELFTEST\]" $LOG | sed 's/.*\[SELFTEST\] //'
# No summary line means the self-test never ran or didn't finish.
grep -q "\[SELFTEST\] DONE" $LOG || { echo "The self-test didn't finish; see $LOG." >&2; exit 1; }
grep -q "\[SELFTEST\] DONE.*failed=0" $LOG
