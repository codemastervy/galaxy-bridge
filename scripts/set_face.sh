#!/bin/sh
# Makes the Wear OS Bridge face the active watch face, using the adb shell's permission to switch
# faces (apps don't have it). Needs JDK 11+, the Android SDK (platform 35, build-tools) and adb.
#   ANDROID_SDK=~/Library/Android/sdk scripts/set_face.sh
set -e
SDK=${ANDROID_SDK:?set ANDROID_SDK}
OUT=$(mktemp -d)
javac -source 11 -target 11 -cp "$SDK/platforms/android-35/android.jar" -d "$OUT" "$(dirname "$0")/setface/SetFace.java"
"$SDK/build-tools/35.0.0/d8" --min-api 30 --output "$OUT" "$OUT/SetFace.class"
adb push "$OUT/classes.dex" /data/local/tmp/setface.dex
adb shell CLASSPATH=/data/local/tmp/setface.dex app_process / SetFace nz.galaxybridge.watch/.face.BridgeFaceService || true
adb shell dumpsys wallpaper | grep -m1 mWallpaperComponent
