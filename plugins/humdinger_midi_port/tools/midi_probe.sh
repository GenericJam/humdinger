#!/usr/bin/env bash
# Listen on a MIDI device's output port from outside the app (as the adb shell
# user) and print what arrives. Proves the Humdinger port delivers to another
# process.
#
#   plugins/humdinger_midi_port/tools/midi_probe.sh <serial> [device name] [seconds]
#
# Prints DEVICE lines for every MIDI device, then LISTENING, then one
# "RECV 90 45 5c" line per message received. Needs JDK 17+ and the Android SDK
# (platforms/android-35, build-tools with d8).
set -euo pipefail

serial=${1:?usage: midi_probe.sh <serial> [device name] [seconds]}
name=${2:-Humdinger}
seconds=${3:-30}

sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
android_jar=$sdk/platforms/android-35/android.jar
d8=$(ls -d "$sdk"/build-tools/*/d8 | sort -V | tail -n 1)
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

javac --release 17 -classpath "$android_jar" -d "$work" "$here/MidiProbe.java"
"$d8" --min-api 28 --lib "$android_jar" --output "$work" "$work"/*.class
adb -s "$serial" push "$work/classes.dex" /data/local/tmp/midi_probe.dex >/dev/null
adb -s "$serial" shell CLASSPATH=/data/local/tmp/midi_probe.dex \
  app_process /system/bin MidiProbe "'$name'" "$seconds"
