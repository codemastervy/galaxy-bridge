# Galaxy Bridge

Use a Samsung Galaxy Watch (Wear OS) with an iPhone: health data in Apple Health, iPhone
notifications and calls on your wrist, music controls, a camera remote and more.

Two apps talk to each other over Bluetooth LE:

| | |
|---|---|
| `watch-app/` | Wear OS app (Kotlin, Jetpack Compose for Wear) |
| `ios-app/` | iPhone companion app (SwiftUI) |
| `WearLink/` | Swift package with the shared protocol code and its tests |

Tested on a Galaxy Watch4 Classic (SM-R890, Wear OS 5 / One UI Watch 6) with an iPhone on iOS 26.

## Features

**Health → Apple Health**
- Heart rate, steps, active energy and distance, recorded on the watch in the background
- Readings are queued on the watch and only deleted after the iPhone confirms Apple Health
  stored them, so nothing is lost while out of range
- Per-type sync toggles; a wrong watch clock is detected and corrected

**iPhone on the watch**
- iPhone notifications as real watch notifications, with their actions; clearing on one
  device clears on the other
- Incoming calls with a full-screen answer/decline screen
- Now playing with play/pause, skip and volume (also in the watch's own media controls)
- iPhone battery, local weather and upcoming calendar events on the watch
- Watch-face complications: iPhone battery, weather, next event

**Watch from the iPhone**
- Watch settings: notifications, calls, music, brightness, screen timeout, Do Not Disturb
- Watch info: model, software, battery, storage
- Find my watch / find my iPhone
- Low watch battery alert
- Browse Google Play watch faces

**Camera remote**
- The watch acts as a Bluetooth shutter for the stock iPhone Camera app, plus a built-in camera

## Requirements and limits

- **The watch must already be set up** (with an Android phone, once). Pairing a freshly reset watch
  straight to an iPhone needs the Wear OS companion encryption layer, which isn't implemented yet;
  see [HANDOFF.md](HANDOFF.md) and [research/PROTOCOL_NOTES.md](research/PROTOCOL_NOTES.md).
- Not possible for third-party apps on these platforms: replying to messages from the watch, call
  audio on the watch, choosing watch faces from the iPhone, and setting the watch's system clock.
- SpO2 and ECG need Samsung's Health Sensor SDK (not included).
- iPhone notifications on the watch need **Share System Notifications** turned on for the watch in
  iPhone Settings → Bluetooth → ⓘ.
- If another iPhone-bridge app is installed on the watch, turn off its notifications to avoid
  duplicates.

## Building

### Watch app
Requires JDK 17+ and the Android SDK (compileSdk 35).

```sh
cd watch-app
./gradlew assembleDebug testDebugUnitTest   # or a local Gradle 8.11
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Optional, so the iPhone can change brightness, screen timeout and Do Not Disturb (or grant these on
the watch under Galaxy Bridge → Settings → Let iPhone change):

```sh
adb shell appops set nz.galaxybridge.watch WRITE_SETTINGS allow
adb shell cmd notification allow_dnd nz.galaxybridge.watch
```

### iPhone app
Requires Xcode 16+. Open `ios-app/GalaxyBridge.xcodeproj`, choose your own signing team, and run
on a device. With a free Apple ID the app has to be reinstalled every 7 days.

### Tests
```sh
cd WearLink && swift test
cd watch-app && ./gradlew testDebugUnitTest
```

## Pairing

1. On the watch, open Galaxy Bridge and tap **Pair iPhone** (the watch accepts a new phone for two minutes).
2. On the iPhone, open Galaxy Bridge, tap **Find my watch** and pick it.
3. Check the code matches on both screens and accept on both.

The iPhone only lists watches that are in pairing mode, and the watch only talks to the phone it
paired with.

## Security and privacy

- All traffic uses the OS Bluetooth stack's authenticated LE Secure Connections pairing (numeric
  comparison); there is no custom cryptography.
- Every message from the other device is strictly validated (types, sizes, ranges, timestamps) before
  use; malformed input is dropped.
- The iPhone app only **writes** to Apple Health; it never reads your existing health data.
- No accounts, analytics or servers. The only network request is the optional weather lookup, which
  sends a location rounded to about 1 km to [Open-Meteo](https://open-meteo.com).
- Calendar events go only to your watch.

## Disclaimer

Not affiliated with or endorsed by Samsung, Google or Apple. "Galaxy" and "Wear OS" are trademarks of
their owners. Health readings are informational and not for medical use. Use at your own risk.

## License

[MIT](LICENSE)
