# Handoff: adding the encryption layer

This project pairs a Samsung Galaxy Watch4 (Wear OS 5) with an iPhone by speaking the
iOS-companion protocol that still ships inside the watch's own firmware. Everything needed
to reach the encrypted stage is mapped in `research/PROTOCOL_NOTES.md`. The one missing
piece is the encryption layer, which needs to be added by a developer using Google's official
library. Please don't hand-roll it.

## The job

Implement `LinkEncryption` (`WearLink/Sources/WearLink/LinkEncryption.swift`) as the
**UKEY2 responder**, backed by **https://github.com/google/ukey2** (Apache-2.0).

What the watch expects (details in PROTOCOL_NOTES Stage 4a):
- Watch is the initiator; the iPhone app is the responder.
- Handshake cipher `P256_SHA512`, next protocol `AES_256_CBC-HMAC_SHA256`.
- After the handshake: D2DConnectionContextV1 for every frame payload in both directions.
- Handshake messages travel inside RootMessage field 17 (`dako`, sub-field 1).
- On first pairing the watch shows a verification code (16 bytes, base64, no padding)
  for the user to approve within 30 seconds; the app should show the same code.

## Suggested approach

1. Build the library's C++ implementation (`src/main/cpp`) for iOS as a static library or
   XCFramework, or wrap it in a Swift package with a small C/Obj-C++ shim.
2. Write a class conforming to `LinkEncryption` that drives the library's responder
   handshake and connection context.
3. Add tests that run the library's initiator against your responder in-process and check
   both sides agree on the verification code and can exchange messages.
4. Keep the library's own tests passing; pin the exact commit you vendor.

## Security expectations

- Use the official library unmodified; record the commit hash.
- Never log key material, verification codes or decrypted payloads.
- Any authentication or sequence failure drops the connection; no fallback to plaintext.
- Store the resumable session (if implemented) only in the iOS Keychain,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

## Before anyone factory-resets a watch to test

- `swift test` passes in `WearLink/`, including the encryption tests.
- The pairing tester has completed Stage 1 against a watch on its setup screen.
- You have a way back if setup stalls (for example, an Android phone to re-pair with).

## Not to publish

`research/apks`, `research/unz`, `research/src` (proprietary decompiled code) and
`research/bt_dumpsys.txt` / `research/snapshot-before-reset` (personal device data) are
git-ignored. Keep them that way.
