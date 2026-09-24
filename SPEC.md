# SPEC — LevelDeck

> Derived from `INTENT.md`. If anything here contradicts the intent, the intent wins.
> Status: draft v1.7.1 (English translation of v1.7, no content changes. v1.7 — Phase 5: reconnection, haptics, login item and challenge-response for the `hello`; includes the two-step Mac Keychain read from v1.6.1)

## 1. Summary

Two native Swift and SwiftUI apps that communicate over the local network:

- **macOS agent:** menu bar app that reads and controls system audio with CoreAudio and exposes a service on the local network.
- **iOS client:** app that discovers the Mac over Bonjour, pairs once and shows faders synced in real time.

No external servers, no accounts and no third-party dependencies.

## 2. Decisions on the intent's open questions

| Question | Decision for v1 | Status |
|---|---|---|
| Per-app volume | Out of v1. To be evaluated later (see §10). | Provisional |
| Pairing | QR code shown on the Mac and scanned from the iPhone; the QR key is the PSK for the TLS handshake (§7). | Decided (Phase 3) |
| Widget / Control Center | Out of v1 (see §10). | Provisional |
| Interface style | Mixer with two vertical faders (Output, Input) and a device picker. | Provisional |

## 3. Platforms and requirements

- macOS 14+ and iOS 17+ (allows using the Observation framework and modern SwiftUI APIs).
- Swift 5.10+ or Swift 6 with strict concurrency.
- No external dependencies: only CoreAudio, Network, Security, CryptoKit (HMAC for the `hello`, §8), SwiftUI, AVFoundation (camera for the QR code), CoreImage (QR code generation) and ServiceManagement.
- Languages: English (development and fallback language) and Spanish, in both apps, with String Catalogs (`Localizable.xcstrings` and `InfoPlist.xcstrings` per target). Rules:
  - `LevelDeckKit` doesn't produce UI text. It exposes typed problems (`NetworkIssue` for the network, the protocol's `ErrorCode`) and each app builds its localized message.
  - Never show the `localizedDescription` of a system error (it mixes a localized sentence with technical detail in English) or the `message` of a protocol `error`. Technical detail only appears in Debug builds, untranslated and marked as such.
  - `scripts/check-localizations.py` (part of `verify.sh`) fails if a string the compiler extracts from the apps has no Spanish translation, or if the bundles don't include `es.lproj`.

## 4. Repository structure

```
leveldeck/
├── INTENT.md
├── SPEC.md
├── project.yml        # XcodeGen: source of truth for the project and targets
├── Configs/           # shared xcconfig; Local.xcconfig (Team ID) outside git
├── LevelDeckAgent/    # macOS target (menu bar app)
├── LevelDeck/         # iOS target
└── Packages/
    ├── LevelDeckKit/     # shared Swift Package
    │   ├── Protocol/  # message models (Codable), protocol version
    │   ├── Transport/ # Network.framework wrappers, framing, TLS-PSK
    │   ├── Sync/      # send throttle, fader echo suppression, RTT measurement, backoff
    │   └── Pairing/   # QR format, Keychain storage
    └── LevelDeckAgentKit/  # macOS-only Swift Package, used by the agent
        ├── AgentAudio/     # AudioControlling and AudioModel (state logic, no CoreAudio)
        └── AgentCoreAudio/ # CoreAudioController: real implementation on top of CoreAudio
```

Protocol and transport logic lives in `LevelDeckKit` and is tested in isolation. The agent's audio logic lives in `LevelDeckAgentKit`: `AgentAudio` is tested with a mock of `AudioControlling` and `AgentCoreAudio` is verified by hand against the hardware.

The Xcode project is generated with `xcodegen generate` from `project.yml` and is not versioned (`*.xcodeproj` is in `.gitignore`). There's no `.xcworkspace`: the local package is referenced from `project.yml`. Bundle IDs: `com.renandiaz.LevelDeckAgent` (macOS) and `com.renandiaz.LevelDeck` (iOS).

## 5. macOS agent

### 5.1 Behavior

- Lives in the menu bar (`MenuBarExtra`), with no Dock icon (`LSUIElement = YES`).
- Registers as a login item with `SMAppService.mainApp` (with a menu option to turn it off):
  - It registers itself only once, on the first launch of a Release build (flag in `UserDefaults`). If the user turns it off, it's not turned back on. In Debug it doesn't register itself: it would register the `.app` in DerivedData, whose path changes; the toggle works the same.
  - The menu has the "Open at Login" toggle. The state is re-read when the menu opens, because it can change from System Settings.
  - If macOS asks for approval (`.requiresApproval`), the menu says so and offers "Open Login Items Settings…" (`SMAppService.openSystemSettingsLoginItems()`). A registration failure is shown with a localized message; the detail, only in Debug.
- When the Mac wakes (`NSWorkspace.didWakeNotification`) it restarts the listener, which re-advertises over Bonjour, and re-subscribes the CoreAudio listeners (`AudioModel.restart`). When the network changes (`NWPathMonitor`: the path becomes available again or the interfaces change) it only restarts the listener. Active sessions aren't touched (§5.3).
- The menu (window style, `.menuBarExtraStyle(.window)`) shows: output and input volume sliders with mute, service status, paired devices (with a connected indicator and a revoke button), "Pair New Device…" (opens the QR window, §7), "Open at Login" and Quit.

### 5.2 Audio service (`AudioController`)

Wrapper over CoreAudio, behind a protocol (`AudioControlling`) so mocks can be used in tests.

| Capability | CoreAudio API |
|---|---|
| Default output/input device | `kAudioHardwarePropertyDefaultOutputDevice` / `DefaultInputDevice` (read and write) |
| Device list | `kAudioHardwarePropertyDevices`, filtering by streams in the scope (`kAudioDevicePropertyStreams`) and excluding hidden ones (`kAudioDevicePropertyIsHidden`) |
| UID → device | `kAudioHardwarePropertyTranslateUIDToDevice` (for `setDefaultDevice`) |
| Output volume | `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, output scope |
| Input volume | same with input scope; if not settable, use `kAudioDevicePropertyVolumeScalar` per channel |
| Mute | `kAudioDevicePropertyMute` |
| External changes | `AudioObjectAddPropertyListenerBlock` on volume, mute, default device and device list |

`AudioControlling` exposes, per `Scope`: `channel`, `setVolume`, `setMute`, `devices`, `setDefaultDevice` and change observation.

Rules:

- Volume is expressed as a `Float` normalized to the 0.0–1.0 range.
- Output and input are symmetric: the whole `AudioControlling` API is parameterized by `Scope`.
- Before exposing a control, check with `AudioObjectIsPropertySettable`. Some devices (HDMI, certain USB interfaces) don't allow changing the volume. In that case the control is reported as not settable and the client shows it disabled.
- Volume and mute settability are evaluated separately (there are microphones with volume and no mute, displays with mute and no volume). The agent and the protocol carry `volumeSettable` and `muteSettable`; each control is disabled on its own, without affecting the other.
- A scope's list includes the devices with at least one stream in that scope that aren't hidden (`kAudioDevicePropertyIsHidden`; if the device doesn't expose the property, it counts as visible). Virtual devices (BlackHole, Zoom's and Teams') appear if they meet that. It's sorted by name. A hidden device isn't listed even if it's the active one: the fader shows its name and the picker doesn't mark any.
- `setDefaultDevice` translates the UID with `kAudioHardwarePropertyTranslateUIDToDevice`. Unknown UID, hidden or without streams in the scope → `deviceNotFound` (e.g. it was disconnected between the client seeing the list and choosing it); the agent re-reads the list so the next `state` corrects it. Choosing the one that's already active does nothing. Only the output or input default is changed: the system sounds default (`DefaultSystemOutputDevice`) is left to macOS.
- The list and the channel are read separately: if one read fails, it keeps its last value and the other is applied anyway. When the active device is disconnected, the HAL can fail for an instant when reading the old default, and the list has to be updated regardless.
- A change in `kAudioHardwarePropertyDevices` (connecting or disconnecting headphones, interfaces or monitors) is reported for both scopes. If the active device disappears, the one macOS picks arrives through the default device listener.
- There may be no default device for a scope (e.g. a Mac mini without a microphone). The agent models it as an absent channel and the menu shows "No device". In the protocol, the channel is present with a `null` value (see §8).
- When the default device changes, re-subscribe the listeners to the new device.
- If `coreaudiod` restarts, all listeners become invalid: `kAudioHardwarePropertyServiceRestarted` re-subscribes them and re-reads both scopes. The same happens when the Mac wakes (§5.1).
- Any change, whether from the client or from outside, produces a single state event that's sent to all connected clients.

### 5.3 Network service (`RemoteServer`)

- `NWListener` on a dynamic port, advertised over Bonjour as `_leveldeck._tcp` with the Mac's name and a TXT record `id=<agentId>`. The iPhone picks the key by `agentId`, not by name (which can change or carry a suffix).
- Transport: TCP + TLS with a pre-shared key (PSK) and WebSocket on top (`NWProtocolWebSocket`, `wss://`) to get message framing for free.
- A connection without a valid PSK doesn't get through the handshake. There's no unencrypted channel: pairing (§7) also happens over TLS-PSK, with the key that arrived via the QR code.
- Supports multiple simultaneous clients.
- TCP keepalive on both ends (5 s idle, 3 probes every 2 s): a connection whose other side disappeared without closing (the Mac went to sleep, Wi-Fi was turned off) is considered dead in ~11 s. That way the iPhone starts reconnecting and the Mac doesn't list ghost clients.
- If the listener fails, it's retried with the same backoff as the client (§6.2). `LevelDeckServer.restartListener()` recreates it on demand (on wake or network change, §5.1).
- The transport (Network.framework parameters, framing, server, client and browser) lives in `LevelDeckKit`. The apps only pick a `TransportSecurity` value, in a single file per app (`AgentTransport`, `AppTransport`).

**TLS-PSK (Phase 3).** Verified against the Network.framework API before building:

- Network.framework doesn't negotiate external PSKs in TLS 1.3: there, PSKs are only for session resumption. External PSKs go with TLS 1.2 PSK ciphersuites (RFC 4279/5487). `TransportSecurity.tlsPSK` pins the version to TLS 1.2 (`sec_protocol_options_set_min/max_tls_protocol_version`) and adds `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8, the one Apple's sample uses). Without ECDHE there's no forward secrecy: if someone captures traffic and later obtains that device's key, they can decrypt it. Accepted for the threat we cover (another device on the local network without the key); noted in §10.
- One key per device: the server adds all PSKs with `sec_protocol_options_add_pre_shared_key(key, identity)`, one per paired device (plus the pending one during pairing). In TLS 1.2 PSK the client sends its identity in the `ClientKeyExchange` and the server picks the key with it; an unknown identity or a different key abort the handshake. The identity is the `deviceId` the Mac assigned when pairing (§7). That the server picks correctly among several keys is proven by the test with two clients with different keys connected at the same time (§11).
- Session resumption and tickets disabled on both ends (`sec_protocol_options_set_tls_resumption_enabled/tickets_enabled(false)`): every connection does the full PSK handshake. With resumption, a client in the same process that already had a valid session with that host:port resumes it without proving the key (the loopback rejection tests caught this), and a revoked device could get back in while its ticket lives. Security doesn't depend on the listener restart changing the port.
- The PSK set is fixed when the listener is created. When it changes (a pairing starts or ends, a device is revoked), `LevelDeckServer.update(security:)` restarts the listener with the new set: new port, same Bonjour name. Already-accepted sessions are independent of the listener and stay alive; clients resolve the Bonjour service on every connection, so the port change doesn't affect them. This way we don't depend on any undocumented dynamic key selection behavior.
- Network.framework doesn't expose a connection's negotiated PSK identity, so the server learns it from the `hello`, which carries `deviceId` (§8). Until Phase 4 it was an unverified claim: a paired device could claim to be another and survive its own live revocation (its active connection was listed as the other's and wasn't closed). Since Phase 5 (protocol v3) the `deviceId` is proven with a challenge-response: when the session opens, the agent sends a random `nonce` and the `hello` answers with the HMAC of that `nonce` made with the key of the claimed `deviceId` (§8). The server verifies it against the current PSK set, so a revoked device or an expired QR code don't get through either. Only whoever holds a device's key can present themselves as that device.

**Plaintext transport (development only).** `TransportSecurity.insecurePlaintext` (TCP + unencrypted WebSocket) only exists if the `LEVELDECK_INSECURE_TRANSPORT` compilation flag is defined:

- Since Phase 3 the apps don't use it in any configuration: always TLS-PSK. The flag remains only in `LevelDeckKit`, with `.when(configuration: .debug)`, to inspect the protocol in tests (`PlaintextSmokeTests`). Without a camera (simulator), pairing is done by pasting the code that the QR window shows as text in Debug builds.
- If the flag shows up in a build without `DEBUG`, an `#error` stops the compilation.
- `scripts/verify.sh` checks that the plaintext transport marker is in the package's Debug build (positive control) and doesn't appear in the Release apps.

## 6. iOS client

### 6.1 Screens

1. **Discovery:** list of Macs found with `NWBrowser`. Those already paired (the TXT `agentId` matches a Keychain entry) are marked and connected automatically: the last one used if present, otherwise the first. Unpaired ones offer "Pair" and open the camera (pairing screen, §7).
2. **Mixer:** two large vertical faders (Output, Input), each with a mute button and an indicator of the active device. Tapping the device name opens a picker (sheet with that scope's list and the active one marked); the list changes live while it's open. Choosing one sends `setDefaultDevice` and closes the sheet; there's no optimistic change: the new device shows up when the `state` arrives. A non-settable volume or mute is shown disabled, with a note saying which one. Agent errors are shown as a transient notice (a few seconds): the mixer has already resynced with the latest `state`.
3. **Settings:** paired Macs (with date and a forget option, which deletes the iPhone's key), version and protocol. Forgetting on the iPhone doesn't revoke on the Mac: the Mac keeps listing the device until it's revoked from its menu.

### 6.2 Fader behavior

The first two rules have been implemented since Phase 2 (`SendThrottle`, `EchoGate` and `MixerState` in `LevelDeckKit/Sync`).

- While the user drags, the client is the source of truth: incoming state events for that control are ignored until ~300 ms after release. This avoids jumps, also when another client moves the same control. Only that fader's volume is held back: the rest of the `state` (mute, name, settability, device list, the other channel) is applied anyway. When the window expires, the last volume received during it is applied, so as not to stay out of sync.
- If the default device changes mid-drag (or during the hold), the agent wins and the drag is invalidated: the client discards the pending send and doesn't send any more `setVolume` until the next touch. Otherwise it would keep writing to the new device (e.g. another client switched to headphones and this one would set them to 100 %).
- Sends are limited to at most 30 per second and the final value is always sent on release. The first value goes out immediately; intermediate ones are coalesced and the most recent goes out.
- Light haptic feedback at 0 %, at 100 % and when turning mute on or off.
- Only for the user's own actions: a volume or mute arriving from another client or from the Mac doesn't vibrate. Staying at the edge doesn't repeat the haptic; leaving and coming back does (`FaderBoundary`).
- If the connection is lost, the faders are shown disabled with a "Reconnecting…" indicator and the client retries with backoff: 1 s, 2 s, 4 s, 8 s and then a fixed 10 s (`Backoff`, `ReconnectPolicy`). The counter resets on connect. Each attempt resolves the Bonjour service again, so a port or network change doesn't affect it.
  - It doesn't retry when retrying doesn't help: `notPaired`, `unsupportedVersion` or a rejected TLS handshake (the Mac doesn't recognize the key). Those stay in "Disconnected" with their message.
  - With the connection open, the `challenge` and the first `state` have to arrive within 5 s; otherwise the connection is closed and counts as a failed attempt ("The Mac didn't respond…"). This covers a hung agent or one on another protocol version.
  - When moving to the background, the client closes the connection and pauses retries. When returning to the foreground, it reconnects immediately without waiting for the backoff (`reconnectNow`) and restarts the Bonjour browser if it had failed.
  - The backoff clock is injected, to test the intervals without actually waiting (§11).

### 6.3 Info.plist requirements

They're added in the phase that uses them (local network and Bonjour in Phase 2; camera in Phase 3). All three are translated in `InfoPlist.xcstrings`.

- `NSLocalNetworkUsageDescription`: text explaining it's used to find the Mac.
- `NSBonjourServices`: `_leveldeck._tcp`.
- `NSCameraUsageDescription`: to scan the pairing QR code.

## 7. Pairing

All the logic lives in `LevelDeckKit/Pairing` (`PairingCode`, `PresharedKey`, `PairingManager` on the Mac, `PairedAgents` on the iPhone, Keychain and in-memory stores). The apps only show the QR code, scan and call the manager.

### 7.1 Flow

1. On the Mac: "Pair New Device…" calls `PairingManager.beginPairing`, which generates a random 32-byte key (`SecRandomCopyBytes`) and a new `deviceId` (UUID) for the future iPhone, puts that key into the listener (§5.3) and opens a window with the QR code. The QR code contains `leveldeck-pair:` + base64url of `{ v: 1, agentId, agentName, deviceId, key }`. The window shows the countdown and expires after 2 minutes.
2. On the iPhone: the pairing screen scans the QR code (AVFoundation, `NSCameraUsageDescription`), validates `v` and saves `{ agentId, agentName, deviceId, key }` in the Keychain (`PairedAgents.pair`).
3. The iPhone connects immediately with TLS-PSK (identity `deviceId`, key `key`). The Mac opens the session with `challenge { nonce }` and the iPhone answers `hello { v, deviceName, deviceId, proof }`, with `proof` = HMAC of the `nonce` with `key` (§8). If the handshake succeeds, the proof is valid and the `deviceId` is the pending one, the Mac registers the device (`deviceId`, name, date) and saves the key in its Keychain. The QR window shows the confirmation and closes with "Done". The iPhone closes that first connection and the discovery screen connects as with any paired Mac.
4. From then on, all connections use TLS-PSK with that key. Each paired iPhone has its own key and identity.
5. Revoking a device from the Mac's menu (`PairingManager.revoke`) deletes its key from the Keychain, sends it `error` `notPaired` and closes its active connection, and removes its key from the listener, so it can't connect again either. The iPhone, on receiving `notPaired`, deletes its key and offers "Pair" again. Since each session's `deviceId` is proven (§5.3), the connection that's closed really is that device's: it can't be connected under another's identity.

The key never travels over the network: the QR code is the out-of-band channel. The Mac only saves the key once the iPhone has proven it holds it (the handshake and the `hello` proof).

### 7.2 Pending key lifecycle

| Moment | Where the key lives |
|---|---|
| `beginPairing` → first `hello` | Only in memory (`PairingManager.pending`) and in the listener's PSK set. It isn't written to the Mac's Keychain. |
| `hello` with the pending `deviceId`, before expiry | Moves to the Keychain as a paired device; `pending` is cleared. The listener's PSK set doesn't change (same identity and key), so there's no restart. |
| The QR code expires, is cancelled or the window is closed without pairing | `pending` is discarded and the listener restarts without that key. An iPhone that scanned it is left with a useless key: its handshake fails and the pairing screen says so and deletes the key. |
| Expires mid-process | Expiry is evaluated when the `hello` arrives: if it already passed, it's rejected with `notPaired` and the pending key is discarded (if the listener already restarted without that key, the `hello` proof doesn't verify either: same result). A handshake in flight when the listener restarts may be cut off; in both cases the iPhone shows "the code expired, show a new one". Simple, deterministic rule: there's no grace period. |
| Keychain failure on save | Pairing doesn't happen: it's rejected with `notPaired`, the pending key is cancelled and the menu shows the error. Without persistence there's no "automatic connection afterwards". |
| Second `beginPairing` with one pending | Replaces the previous one; the old QR code is invalidated. |

**Scanned twice.**

- The same iPhone scans the same QR code again (within the window): the iPhone's Keychain has the same entry; the Mac sees it as an already-paired device. Idempotent.
- The same iPhone scans a new QR code from an already-paired Mac (re-pairing): the iPhone replaces its entry (same `agentId`); the Mac is left with the old identity orphaned in its list until it's revoked from the menu. Accepted: it's visible and cleaned up with one click.
- Two iPhones scan the same QR code: the first to send the `hello` gets registered and the window closes. The QR key is already that device's permanent key, so the second would also pass the handshake and show up as the same device (with its own name in the last `hello`). This requires physically seeing the Mac's screen during the 2-minute window: outside the threat we cover (another device on the local network). Possible hardening without the key travelling: derive the final key on both sides with the first TLS session's exporter (`sec_protocol_metadata_create_secret`), which only the two parties to that handshake know. Noted in §10.

### 7.3 Storage

- Both sides use `kSecClassGenericPassword`. The iPhone, in the data protection Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: the identity is per device and doesn't migrate with a backup. The Mac, in the classic login keychain: the data protection one requires the `keychain-access-groups` entitlement with a provisioning profile, which a Personal Team doesn't provide (`errSecMissingEntitlement`); the login keychain only asks for confirmation if the agent's signing identity changes. If the Keychain fails, the apps keep working with what's in memory and show a localized error (technical detail only in Debug); the Mac rejects pairing in that case, so the iPhone isn't left with a key the Mac won't remember.
- Mac: service `com.renandiaz.LevelDeckAgent.pairedDevices`, one item per `deviceId` with `{ device: { id, name, pairedAt }, key }`; and `…identity` with the `agentId`, created the first time.
- iPhone: service `com.renandiaz.LevelDeck.pairedAgents`, one item per `agentId` with `{ id, name, deviceId, key, pairedAt }`.
- Two-step read, the same on both sides: first the service's accounts are listed (`kSecMatchLimitAll` with `kSecReturnAttributes`) and then each one is read (`kSecMatchLimitOne` with `kSecReturnData`). The macOS login keychain doesn't support `kSecReturnData` together with `kSecMatchLimitAll` (it returns `errSecParam`, -50).
- The stores are behind protocols (`PairedDeviceStore`, `PairedAgentStore`) with in-memory implementations for tests.

## 8. Protocol

JSON messages over WebSocket. All of them include `type` and the payload is flat, at the same level as `type`. The protocol is versioned (`v: 3` since Phase 5, which added the `challenge` and the `hello`'s `proof`; v2 changed `settable` to `volumeSettable`), and the version only travels in `hello` and `state`: the handshake negotiates it, and commands don't repeat it.

**Handshake (v3).**

1. When the session opens (TLS-PSK ready), the agent sends `challenge { nonce }`: 32 random bytes (`SecRandomCopyBytes`) in base64url, new on every connection.
2. The client answers `hello { v, deviceName, deviceId, proof }` with
   `proof = HMAC-SHA256(key, "leveldeck-hello-v3" ‖ 0x00 ‖ nonce ‖ utf8(deviceId))` in base64url, where `key` is its pairing key (§7). The label separates this use of the key from any other; the `nonce` has a fixed length and the `deviceId` goes last, so the concatenation is unambiguous.
3. The agent checks, in order: the version (`unsupportedVersion` and close), the proof against the key of that `deviceId` in the current PSK set, with a constant-time comparison (`notPaired` and close if it's missing, doesn't verify or the `deviceId` isn't there), and the pairing (`PairingManager`: name, pending, expiry; §7). Then it answers with `state`.
4. The `nonce` is single-use: a second `hello` in the same session doesn't verify. A session without a valid `hello` within 10 s is closed. On the client side, if the `challenge` and the `state` don't arrive within 5 s, it closes and retries (§6.2).

An invalid proof is answered with `notPaired`, without a new code: if TLS passed with the client's key, the proof only fails when it claims a `deviceId` that isn't its own or when its key is no longer on the Mac. In both cases the right thing is for it to delete the key. With the development plaintext transport (§5.3) there are no keys: `deviceId` and `proof` are optional and aren't verified. A v2 client sends the `hello` without waiting for the `challenge` and receives `unsupportedVersion`; a v3 client against a v2 agent doesn't receive a `challenge` and keeps retrying with "The Mac didn't respond…". Both apps are installed together, so there's no backward compatibility.

### Client → Agent

| type | payload | Effect |
|---|---|---|
| `hello` | `{ v, deviceName, deviceId, proof }` | The client's first message, in response to the `challenge`. `deviceId` is the PSK identity the Mac assigned when pairing (§7) and `proof` the HMAC of the `nonce` (see above); both are omitted only with the development plaintext transport. The agent answers with `state`; with `error` `unsupportedVersion` and closes if `v` doesn't match; with `error` `notPaired` and closes if the proof is missing or doesn't verify, or if `deviceId` is neither paired nor pending. Any other message before `hello` closes the connection. |
| `setVolume` | `{ scope: "output"\|"input", value: 0.0–1.0 }` | Changes the default device's volume. |
| `setMute` | `{ scope, muted: Bool }` | Changes the mute. |
| `setDefaultDevice` | `{ scope, deviceId: String }` | Changes the scope's default device. `deviceId` is a UID from `devices`. If it's no longer available, `error` `deviceNotFound`. Choosing the active one does nothing. |

### Agent → Client

| type | payload |
|---|---|
| `challenge` | `{ nonce }`. First message of every session (v3): 32 random bytes in base64url. Doesn't carry `v`. A `nonce` with another length is a decoding error. |
| `state` | Full snapshot (see below). Sent after `hello` and on any change. |
| `error` | `{ code, message }`. Codes: `unsupportedVersion`, `notSettable`, `deviceNotFound`, `invalidValue`, `notPaired`. `message` is only for diagnostics and isn't localized; the client shows a localized text based on `code`. `notPaired` is followed by the connection closing (in the `hello` or on revocation, §7); the client deletes its key for that Mac. |

```json
{
  "type": "state",
  "v": 3,
  "output": { "deviceId": "…", "deviceName": "MacBook Pro Speakers",
              "volume": 0.62, "muted": false, "volumeSettable": true, "muteSettable": true },
  "input":  { "deviceId": "…", "deviceName": "MacBook Pro Microphone",
              "volume": 0.80, "muted": false, "volumeSettable": true, "muteSettable": true },
  "devices": {
    "output": [{ "id": "…", "name": "…" }],
    "input":  [{ "id": "…", "name": "…" }]
  }
}
```

`volumeSettable` indicates whether the volume can be changed and `muteSettable` whether the mute can be changed; they're independent and the client disables each control separately. A channel with v1's `settable` key doesn't decode.

If there's no default device for a scope, its key is present with a `null` value (`"input": null`). Omitting the key is a decoding error, like any other missing field.

`devices` carries, per scope, the devices that can be chosen (§5.2), sorted by name. The active one is identified by `deviceId`. The list updates on every client when devices are connected or disconnected.

The `deviceId` is the device's UID (`kAudioDevicePropertyDeviceUID`), not the `AudioObjectID`, because the UID is stable across restarts.

A `setVolume` with a `value` outside 0.0–1.0 (or `NaN`) is invalid: it isn't clamped. `LevelDeckKit` refuses to encode it and rejects it when decoding, and the agent answers `error` with `invalidValue`. An unknown `type` or a missing field are also decoding errors and are also answered with `invalidValue`; the connection stays open.

An `error` only goes to the client that sent the command. The `state` resulting from a command goes to everyone, so what one client does is reflected in the others.

The full snapshot is always sent, not diffs. The payload is small and this avoids a whole class of sync bugs. `state` sends are coalesced to at most 30 per second, always with the latest state, and a snapshot identical to the previous one isn't re-sent: that way every change produces a single event even if it arrives through several paths (the client's command and the CoreAudio listener).

## 9. Phases

Each phase ends with something that can be used and tested.

**Phase 0 — Skeleton.** Workspace, two targets, `LevelDeckKit` package with the protocol models and their encoding and decoding tests.
*Done when:* `xcodegen generate` works, both targets build with `xcodebuild` and the `LevelDeckKit` tests pass (`scripts/verify.sh`, which also runs in CI on `macos-15`).

**Phase 1 — Audio on the Mac.** `AudioController` with output and input volume and mute, parameterized by `Scope`, plus listeners. The menu shows a slider with mute for each scope that reflects and controls the system.
*Done when:*
- the menu shows output and input sliders with mute, and they control the system;
- external changes (keyboard, System Settings) move the sliders;
- changing the default device re-subscribes the listeners;
- a non-settable device disables its slider without failing;
- the state logic is tested with a mock of `AudioControlling` and passes in CI; verification with real hardware is a manual checklist in the PR.

**Phase 2 — Local connection (no security, development only).** Server with Bonjour and plaintext WebSocket, which only exists in Debug builds (`LEVELDECK_INSECURE_TRANSPORT` flag, §5.3). The transport and the protocol live in `LevelDeckKit`. The iOS client discovers, connects and shows the output and input faders, each with mute, synced in both directions. `muteSettable` enters the protocol (brought forward from Phase 4). The send throttle (max 30/s, always with the final value) and the fader echo suppression (§6.2) are brought forward from Phase 5. A debug overlay on the iPhone shows the `setVolume` → `state` RTT.
*Done when:*
- the agent advertises `_leveldeck._tcp` and the iPhone discovers it and connects without configuring an IP;
- the output and input faders with mute sync in both directions in under 100 ms on the local network (measured with the RTT overlay);
- dragging the fader doesn't cause jumps or jitter from the echo;
- an integration test in `LevelDeckKit` brings up the server on loopback and verifies `hello` → `setVolume` → `state`, and passes in CI;
- the plaintext transport can't be compiled in Release (verified in CI);
- manual verification on a physical iPhone (local network permission and Bonjour), with a checklist in the PR.

**Phase 3 — Pairing and TLS-PSK.** QR code, Keychain, TLS-PSK and revocation (§7). `TransportSecurity.tlsPSK` is added (TLS 1.2 with a PSK ciphersuite, one key per device, §5.3). Decision on the plaintext mode: the apps stop using it in every configuration; it remains only in `LevelDeckKit` Debug for tests. The `hello` gains `deviceId` and the protocol the `notPaired` code. New screens on the iPhone: pairing (camera) and settings (paired Macs). QR window and device list with revocation in the agent. New strings in English and Spanish.
*Done when:*
- an unpaired iPhone can't connect (the handshake fails with an unknown identity and with a wrong key);
- a paired one connects automatically, without scanning again;
- a revoked one loses its active connection instantly and can't connect again;
- the three criteria are tested with loopback integration tests (`PairingIntegrationTests`) that pass in CI, along with QR expiry and cancellation and active sessions surviving a listener restart;
- manual verification on a physical iPhone (camera permission, scanning, reconnection after reopening the app, revocation with the app open), with a checklist in the PR.

**Phase 4 — Full mixer.** Device picker (`devices` and `setDefaultDevice`), handling of non-settable controls in the client and multiple simultaneous clients. Protocol adjustment: `settable` becomes `volumeSettable` and the version goes up to `v: 2`. (Mute in the client and `muteSettable` were brought forward to Phase 2.) New strings in English and Spanish.
*Done when:*
- tapping the device name on the iPhone opens a picker with that scope's devices and the active one marked; choosing one makes it the Mac's default device;
- the list updates live on every client when headphones, USB interfaces or monitors are connected or disconnected; if the active one disappears, the clients reflect the one macOS picks;
- hidden devices aren't shown; virtual ones (BlackHole, Zoom, Teams) are, if they have streams in that scope;
- a non-settable control is shown disabled without affecting the other (a device with mute and no volume keeps mute usable); connecting an HDMI monitor with no volume control disables the fader without breaking anything;
- choosing a device that disappeared between the list and the tap answers `deviceNotFound` and the client recovers on its own;
- with multiple clients, what one does is reflected in the others, and the one dragging a fader isn't affected by the others;
- the device logic is tested with the `AudioControlling` mock (hot connect and disconnect, active device disappearing, independent flags) and a loopback integration test with two clients, and they pass in CI;
- manual verification with real hardware, with a checklist in the PR.

**Phase 5 — Polish.** Reconnection with backoff, haptics, login item and the option to turn it off. (Echo suppression and the throttle were brought forward to Phase 2.) Hardening of the `hello` with challenge-response: the protocol goes up to `v: 3` (§5.3, §8). New strings in English and Spanish.
*Done when:*
- sleeping and waking the Mac, turning Wi-Fi off and on on either side or changing networks recovers the connection without intervention: the agent re-advertises, re-subscribes the CoreAudio listeners and the iPhone reconnects on its own;
- without a connection, the faders are disabled with "Reconnecting…" and the client retries at 1 s, 2 s, 4 s, 8 s and 10 s; when the app returns to the foreground it reconnects immediately;
- light haptic when reaching 0 % and 100 % while dragging and when turning mute on or off;
- the agent registers as a login item, the menu allows turning it off and, if macOS asks for approval, it says so and opens the login items settings;
- a paired device that claims another's `deviceId` is rejected, and therefore can't survive its own revocation;
- loopback integration tests (`HelloAuthIntegrationTests`, `ReconnectTests`) that pass in CI;
- manual verification with a checklist in the PR: sleep and wake the Mac, Wi-Fi off and on on each side, app in the background for several minutes and back to the foreground, login item after restarting the Mac.

## 10. After v1

- **Per-app volume.** Requires a virtual audio driver (HAL plug-in / AudioServerPlugIn style) that captures each app's audio. Alternatives: write our own (high cost and more complex signing), integrate with BackgroundMusic (open source) or control SoundSource if it exposes automation. Do a spike before deciding.
- **Widget / Control Center (iOS 18+).** Control Widgets run short-lived App Intents and can't keep a connection open. Each action would have to connect, do the TLS handshake, send and close. We need to measure whether the resulting latency is acceptable.
- **Mac → Mac or iPad.** The client is SwiftUI, so porting it to iPad is almost free.
- **Harden pairing.** (a) Derive the final key from the first TLS session's exporter so the QR code is truly single-use (§7.2). (b) Forward secrecy: try `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (0xCCAC) in Network.framework; if it negotiates, prefer it. (c) Bind the `hello` proof to the TLS session: include in the HMAC a value from that connection's exporter (`sec_protocol_metadata_create_secret`) in addition to the `nonce`. Today the proof isn't bound to the channel; a relay would require the victim device to sign someone else's `nonce`, and the victim can't complete a handshake with the attacker because they don't share a key, so it isn't exploitable under our threat model. None of the three changes the user flow.
- ~~**Verify the `hello`'s `deviceId`.**~~ Done in Phase 5 with challenge-response (§5.3, §8).

## 11. Testing

- **LevelDeckKit:** unit tests for protocol encoding (including `challenge` and the `hello`'s `proof`), the QR format (`PairingCode`, `PresharedKey`), `HelloProof` (fixed vector, different key, different `deviceId`, different `nonce`, truncated proof), the `hello` policy in `PairingManager` (pending, known, unknown, store failure), throttle and coalescing logic, `Backoff` and `FaderBoundary`.
- **AudioController:** behind `AudioControlling`. Mock-based tests for the state logic (including device logic: hot connect and disconnect, active device disappearing, device disappearing before the tap, list read errors and independent flags) and a manual verification against the real hardware (CoreAudio can't be usefully mocked at a low level; the hidden and stream filters are verified there).
- **Integration:** tests that bring up the `LevelDeckKit` server on loopback with TLS-PSK. `LoopbackIntegrationTests` verifies the full `hello` → `setVolume` → `state` cycle, `setMute`, errors and two clients with different keys at the same time (fixed test keys, no `authorizer`). Since Phase 4, with two clients: the device list and selection reach both, so does the active device disappearing, `deviceNotFound` only reaches the one who asked, and the one dragging (with its `MixerState`) isn't moved by the other's changes and is invalidated if the other changes device. `PairingIntegrationTests` covers Phase 3 with `PairingManager` and an in-memory store: a paired device connects and reconnects, unknown identity and wrong key are rejected in the handshake, a `hello` without `deviceId` is rejected, a revoked device loses its active connection and doesn't come back, a cancelled or expired QR code doesn't work, and an active session survives a listener restart. `PlaintextSmokeTests` keeps the Debug plaintext transport alive. Since Phase 5, `HelloAuthIntegrationTests` (with `PairingManager`): a client that passes TLS with its own key but claims another's `deviceId` is rejected with `notPaired` and the other stays connected; a device trying to disguise itself can't survive its own revocation; a `hello` without a proof or with a proof recycled from another session is rejected; a client that doesn't answer the `challenge` is closed by timeout. `ReconnectTests` uses an injected manual clock: retries go out exactly at 1 s, 2 s, 4 s, 8 s, 10 s and 10 s (and not an instant earlier), `reconnectNow` skips the wait and resets the counter, the client reconnects on its own when the agent comes back on its port (and the backoff starts again from 1 s), and it doesn't retry after `notPaired`. The only thing that runs in real time is the attempt failing or connecting on loopback.
- **AudioModel:** `restart` (on wake) re-subscribes the listeners and re-reads both scopes, tested with the mock.
- **Real Keychain:** `KeychainStoreTests` (macOS only) uses `KeychainPairedDeviceStore` against the login keychain, with a unique service per test that's deleted at the end: empty store without error, devices sorted by `pairedAt` with their keys, `agentId` round trip and revocation of a single device.
- **Manual checklist per phase,** based on the "Done when" criteria.

## 12. Distribution

Direct installation from Xcode on my devices. With a free Apple ID, iOS signing expires after 7 days. With a paid developer account you can use TestFlight or one-year signing. The macOS agent is signed locally and doesn't need notarization for personal use.
