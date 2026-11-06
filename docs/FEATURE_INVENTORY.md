# Galaxy Watch4 Classic ↔ iPhone: feature inventory

Sources: this repo; the watch snapshot in `research/snapshot-before-reset` (installed packages,
settings); watch APKs pulled earlier; live adb/Bluetooth work from earlier sessions. The watch was not
on adb and the Samsung SDK was not on the Mac when this was written, so items marked
*needs hardware check* or *needs SDK* are unverified.

**Status key:** ✅ demonstrated on your watch and iPhone · 🧪 built and unit-tested, not yet seen on
hardware · ⬜ not built

**Classes:** IMPLEMENTABLE · PARTIAL (some of it achievable) · INVESTIGATE · ANDROID ONLY ·
BLOCKED BY NATIVE PAIRING · NOT SUPPORTED

**Routes used below**
- **GBLink**: our own encrypted BLE channel between the two apps (works today).
- **ANCS / AMS**: iOS's built-in notification and media services, read by our watch app. They run
  without the iPhone app being open.
- **HFP / MAP / PBAP**: classic Bluetooth call, message and phonebook profiles. The iPhone offers
  them; the watch's Bluetooth stack has clients for them, controlled by the system, not by apps.
- **adb grant**: a one-time permission you give our watch app from the Mac (e.g.
  `WRITE_SECURE_SETTINGS`). Fine for your own watch; another user would need to do the same.

Why Galaxy Wearable features don't come "for free": Galaxy Wearable talks to the watch over
Samsung's own accessory protocol and plugins, which only exist on Android phones. Everything below is
rebuilt on top of GBLink, ANCS/AMS or system Bluetooth profiles instead.

Native pairing affects only one item: **setting up a freshly reset watch without Android**. Nothing
else below depends on it.

---

## A. Connectivity and device management

| Feature | Class | Status | Reason / route | Work required |
|---|---|---|---|---|
| Connect / disconnect | IMPLEMENTABLE | ✅ | GBLink with numeric-comparison bonding | — |
| Automatic reconnection | IMPLEMENTABLE | ✅ (unreliable) | iOS pending connect + watch auto-reconnect | Harden: Samsung battery-optimisation exemption, watch-side reconnect, iOS state restoration checks |
| Connection status | IMPLEMENTABLE | ✅ | Both apps show it | — |
| Signal strength | IMPLEMENTABLE | ⬜ | iOS `CBPeripheral.readRSSI` on the live link | Small: show in watch card |
| Watch battery / charging | IMPLEMENTABLE | ✅ | GBLink status | — |
| Device info, firmware version | IMPLEMENTABLE | ✅ partial | Model and Android version shown; build number and security patch are readable (`Build.DISPLAY`, `SECURITY_PATCH`) | Add fields |
| Connection history | IMPLEMENTABLE | ⬜ | Log connect/disconnect events on the iPhone | Small |
| Find My Watch | IMPLEMENTABLE | ✅ | GBLink → watch rings | — |
| Find My Phone | IMPLEMENTABLE | ✅ | GBLink → iPhone alert | — |
| Disconnection alerts | IMPLEMENTABLE | ⬜ | Local notification after a grace period (iPhone) and a watch buzz | Small |
| Works with iPhone app closed | PARTIAL | ⬜ | Notifications, music, calls and shutter come from iOS itself, so they keep working. Health sync and settings need our app; iOS **won't** relaunch an app you swiped away (Apple rule), but does relaunch one iOS suspended | Make the watch reconnect on its own to the iPhone's system services; verify on hardware |

## B. Notifications

| Feature | Class | Status | Reason / route | Work required |
|---|---|---|---|---|
| iPhone notifications on watch | IMPLEMENTABLE | ✅ | ANCS | — |
| Per-app controls (mute apps) | IMPLEMENTABLE | ⬜ | ANCS gives each notification's app ID; filter on the watch, managed from the iPhone | Medium: app list, sync, UI |
| Categories (social, email, calendar…) | IMPLEMENTABLE | 🧪 | ANCS category IDs already parsed | Add per-category toggles |
| Delivery with iPhone app closed | IMPLEMENTABLE | ⬜ | ANCS is part of iOS, not our app | Needs hardware check |
| Two-way dismissal | IMPLEMENTABLE | ✅ | ANCS remove events + negative action | — |
| Actions (e.g. "Mark as read", "Clear") | PARTIAL | ✅ | ANCS exposes at most one positive and one negative action per notification | — |
| Replies | NOT SUPPORTED | — | ANCS has no reply, and iOS has no API for third-party apps to reply to other apps' messages. MAP SMS sending is a separate, unverified route (see C) | — |
| Preferences (vibration, quiet hours) | IMPLEMENTABLE | ⬜ | Watch notification channels; vibration patterns | Small |

## C. Calls and communication

| Feature | Class | Status | Reason / route | Work required |
|---|---|---|---|---|
| Incoming call alert, caller name | IMPLEMENTABLE | ✅ | ANCS incoming-call category | — |
| Answer / reject from watch | INVESTIGATE | ❌ answer reported failing | ANCS positive/negative action should answer/decline on iOS; needs logs from a test call | Capture logs during a call; fix |
| Call audio on the watch | INVESTIGATE | ⬜ | Needs the watch connected as an HFP hands-free device. It worked with your old iPhone bond; the current bond has the hands-free profile off. Apps can't switch it on; adb or Bluetooth settings might | Try enabling HFP client over adb; if it connects, Samsung's own call screen takes over |
| Outgoing calls from watch | INVESTIGATE | ⬜ | Only possible over HFP (watch dials via the iPhone). Depends on the row above | As above, then test Samsung Dialer |
| Call status, call log | PARTIAL | ⬜ | Live state via ANCS / HFP; iOS gives apps no call history | — |
| Contacts on watch | IMPLEMENTABLE | ⬜ | iPhone app reads Contacts (with permission) and sends them; watch app writes them into the watch's contacts store (`WRITE_CONTACTS`, a normal runtime permission), so Samsung Contacts and Dialer show them | Medium |
| Message notifications | IMPLEMENTABLE | ✅ | ANCS | — |
| Reading full message threads / SMS replies | INVESTIGATE | ⬜ | The iPhone offers MAP (used by car kits). Whether iOS allows sending through it to this watch, and whether a watch app can use MAP, are unverified | Probe MAP from the watch |

## D. Watch faces and customisation

| Feature | Class | Status | Reason / route | Work required |
|---|---|---|---|---|
| List installed watch faces | IMPLEMENTABLE | ⬜ | Watch faces are apps with a known service type; watch app queries the package manager | Small–medium; send list (with names) to iPhone |
| Change watch face from iPhone | INVESTIGATE | ⬜ | Normal apps can't set the watch face (system permission). Wear OS has a developer broadcast (`DEBUG_SURFACE set-watchface`) that works from adb; whether it works from our app, or via a Samsung setting, is unknown | Test on watch. Fallback: open the picker |
| Open the native watch-face picker | PARTIAL | ⬜ | Background apps can't open screens on Android 14; a full-screen notification can | Small |
| Customise a face (colours, slots) | INVESTIGATE | ⬜ | The face's own editor is a system screen; may be launchable for the active face | Test |
| Complications | IMPLEMENTABLE | ✅ | Our providers: iPhone battery, weather, next event | Add more (steps, HR, calendar count) |
| Favourites | INVESTIGATE | ⬜ | Samsung keeps its own favourites list; storage unknown | Inspect on watch |
| Install new faces | PARTIAL | ✅ / ⬜ | Google Play web page from the iPhone (done). Sideloading a face APK from the Mac via adb also works | — |

## E. Music and media

| Feature | Class | Status | Reason / route | Work required |
|---|---|---|---|---|
| Play / pause / skip / volume / track info | IMPLEMENTABLE | ✅ | AMS | — |
| Media controls with iPhone app closed | IMPLEMENTABLE | ⬜ | AMS is part of iOS | Needs hardware check |
| Transfer music iPhone → watch | PARTIAL | ⬜ | Apple Music / iTunes library files are DRM-protected and not readable by apps. Your own DRM-free files (Files app) can be sent; BLE is too slow, so it would need Wi-Fi transfer | Medium–large |
| Local music management | PARTIAL | ⬜ | Watch app can list/delete audio files it can read; playback stays in Samsung Music | Medium |

## F. Camera

| Feature | Class | Status | Reason / route | Work required |
|---|---|---|---|---|
| Remote shutter (stock Camera app) | IMPLEMENTABLE | ✅ | Watch acts as a Bluetooth volume-up button | — |
| Shutter in our camera | IMPLEMENTABLE | ✅ | GBLink | — |
| Live preview on watch | PARTIAL | ⬜ | Only for our in-app camera (stock Camera can't share frames). Low-res frames over BLE at ~1–2 fps | Medium |
| Timer, flash, front/back switch | PARTIAL | ⬜ | Our camera only; stock Camera only accepts the shutter | Small–medium |

## G. Health and fitness

| Feature | Class | Status | Reason / route | Work required |
|---|---|---|---|---|
| Heart rate → Apple Health | IMPLEMENTABLE | ✅ | Health Services passive monitoring | — |
| Steps, active energy, distance | IMPLEMENTABLE | ✅ | Health Services | — |
| Floors climbed | IMPLEMENTABLE | ⬜ | Health Services `FLOORS` | Small |
| Faster catch-up sync | IMPLEMENTABLE | ⬜ | Merge queued readings into large batches, more in flight, save concurrently | Medium (planned) |
| SpO2 → Apple Health | IMPLEMENTABLE | ⬜ | Samsung Health Sensor SDK on-demand SpO2 → HealthKit Blood Oxygen | Needs SDK + Health Platform dev mode |
| ECG | PARTIAL | ⬜ | SDK gives the raw trace; Apple doesn't let apps write ECGs into Health, and there's no AFib classification | Record + show in app |
| Body composition (BIA) | IMPLEMENTABLE | ⬜ | SDK BIA → HealthKit body fat %, lean mass | Needs SDK |
| HRV (Apple Health) | IMPLEMENTABLE | ⬜ | SDK continuous HR with beat intervals → SDNN | Needs SDK |
| Stress score | PARTIAL | ⬜ | Samsung's stress score isn't in any SDK; an HRV-based estimate is possible but not Samsung's number | Optional |
| Skin temperature | NOT SUPPORTED | — | No skin-temperature sensor on the Watch4 (Watch5 and later) | — |
| Sleep | INVESTIGATE | ⬜ | Samsung Health's sleep analysis isn't in Health Services or the Sensor SDK; it normally syncs via the Android phone app. Health Connect exists on the watch but isn't documented for this | Inspect on watch; likely ANDROID ONLY |
| Workouts with GPS → Apple Health | IMPLEMENTABLE | ⬜ | Health Services exercise API + watch GPS → HealthKit workout with route | Large |
| Samsung Health history | ANDROID ONLY | — | Stored by Samsung Health / Samsung Cloud; no API on the watch | — |
| Background sync | IMPLEMENTABLE | ✅ | Durable watch outbox + acks | Speed-up planned |

## H. Watch settings

| Feature | Class | Status | Reason / route | Work required |
|---|---|---|---|---|
| Brightness, screen timeout | IMPLEMENTABLE | ✅ | `WRITE_SETTINGS` | — |
| Do Not Disturb | IMPLEMENTABLE | ✅ | DND access | — |
| Volume (media, ring, notification, alarm) | IMPLEMENTABLE | ⬜ | Audio manager, no special permission | Small |
| Sound / vibrate / mute mode | IMPLEMENTABLE | ⬜ | Ringer mode (needs DND access, already granted) | Small |
| Ringtone, notification sound | IMPLEMENTABLE | ⬜ | `WRITE_SETTINGS` (granted); list system sounds | Small |
| Always-on display | IMPLEMENTABLE | ⬜ | `ambient_enabled` global setting via adb-granted `WRITE_SECURE_SETTINGS` | Small; needs hardware check that it takes effect live |
| Raise-to-wake, double-tap-to-wake | IMPLEMENTABLE | ⬜ | `wake_gesture_enabled`, `double_tap_to_wake` secure settings (adb grant) | Small |
| Theatre mode | INVESTIGATE | ⬜ | `theater_mode_on` global setting (adb grant); unsure the system reacts without its own toggle | Test |
| Bedtime mode | INVESTIGATE | ⬜ | Samsung mode manager (`ModeManagerContentProvider`), undocumented | Inspect on watch |
| Battery saver | INVESTIGATE | ⬜ | `low_power` global setting (adb grant) works on some devices | Test |
| Wi-Fi | PARTIAL | ⬜ | Apps can't toggle Wi-Fi on Android 10+; can open the Wi-Fi screen on the watch | Small |
| Bluetooth | NOT SUPPORTED (by design) | — | Turning it off would cut the link to the iPhone | — |
| Quick-settings layout | NOT SUPPORTED | — | Samsung system UI, no API | — |
| Font size | IMPLEMENTABLE | ⬜ | `font_scale` (`WRITE_SETTINGS`) | Small |
| Other accessibility | PARTIAL | ⬜ | Some secure settings (adb grant); screen readers need the system | Per item |
| Emergency SOS | ANDROID ONLY | — | Samsung Safety Assistance is configured via Galaxy Wearable | — |
| Language / region | PARTIAL | ⬜ | Changing system locale needs `CHANGE_CONFIGURATION` (grantable over adb) | Test |
| Time / time zone | NOT SUPPORTED | ✅ workaround | System-only permission; clock-wrong warning and health timestamp correction are done | — |

## I. Apps and content

| Feature | Class | Status | Reason / route | Work required |
|---|---|---|---|---|
| Installed app list, versions | IMPLEMENTABLE | ⬜ | Package manager query from the watch app | Small–medium |
| App storage size | IMPLEMENTABLE | ⬜ | Storage stats (usage-access permission, adb grantable) | Small |
| Uninstall an app | PARTIAL | ⬜ | Our app can show the uninstall prompt on the watch; you confirm there | Small |
| Install apps | PARTIAL | ✅ / ⬜ | Google Play web from the iPhone (done); adb sideload from the Mac | — |
| Launch an app from the iPhone | PARTIAL | ⬜ | Android blocks background launches; a tappable/full-screen notification works | Small |
| Calendar | IMPLEMENTABLE | ✅ partial | Agenda in our app and complication. Writing events into the watch's own calendar (`WRITE_CALENDAR`) would make Samsung Calendar show them | Medium |
| Weather | IMPLEMENTABLE | ✅ partial | In our app and complication. Samsung's Weather app only takes data from Galaxy Wearable (ANDROID ONLY) | — |
| Alarms, timers | PARTIAL | ⬜ | Standard "set alarm/timer" intents open the watch's clock app; background limits mean a tappable notification is needed | Small–medium |
| Reminders | PARTIAL | ⬜ | Read iPhone Reminders (EventKit) and show them in our app; Samsung Reminder app is ANDROID ONLY | Medium |
| Photos to watch gallery | PARTIAL | ⬜ | Pick on iPhone, save into the watch's media store so Samsung Gallery shows them; BLE is slow (seconds per photo) | Medium |
| Voice recordings to iPhone | PARTIAL | ⬜ | Read recordings on the watch (media permission) and send; slow over BLE | Medium |
| Samsung Pay / Google Wallet | ANDROID ONLY | — | Both need an Android phone account link | — |
| SmartThings Find (Samsung's find network) | ANDROID ONLY | — | Samsung account + Android | — |

## J. Software and maintenance

| Feature | Class | Status | Reason / route | Work required |
|---|---|---|---|---|
| Firmware / build / security patch | IMPLEMENTABLE | ⬜ | Readable by any app | Small |
| Software update check / install | PARTIAL | ⬜ | Updates come from Samsung's update agent, normally triggered by Galaxy Wearable. We can open the watch's own Software update screen (may work over Wi-Fi) | Small; needs hardware check |
| Storage | IMPLEMENTABLE | ✅ | — | — |
| Battery health, charge cycles | IMPLEMENTABLE | ⬜ | Android 14 battery info (health, cycle count) | Small |
| Link diagnostics (our app) | IMPLEMENTABLE | ⬜ | Connection log, sync stats, last errors, exportable | Small–medium |
| System logs | PARTIAL | ⬜ | `READ_LOGS` via adb grant; export our own logs only by default | Small |
| Backup / restore | PARTIAL | ⬜ | Samsung backup is ANDROID ONLY; our own app settings can be backed up | Small |
| Initial setup of a reset watch | BLOCKED BY NATIVE PAIRING | — | Needs the encryption layer (paused) | See docs/NATIVE_PAIRING.md |

---

## Compared with Galaxy Wearable on Android

**You'll have:** health sync to Apple Health (HR, steps, energy, distance, floors; SpO2, BIA and HRV
once the SDK is in), notifications with actions and two-way dismissal, call alerts with answer/decline,
music remote, camera remote, find watch/phone, the watch's display, sound, AOD and DND settings from
the iPhone, installed apps and storage, iPhone battery/weather/calendar on the watch, contacts on the
watch, watch faces from Google Play, and diagnostics.

**Possibly (needs hardware checks):** call audio and outgoing calls on the watch (HFP), switching watch
faces from the iPhone, theatre/bedtime/battery saver, SMS replies (MAP), sleep.

**Not possible on iPhone:** replying to other apps' notifications, Samsung Pay / Wallet, Emergency SOS
setup, Samsung Health history and its own sleep and stress scores, skin temperature (no sensor),
Samsung Weather/Reminder native apps, quick-settings layout, Apple Music transfer, setting the watch
clock, and setting up a reset watch (until native pairing resumes).

---

## Roadmap

**Phase 1: fixes you asked for (no hardware dependency)**
1. Faster catch-up sync: merge the queue into large batches, more in flight, concurrent saves.
2. Stay connected: battery-optimisation exemption, watch-side reconnect to the iPhone's own services,
   disconnection alerts, connection history, signal strength.
3. Device info: build, security patch, battery health and cycles.

**Phase 2: watch on adb (grants and checks)**
4. Calls: logs from a test call, fix answering; try enabling HFP for audio and outgoing calls.
5. Watch faces: list installed faces; test switching; fallback to opening the picker.
6. Settings: volume, sound mode, ringtone, AOD, wake gestures, font size; then test theatre mode,
   bedtime, battery saver, language.
7. Per-app and per-category notification controls.
8. Apps: installed list, storage, uninstall prompt, open on watch.
9. Contacts and calendar into the watch's own apps.

**Phase 3: Samsung Health Sensor SDK**
10. SpO2 → Apple Health. 11. ECG recording and viewer. 12. BIA, HRV.

**Phase 4: larger items**
13. Workouts with GPS → Apple Health. 14. Floors and more complications.
15. Camera timer/preview. 16. Photos to watch, recordings to iPhone.
17. Investigate: MAP messages, sleep, alarms/timers, software update screen.
18. **Tiles** (added from the watch's normal "Add tiles" screen, like any app): Calendar (upcoming
    iPhone events) and Reminders (iPhone Reminders, with tick-off), plus Weather, iPhone battery and
    Now Playing. Data comes from the iPhone app over GBLink; Samsung's own Calendar/Reminder apps are
    left alone.

**Phase 5: any Wear OS watch**
19. Make the watch app work on non-Samsung Wear OS 3+ watches (Pixel Watch, TicWatch, etc.):
    everything built on Health Services, ANCS/AMS, GBLink, tiles and complications is standard
    Wear OS. Samsung-only parts (Health Sensor SDK: SpO2, ECG, BIA; Samsung settings keys) are
    detected at runtime and hidden when missing. Test on at least one non-Samsung watch.

**Paused:** native pairing (Stage 4a onward). Tester and docs unchanged; nothing above depends on it.
