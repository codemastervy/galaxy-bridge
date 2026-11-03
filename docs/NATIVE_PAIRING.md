# Native pairing (no Android phone): status and tester

Goal: set up a factory-reset Wear OS watch directly with an Apple device, using the iPhone-companion
mode built into the watch's own firmware. Protocol details: [research/PROTOCOL_NOTES.md](../research/PROTOCOL_NOTES.md).

## Status by stage

| Stage | What happens | Status |
|---|---|---|
| 1a Setup discovery | Find the watch on its setup screen (setup pairing GATT service) | Implemented; verified on hardware that a set-up watch is correctly reported as *not* on its setup screen |
| 1b Capabilities | Write `WearPairingCapabilities {os: iOS, bleRole: 2}`; the encrypted write forces Bluetooth bonding | Implemented; needs a watch on its setup screen to verify |
| 1c Bond | OS pairing prompt on both screens; record saved to Keychain | Implemented; needs a watch on its setup screen |
| 3a–3c Clockwork | Watch connects to our GATT service, reads confirm/decommission, subscribes, writes ATT size | Implemented (`ClockworkSession`, `wearlink-pair serve`); Mac publishing verified; unit-tested |
| 4 Stream and frames | Packet link with acks, length-prefixed MessagePiece frames, multi-piece reassembly, digest check | Implemented and unit-tested |
| **4a Encryption** | UKEY2 handshake (watch = initiator), then D2D-encrypted frames | **Not implemented.** The session stops here, without replying or falling back to plaintext |
| 4b Connect and beyond | Encrypted Connect exchange, then the setup flow (terms, settings, "setup complete") | Not implemented; unknown until 4a works |

## The tester

```sh
cd WearLink
swift build
.build/debug/wearlink-pair scan                  # list watches; [setup screen] marks ones ready
.build/debug/wearlink-pair setup <id-or-name> --json stage1.json
.build/debug/wearlink-pair serve --json stage3.json
.build/debug/wearlink-pair status | forget       # Keychain pairing record
```

Every step prints one line: `✓` passed, `…` started, `✗` failed, `■` blocked (a known missing
piece). The end of each run prints the furthest stage passed and the exact stopping point. `--json`
writes the same events for bug reports. Events contain sizes, field numbers and state names only:
no payload bytes, keys or verification codes (a unit test checks this).

Exit codes: 0 passed, 1 failed, 2 Bluetooth unavailable/denied, 3 blocked.

## Security properties

- All GATT characteristics require an encrypted, bonded link.
- Only packet-level acks are sent before encryption; the session never answers the watch's
  handshake or any message in plaintext, and refuses a plaintext Connect.
- Any failed authentication, digest mismatch or malformed frame stops the session.
- Pairing records use the data-protection Keychain, `AfterFirstUnlockThisDeviceOnly`, non-syncing.

## Outstanding blockers

1. **Encryption layer (Stage 4a).** Needs a `LinkEncryption` conformance backed by Google's UKEY2
   library, installed where `ClockworkSession` is created. See [HANDOFF.md](../HANDOFF.md). A
   developer needs to add it; it isn't written in this repo.
2. **The setup flow after encryption (Stage 4b+).** What the watch requests after Connect isn't known
   yet. It can only be captured from a reset watch once Stage 4a works, using `serve`'s diagnostics.
3. **Hardware verification of Stage 1.** Needs a watch on its setup screen, which means a factory
   reset. Have an Android phone available to set the watch up again if a test stalls.
4. **Mac as the companion.** After Stage 1 the watch connects back to the device it bonded with.
   Whether it reconnects to a Mac's advertised service as reliably as to an iPhone is unverified.
