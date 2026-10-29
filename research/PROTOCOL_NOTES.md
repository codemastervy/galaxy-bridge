# Galaxy Watch4 (Wear OS 5) ↔ iPhone — protocol notes

Sources (all pulled from the user's SM-R890, decompiled with jadx 1.5.1):
- `SecClockworkSetupWizard.apk` → `research/src/setup`
- Google Play Services 26.32.34 `base.apk`, `classes.dex` + `classes7.dex` → `research/src/gms_classes*`
  (obfuscated; class names below are jadx names in that build and will differ in other GMS versions)

Wear OS still ships Google's full iOS-companion stack. The watch is the BLE **central** to the
iPhone after setup; the iPhone app is a BLE **peripheral** hosting Google's "Clockwork" GATT service,
and iOS itself provides ANCS (notifications), AMS (media) and CTS (time) to the watch.

---

## Stage 1 — setup-time pairing (watch = peripheral, on the OOBE pairing screen)

`com/google/android/clockwork/setup/PairingGattServer.java`

| | UUID | props |
|---|---|---|
| Service | `1c81447b-f48d-4d17-a606-3ff36527045a` | |
| Pairing char | `6fcfb474-ce57-48ff-a4ce-b43767d6d04a` | read + notify (CCCD); returns bond status |
| Capabilities char | `b2ae0493-d87f-475c-b656-5840e0a13fc8` | write, **encrypted** (forces BLE bonding → iOS pairing prompt) |

Capabilities payload = `uint16 LE length` + protobuf `WearPairingCapabilities`:
- field 1 `companionOs`: 0 unknown, **1 = iOS** ("alt mode"), 2 = Android
- field 2 `companionBleRole`: 0/1/2 → saved to `Settings.Global companion_ble_role`

**Our app must send `04 00 08 01 10 02`** (iOS, BLE role 2). See Stage 2 for why role ≠ 1.

Effects (`CtkdEnabledPairingManager`, `DefaultPairingHandler.onBonded`):
- `paired_device_os_type` = 2 (iOS), `companion_address` = iPhone BT address
- `needsA2A()` true for iOS → UKEY2 encryption step (Stage 3)
- Watch later skips Google-account sync, disables AOD by default, uses built-in ANCS client

Other setup facts:
- `SkipSetupAdapter` = setup **command 14** from the companion → marks setup complete
  (`setup_skipped=1`, `user_setup_complete=1`, `device_provisioned=1`).
- Fast Pair RFCOMM server and Samsung `SakSocketServer` also run in OOBE (Android path only).

## Stage 2 — which transport the watch uses (`czqs.java` ~line 437)

```
companion_ble_role == 1  → IosL2capCM (cznz/czmn): BLE L2CAP CoC + **Apple App Attest**
otherwise                → BleConnectionManager (czip): GATT "Clockwork" service, **no App Attest**
```
(the other branch condition `czqs.a && y(config)` uses a static flag that's never set.)

L2CAP path requires App Attest with an app ID in a hardcoded allow-list
(`EQHXZ8M8AV.com.google.Wear`, `…com.google.DeviceCompanion`, etc.). Unforgeable → **we use GATT path.**
Google's own "Wear OS by Google" iOS app *can* pass this check.

## Stage 3 — GATT Clockwork service (hosted by the iPhone app; watch connects as central)

`czjj.java` (UUID table), `czjo.java` (slot map), `czip.java`/`czjr` (state machine)

| Role | UUID | Watch does |
|---|---|---|
| Clockwork service | `2feb2e7e-d3a1-491f-961a-ae85b5920549` | discovers |
| a: watch→phone data | `07b18b65-9076-4050-a754-21adc1e12422` | writes packets |
| b: phone→watch data | `280adb07-4033-40c4-b2c0-8a3c75df4165` | subscribes (notify) |
| c: reconnect | `ffeddd90-74bc-11e4-82f8-0800200c9a66` | subscribes |
| d: reset | `0eb6f3c9-df9c-4679-bcae-06ba51f7920f` | subscribes + writes ascii(MTU-3) |
| e: pairing confirm | `1699e0b2-357c-4c98-8007-7a50b5b3e771` | reads, expects `01` |
| f: decommission | `65bbb4b0-c1c7-11e4-8dfc-aa07a5b093db` | reads, `00` = stay paired |

Connect sequence: read e (until `01`) → read f (`00`) → subscribe b, c, d → write d = ascii(MTU−3)
→ start streams → Wear wire protocol (Stage 4).

Also used on the iPhone (provided by iOS, not our app):
ANCS `7905f431-b5ce-4e99-a40f-4b1e122d00d0` (NS `9fbf120d…`, CP `69d1d8f3…`, DS `22eac6e9…`),
AMS `89D3502B-0F36-433A-8EF4-C502AD55F8DC` (RC `9B3C81D8…`, EU `2F7CABCE…`), CTS `1805`.

### Packet framing (cziz / czjn / czjk)
- Data: `[flags, ackId, seq] + chunk`; chunk ≤ (MTU − 3) − 3. Writer sends flags=0, ackId=0.
- `seq` 0..255 wrapping; receiver delivers in order, drops dupes.
- Ack: 2 bytes `[0x02, id]` = cumulative ack through `id`; `[0x03, id]` = nack / resend from after `id`.
- A data packet may piggy-back an ack: if `flags & 2`, bytes 0–1 are an ack.
- Sender keeps a window (`fdzs.h()`), resends on ack timeout, disconnects after N failures.

## Stage 4 — Wear OS wire protocol over the stream (`czab.w` / `czab.h` / `cyoy`)

### Framing (`czah.a`, `czah.e`, `cyvg.q`)
```
frame        = uint32 big-endian length || payload
payload      = MessagePiece bytes, or D2D-encrypted(MessagePiece bytes) once UKEY2 is up
MessagePiece (damq) { 1 bytes  root      (serialized RootMessage)
                      2 string digest    base64url-no-pad(SHA1(root))
                      3 int32  piece     1-based
                      4 int32  total
                      5 int32  queueId }
```
Large roots are split into several pieces (`czah.g`), reassembled by digest.

### RootMessage (`damp`) field numbers
4 danr · 5 daiy · 6 dalf · **7 Connect (dakh)** · 8 dany · 9 dans · 10 danq · 11 dals · 12 dalk ·
13 bool · 16 danq · **17 crypto negotiation (dako)** · 18 danq · **19 iOS auth (damd, L2CAP only)** · 20 dakl

### Connect (`dakh`) field numbers (proto2; 1 and 2 required)
1 string nodeId · 2 string displayName · 3 int64 androidId · 4 int32 peer type (watch sends 3) ·
5 int32 wire version · 6 int32 (watch sends 0) · 7 string · 8 string · 9 bool isMigrating ·
10 string migratingFromNodeId · 11 int32

1. **Encryption** (if config requires): UKEY2 → `D2DConnectionContext` (saved session = 73 bytes,
   used for resume HMAC). Google open-source: github.com/google/ukey2. Tag `A2AEncryption`.
2. **Handshake**: both sides send a `Connect` message (`dakh`, inside root `damp` field `f`):
   node id, display name, android id (long), wire version, flags, isMigrating, migratingFrom, etc.
   Peer must start with Connect or the watch aborts.
3. Then the normal data layer: data items, messages, RPCs, assets.

## TODO
- Extract exact protobuf field numbers for `damp` (RootMessage) and `dakh` (Connect) from the
  protobuf-lite `messageInfo` strings.
- Decode `cyoy.b` UKEY2 framing (failed to decompile; use `--show-bad-code`).
- Find how the iOS ConnectionConfiguration (Type=BLE) is created after Stage 1.
- What the companion must send to finish OOBE (Samsung OEM setup, command 14, etc.).
