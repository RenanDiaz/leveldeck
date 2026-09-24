# SPEC — LevelDeck

> Derived from `INTENT.md`. If anything here contradicts the intent, the intent wins.
> Status: **Part I (v1)** — v1.7.1, implemented through Phase 5 (reconnection, haptics, login item and challenge-response for the `hello`; includes the two-step Mac Keychain read from v1.6.1; v1.7.1 is the English translation, no content changes). **Part II (v2)** — draft 2.0 under review (§13–§22): per-device strips, protocol v4, universal app, design audit and per-app volume spike.

## 1. Summary

Two native Swift and SwiftUI apps that communicate over the local network:

- **macOS agent:** menu bar app that reads and controls system audio with CoreAudio and exposes a service on the local network.
- **iOS client:** app that discovers the Mac over Bonjour, pairs once and shows faders synced in real time.

No external servers, no accounts and no third-party dependencies.

## 2. Decisions on the intent's open questions

| Question | Decision for v1 | Status |
|---|---|---|
| Per-app volume | Out of v1. Spike with go/no-go in v2 (§20). | Provisional |
| Pairing | QR code shown on the Mac and scanned from the iPhone; the QR key is the PSK for the TLS handshake (§7). | Decided (Phase 3) |
| Widget / Control Center | Out of v1 (see §10). | Provisional |
| Interface style | Mixer with two vertical faders (Output, Input) and a device picker. In v2 it becomes one strip per device (§13). | Provisional |

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

- **Per-app volume.** → v2, §20. The driver-free path is Core Audio process taps (macOS 14.4+); Phase 10 is a spike with a go/no-go. What v1 said here (a virtual AudioServerPlugIn driver, BackgroundMusic, SoundSource) is kept as a discarded alternative in §20.2.
- **Widget / Control Center (iOS 18+).** Control Widgets run short-lived App Intents and can't keep a connection open. Each action would have to connect, do the TLS handshake, send and close. We need to measure whether the resulting latency is acceptable.
- **Mac → Mac or iPad.** iPad → v2, Phase 8 (§17). A Mac client stays out of scope.
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

---

# Part II — v2

> Derived from the "v2" section of `INTENT.md`, which is a draft. Status: **draft 2.0** for review. The pending decisions are in §21, each with a recommended option; until they're made, the spec assumes the recommended one.
>
> Part I (§1–§12) describes v1 as it shipped and remains the reference for everything v2 doesn't change: pairing (§7), TLS-PSK (§5.3), challenge-response for the `hello` (§8), reconnection (§6.2), localization (§3) and testing (§11). Where v2 replaces something in Part I, it says so explicitly.

## 13. v2 summary

Three structural changes and one conditional:

1. **Per-device strips.** The agent observes and controls volume and mute for every output and input device, not just the default. The state goes from "two channels plus a list of names" to "one strip per device and scope, plus the default for each scope". The protocol moves to **v4** (§15). The client's mixer and the Mac's menu show one strip per device.
2. **Universal app.** The iOS target becomes iPhone and iPad, with a layout for regular width (landscape, Stage Manager, resizable windows) and today's compact layout for iPhone and Slide Over (§17).
3. **Revised interface structure.** An audit of the current UI on iPhone, iPad and the Mac's menu, with proposals per area (§18). The spec fixes the structure; the visual design is iterated separately.
4. **Per-app volume (conditional).** A spike on Core Audio process taps (macOS 14.4+) that ends in a documented go/no-go. Only if it's a "go" is there an implementation phase (§20, Phases 10 and 11).

Unchanged: everything native and local, no third-party dependencies, shared logic in `LevelDeckKit` and `LevelDeckAgentKit`, English and Spanish text, a complete snapshot in every `state`, and the security model from Phase 3 and Phase 5 as is.

### 13.1 New vocabulary

| Term | What it is |
|---|---|
| **Strip** | The state of one device in one scope: `deviceId`, name, transport type, volume, mute and the settability of each. A device with both input and output streams (a USB interface) yields two strips, one per scope, with independent volumes: in Core Audio, volume is a per-scope property of the same object. |
| **`StripID`** | `(scope, deviceId)`. It's the key for everything that was keyed by `Scope` in v1: echo gates, throttles, RTT meter, listeners. |
| **Default** | The device macOS uses for the scope (`kAudioHardwarePropertyDefault{Output,Input}Device`). In v2 it's a mark on a strip, not a separate strip. |
| **Hidden strip** | A strip the client doesn't show, by user preference. It's client state, per paired Mac; the agent knows nothing about it. |

## 14. macOS agent in v2

### 14.1 Behavior

Everything in §5.1 stays (menu bar, login item, wake, network change). The menu's content changes:

- An **Output** section and an **Input** section, each with one strip per device: name, icon by transport, volume slider and mute button. The default's strip is marked, and the others offer "Use as Default" (context menu or secondary button; the exact form is a proposal in §18.3).
- Sections can be collapsed. They start expanded; the state is remembered in `UserDefaults`. Past ~6 strips per section the menu grows to a maximum height and scrolls (`ScrollView`), so it never exceeds the screen.
- Service status, paired devices, pairing, login item and Quit stay as they are. The proposals to move them to a settings window are in §18.3; they're not part of this phase.

### 14.2 Per-device audio service (`AudioControlling` v2)

The API is parameterized by `StripID` instead of `Scope`:

```swift
public struct StripID: Hashable, Sendable { public var scope: Scope; public var deviceId: String }

public struct AudioStrip: Sendable, Equatable {
    public var id: StripID
    public var deviceName: String
    public var transport: DeviceTransport   // builtIn, bluetooth, usb, hdmi, displayPort, thunderbolt, airPlay, virtual, aggregate, other
    public var volume: Float                // 0.0–1.0
    public var muted: Bool
    public var volumeSettable: Bool
    public var muteSettable: Bool
}

@MainActor public protocol AudioControlling: AnyObject {
    func strips(_ scope: Scope) throws(AudioControlError) -> [AudioStrip]        // every strip in the scope, sorted by name
    func strip(_ id: StripID) throws(AudioControlError) -> AudioStrip?           // one strip; nil if the device no longer exists
    func defaultDevice(_ scope: Scope) throws(AudioControlError) -> String?      // deviceId, or nil if there is none
    func setVolume(_ value: Float, strip: StripID) throws(AudioControlError)
    func setMute(_ muted: Bool, strip: StripID) throws(AudioControlError)
    func setDefaultDevice(_ deviceId: String, scope: Scope) throws(AudioControlError)
    func startObserving(_ onChange: @escaping @MainActor (AudioChange) -> Void)
    func stopObserving()
}

public enum AudioChange: Sendable, Equatable {
    case strip(StripID)          // volume, mute or data source of one strip
    case defaultDevice(Scope)    // the scope's default changed
    case deviceList              // something was plugged or unplugged: re-read the strips of both scopes
    case controlsChanged(deviceId: String) // the device's controls changed: re-resolve its strips
    case serviceRestarted        // coreaudiod restarted: re-read everything
}
```

Rules, in addition to those in §5.2 that still apply (0–1 normalization, `AudioObjectIsPropertySettable`, independent `volumeSettable` and `muteSettable`, hidden and streamless devices filtered out, UID as identity, only the output and input defaults and not the system sounds one):

- **Which devices get a strip.** The same ones as v1's list (§5.2): at least one stream in the scope and not hidden. A device with neither volume nor mute control still gets a strip, with both controls disabled: it's still a destination that can be made the default.
- **Per-device volume, not just the default's.** `VolumeControl.resolve(device, scope)` already works on an arbitrary `AudioObjectID`, so per-strip reads and writes reuse the same resolution (virtual main volume → `VolumeScalar` on the main element → `VolumeScalar` per channel). What Phase 6 has to verify against hardware is that `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` responds on devices that aren't the default (see §14.4).
- **Data source.** On Intel Macs before the T2 chip, "Built-in Output" had two data sources (internal speakers and headphones) with volume stored per source. `kAudioDevicePropertyDataSource` is observed per strip and a change fires `.strip(id)`, which re-reads volume and mute. On T2 and Apple Silicon Macs, speakers and jack are separate devices and the change arrives as a device-list add/remove, so this only covers old hardware: it's cheap and it isn't exposed in the protocol.
- **An unknown `deviceId`** in `setVolume` or `setMute` (unplugged between the `state` and the command) throws `.deviceNotFound(scope)`; the agent re-reads the list and the next `state` corrects it. Same as `setDefaultDevice` in v1.
- **Device without volume** (`volumeSettable == false`): `setVolume` throws `.notSettable`; the client shows it disabled and doesn't send it. Same for mute.

### 14.3 Observing every device at once

v1 had four system listeners and two or three per scope on the default device. v2 has listeners on every device that has a strip:

| Object | Property | Event |
|---|---|---|
| System | `kAudioHardwarePropertyServiceRestarted` | `.serviceRestarted` |
| System | `kAudioHardwarePropertyDevices` | `.deviceList` |
| System | `kAudioHardwarePropertyDefaultOutputDevice` / `DefaultInputDevice` | `.defaultDevice(scope)` |
| Each device × scope | the volume addresses `VolumeControl.resolve` chose (1, or N per channel) | `.strip(id)` |
| Each device × scope | `kAudioDevicePropertyMute` (if present) | `.strip(id)` |
| Each device × scope | `kAudioDevicePropertyDataSource` (if present) | `.strip(id)` |
| Each device | `kAudioDevicePropertyDeviceIsAlive` | `.deviceList` (the device is going away; the list confirms it) |
| Each device | `kAudioDevicePropertyDeviceHasChanged`, `kAudioObjectPropertyControlList` | `.controlsChanged(deviceId)`: the device's controls appeared or disappeared. `VolumeControl.resolve` runs again for each scope of the device and **only** those strips' listeners are re-subscribed. Apple documents `DeviceHasChanged` for exactly this: "clients should re-evaluate everything they need to know about the device, particularly the layout and values of the controls". |
| Each device | `kAudioObjectPropertyName` | `.strip(id)` for each scope of the device (name edited in Audio MIDI Setup) |

The block and queue each listener was registered with are stored and passed unchanged to `AudioObjectRemovePropertyListenerBlock` (v1 already does this with `Listener.block`); a re-created block doesn't match and the listener stays alive.

Alternative evaluated and discarded: a single wildcard listener per device (`kAudioObjectPropertySelectorWildcard`), as SimplyCoreAudio does. Fewer registrations, but it fires for every property of the device (`DeviceIsRunning`, buffer size, stream format) and forces filtering by selector in every callback. With precise addresses every event already says what to re-read. If Phase 6 measurements show per-address registration is slow with many devices, the wildcard is plan B and doesn't change the `AudioControlling` API.

How it scales:

- **Count.** A typical Mac has between 4 and 15 devices (speakers, microphone, a monitor, Bluetooth headphones, an interface, BlackHole in two or three variants, Zoom, Teams). With 3–5 listeners per strip plus 3 per device that's 40–100 registered blocks. Apple documents no limit and no per-count cost; what is documented is that each registration retains its block and queue until removed, so the real cost is memory and the discipline of removing them. BackgroundMusic registers four addresses per device and SimplyCoreAudio one wildcard per device, on every device, with no reported problems. Logged as a risk to measure in Phase 6 (§14.4), not as a known problem.
- **Subscription by difference.** On `.deviceList`, listeners aren't torn down and recreated wholesale: the difference between the previous and new strip sets is computed, listeners for strips that disappeared are removed and listeners for new ones are added. Strips that remain keep their listeners. This avoids losing an event between "remove all" and "add all again", and makes plugging a device O(1) in listeners, not O(N).
- **Targeted reads.** Each event re-reads only what it names: `.strip(id)` re-reads that strip (3–5 HAL calls); `.defaultDevice(scope)` re-reads one `AudioObjectID`; `.deviceList` re-reads the UID lists of both scopes and the new strips; `.serviceRestarted` and `restart()` (wake) re-read and re-subscribe everything. v1 re-read list and channel on every event; in v2, re-reading everything on every event would be O(N) HAL calls per fader movement, and it isn't needed.
- **One event per change.** `AudioModel.onChange` still fires once per applied change; the server still coalesces at 30/s and drops identical snapshots (§16.1). Bursts (wake: every device reappears within ~1 s and fires dozens of listeners) produce dozens of targeted re-reads but a handful of `state` messages, thanks to coalescing.
- **Listener on a dead device.** When a device is unplugged, `DeviceIsAlive` goes to 0 and `kAudioHardwarePropertyDevices` changes; the order between the two isn't documented, so subscription by difference is driven by the list, and `DeviceIsAlive` only brings the re-read forward. `AudioObjectRemovePropertyListenerBlock` on the dead object returns `kAudioHardwareBadObjectError` and is harmless. v1's pattern (`activeListeners` with IDs, blocks ignored once inactive, `remove` ignoring the error) is kept as is. A Bluetooth device that comes back may have a different `AudioObjectID`: everything is indexed by UID, as in v1.
- **Main actor.** Listeners keep delivering on the main queue and `AudioControlling` stays `@MainActor`, as in v1. Reading a strip is a few microsecond-level HAL calls. Writing to Bluetooth devices can take longer (the driver negotiates with the peripheral): Phase 6 measures it and, if a write consistently exceeds ~5 ms, volume writes move to their own queue (an `AudioHAL` actor) while `AudioModel` stays on the main actor. That's a decision deferred to the measurement, not a design decision today.

### 14.4 Risks to verify against hardware (Phase 6)

None of this can be tested with the mock; it goes in Phase 6's manual checklist with an explicit success criterion:

| Risk | How it's verified | If it fails |
|---|---|---|
| `VirtualMainVolume` doesn't respond on a non-default device. **Low risk:** the property is per `AudioObject` and its documented semantics (applies to the master control or to the preferred layout's channels) don't mention the default; SimplyCoreAudio, eqMac and dozens of apps read and write it on arbitrary devices with `AudioObjectGetPropertyData`. What Apple doesn't document is that it works outside the deprecated `AudioHardwareService` API; it's verified by usage, not by a document. | Read and write the internal speakers' volume while headphones are the default | `VolumeControl.resolve` already falls back to `VolumeScalar`; if that fails too, the strip ends up with `volumeSettable: false` and the device is documented |
| Writing volume to an inactive Bluetooth device doesn't persist or is slow | Set AirPods to 30 % while not default, make them default, check they stayed at 30 %; time `setVolume` | Show the value the HAL returns (never the one sent) and, if slow, move writes off the main actor (§14.3) |
| Listener burst on wake produces repeated `state` messages or a flickering menu | Sleep with 8+ devices, wake, count `state` messages sent (Debug log) | Coalescing and dedup already exist; if the problem is the re-read, add a 50 ms grouping window in `AudioModel.refresh` |
| A device with per-channel volume reports different values per channel | USB interface with separate L/R: move one channel from Audio MIDI Setup | v1 averages and writes the same value to all; kept and documented |
| Aggregate and Multi-Output devices | Create one in Audio MIDI Setup with two devices | macOS gives them no volume control (the controls in Sound Settings are inactive): the strip appears with `transport: aggregate` and both controls disabled. Controlling their sub-devices is out of v2. |
| A device's controls change without the list changing (a driver adding a control, `DeviceHasChanged`) | BlackHole: change the driver's configuration; a monitor that gains mute when switching inputs | `.controlsChanged` re-resolves and re-subscribes only that strip |

## 15. Protocol v4

Still JSON over WebSocket with TLS-PSK, flat payload, `v` only in `hello` and `state`, a complete snapshot in every `state`, no diffs. The handshake (`challenge` → `hello` with `proof`) is identical to v3 (§8): v4 touches nothing security-related. As in v1, both apps are installed together and there's no backward compatibility: a v3 client gets `unsupportedVersion`.

### 15.1 `state`

```json
{
  "type": "state",
  "v": 4,
  "defaults": { "output": "AppleUSBAudioEngine:…", "input": null },
  "strips": {
    "output": [
      { "deviceId": "BuiltInSpeakerDevice", "deviceName": "MacBook Pro Speakers", "transport": "builtIn",
        "volume": 0.62, "muted": false, "volumeSettable": true, "muteSettable": true },
      { "deviceId": "AppleUSBAudioEngine:…", "deviceName": "Scarlett 2i2", "transport": "usb",
        "volume": 1.0, "muted": false, "volumeSettable": false, "muteSettable": false }
    ],
    "input": [
      { "deviceId": "BuiltInMicrophoneDevice", "deviceName": "MacBook Pro Microphone", "transport": "builtIn",
        "volume": 0.80, "muted": false, "volumeSettable": true, "muteSettable": true }
    ]
  }
}
```

- `strips.output` and `strips.input` carry **every** strip in the scope, sorted by name (`localizedStandardCompare`): the same devices as v1's `devices` list plus their state. An empty list is valid (Mac mini without a microphone → `"input": []`).
- `defaults.<scope>` is the default's `deviceId`, or `null` if there is none. Always present. When not `null` it must match a strip in the scope; if it doesn't (hidden active device, §5.2), the client shows "Default: <no strip>" and marks none. It's the same case that in v1 showed the name without marking the picker.
- `transport` is a closed enum: `builtIn`, `bluetooth`, `usb`, `hdmi`, `displayPort`, `thunderbolt`, `airPlay`, `virtual`, `aggregate`, `other`. It comes from `kAudioDevicePropertyTransportType`; anything unmapped is `other`. It's for the strip's icon; the client makes no decisions with it.
- The v3 keys `output`, `input` and `devices` **go away**. A `state` with them and without `strips` doesn't decode.
- Size rule: a strip is ~170 bytes; a Mac with 12 strips produces a `state` of ~2.3 KB. At 30/s that's ~70 KB/s to each client. It's the price of keeping the complete snapshot and it's accepted (§16.1 has the table).

### 15.2 Client → Agent

| type | payload | Effect |
|---|---|---|
| `hello` | `{ v: 4, deviceName, deviceId, proof }` | Unchanged except `v`. |
| `setVolume` | `{ scope, deviceId, value: 0.0–1.0 }` | Changes that strip's volume. `deviceId` is **required** (decision §21 D2). Unknown strip → `deviceNotFound`. `volumeSettable: false` → `notSettable`. `value` out of range or `NaN` → `invalidValue`, no clamping, as in v1. |
| `setMute` | `{ scope, deviceId, muted }` | Same, for mute. |
| `setDefaultDevice` | `{ scope, deviceId }` | Unchanged (§8). |

### 15.3 Agent → Client

`challenge` and `error` are unchanged. The error codes are the same five; `deviceNotFound` now also applies to `setVolume` and `setMute`.

### 15.4 Rules that carry over

Repeated here so a Part II reader doesn't have to go back to §8 for the essentials:

- An `error` goes only to whoever sent the command; the resulting `state` goes to everyone.
- `state` messages are coalesced to at most 30/s, always with the latest snapshot, and a snapshot identical to the previous one isn't resent.
- A message that can't be decoded is answered with `invalidValue` and the connection stays open.
- The `deviceId` is the UID (`kAudioDevicePropertyDeviceUID`), stable across reboots.

### 15.5 Models in `LevelDeckKit/Protocol`

`ChannelState` and `DeviceList` are retired. In come `StripID`, `Strip` (the protocol projection of `AudioStrip`), `DeviceTransport`, `StripList` (`output`/`input` with a subscript by `Scope`, like `DeviceList`) and `Defaults`. `StateSnapshot` becomes `{ defaults, strips }` with `subscript(_ id: StripID) -> Strip?` and `func strips(_ scope: Scope) -> [Strip]`. `ProtocolVersion.current = 4`. The encoding tests in `AgentMessageTests` and `ClientMessageTests` are rewritten for the new shape, including: empty `strips` per scope, `defaults` with `null`, `defaults` matching no strip (decodes; the rule is the client's), unknown `transport` (decoding error: the enum is closed and both apps are installed together), and `setVolume` without `deviceId` (decoding error).

## 16. Synchronization at scale

v1 synchronized two controls. v2 synchronizes 2N, with N variable and with the possibility of moving several at once (multitouch on the iPad, several clients). The mechanisms are the same (`SendThrottle`, `EchoGate`, `MixerState`, server coalescing); the key changes (from `Scope` to `StripID`) and rules are added so the cost doesn't grow with N where it shouldn't.

### 16.1 Agent side

| Mechanism | v1 | v2 |
|---|---|---|
| Re-read after a HAL event | list + channel of the scope | only what the event names (§14.3) |
| Snapshot construction | on every `onChange` (`currentState()`) | **lazy:** `onChange` marks `dirty`; the snapshot is built once when the throttle fires (max 30/s), not once per listener. In a burst of 40 events in 100 ms, 3 snapshots are built, not 40. |
| Coalescing and dedup | 30/s, identical snapshot not resent | same; dedup compares `StateSnapshot` by `Equatable` (O(N) struct comparisons, trivial) |
| JSON encoding | one per `state` sent | same: one per 33 ms tick, shared across all sessions (encode once and send the same `Data` to every client; today `MessageConnection.send` encodes per session, this changes to encoding before the loop) |
| Incoming commands | 1 client × 1 fader × 30/s | K clients × F fingers × 30/s. Each command is a microsecond-level HAL write (except Bluetooth, §14.3). With 3 clients and 2 fingers each that's 180 writes/s: no problem. Not limited on the agent side; the limit is each client's throttle. |

`state` size by strip count (compact JSON with sorted keys, no whitespace):

| Total strips | Approx. size | At 30/s |
|---|---|---|
| 2 (v1) | 0.5 KB | 15 KB/s |
| 8 | 1.6 KB | 48 KB/s |
| 16 | 3.0 KB | 90 KB/s |
| 32 (extreme case, many virtual devices) | 5.8 KB | 175 KB/s |

All of it fits comfortably on local Wi-Fi (tens of MB/s) and 30/s is only reached while someone is dragging. If in Phase 7 the RTT measured with 16+ strips exceeds v1's 100 ms, the first lever is lowering the `state` rate to 20/s for clients that aren't dragging (the echo `state` to the one dragging can stay at 30/s); the second is excluding `deviceName` and `transport` from the periodic snapshot. Neither is implemented up front: they're the exits if the measurement calls for them.

### 16.2 Client side

- **`MixerState` per strip.** `channels: [Scope: ChannelState]` becomes `strips: [StripID: Strip]`; `gates`, `heldRemoteVolume` and `invalidatedDrags` are indexed by `StripID`. `apply(snapshot)` walks the snapshot's strips: for the strip being dragged (or just released) it holds the volume and applies the rest; the others are applied as is. A strip that was there and no longer arrives is removed (and if it was being dragged, the drag is invalidated, see below). `devices` goes away: the device list now **is** the strips.
- **Drag invalidation.** v1's rule ("if the default changes mid-drag, the agent wins") stops making sense: the command carries `deviceId`, so changing the default redirects nothing. The new rule is simpler: a drag is invalidated if **its strip disappears from the snapshot** or if its `volumeSettable` becomes `false`. Both are device changes, not default changes. The pending send is cancelled and nothing more is sent until the next touch, as in v1.
- **Throttle per strip.** One `ThrottledSender<Float>` per strip being dragged, created on demand and discarded on release (not one per existing strip: with 30 strips that would be 30 idle timers). 30/s per strip. With multitouch, F fingers produce F × 30/s: accepted (§16.1). No global client cap; if one were wanted, the place is `MixerModel`, not `SendThrottle`.
- **Multitouch.** On the iPad, several strips can be dragged at once (`VerticalFader` already keeps its own `dragStart`; gestures on different strips are independent in SwiftUI). On the iPhone too, even if in practice it isn't used. Each strip has its own echo gate, so two fingers don't step on each other.
- **RTT per strip.** `RoundTripMeter` indexes pending sends by `StripID`; the Debug overlay shows the last RTT of the strip that moved.
- **Render by difference.** With 30 `state`/s and 16 strips, if the mixer view observes "the whole snapshot", SwiftUI re-evaluates 16 strips 30 times a second. It's cheap (they're structs) but unnecessary, and it's the first thing you notice on an iPad with a large window. `MixerModel` keeps one `@Observable` `StripModel` per strip and, when applying a snapshot, writes into each one **only if its `Strip` changed** (`Equatable`). So a strip that didn't change doesn't invalidate its view. The list of strips (add, remove, reorder) is a separate property that changes only when the IDs change. It's the client-side counterpart of the agent's targeted reads.
- **Hidden strips.** `HiddenStrips` in `LevelDeckKit/Sync` (pure, tested logic): a set of `StripID` per `agentId`, persisted by the app in `UserDefaults`. Hiding a strip doesn't remove it from the snapshot or from `MixerState`; only the view filters it. If the hidden strip is the default, it's shown anyway, with a "hidden" mark so the user understands why it appears (decision §21 D4). If the agent stops reporting a hidden strip, the preference is kept: when the device comes back it's still hidden.
- **Order.** Stable by name, the same as the agent's; the default mark doesn't reorder (decision §21 D3). Hidden strips are removed without altering the order of the rest.

### 16.3 What doesn't change

`SendThrottle`, `EchoGate`, `Backoff`, `FaderBoundary`, `ReconnectPolicy`, `SyncTiming` (30/s and 300 ms) and all the reconnection logic in §6.2 stay the same, with the same tests. v2 uses them with a different key.

## 17. Universal client (iPhone and iPad)

### 17.1 Target

One `LevelDeck` target, one bundle ID, one `Localizable.xcstrings`. Changes in `project.yml`:

- `TARGETED_DEVICE_FAMILY: "1,2"` (XcodeGen's default for iOS; today it's forced to `"1"`).
- Orientations via per-family build settings: `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone: UIInterfaceOrientationPortrait` (as today) and `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` with all four. In the resulting `Info.plist` they land as `UISupportedInterfaceOrientations~ipad`. Apple requires all four for resizable windows (TN3192) and App Store Connect already warns when they're missing.
- `UIRequiresFullScreen` is **not** declared. It's deprecated since iPadOS 26 and stops having any effect in iPadOS 27; an app without the key is resizable in Stage Manager and in iPadOS 26's windowed mode. The generated launch screen (`UILaunchScreen_Generation`, already present) is a requirement and is already met.
- `UIApplicationSupportsMultipleScenes` is **not** declared (one window; decision §21 D6). If it's ever enabled, the model is already per scene: `DiscoveryView` owns the `MixerModel`; the only shared piece would be `PairedAgents` (Keychain), which already tolerates reads from several views.
- No changes to `Info.plist`: Bonjour, local network and camera apply the same. The iPad has a rear camera for the QR.
- CI: `generic/platform=iOS Simulator` builds the universal target with no changes to `verify.sh`. The `macos-15` runners ship iPad simulators (`iPad Pro 13-inch (M4)`, `iPad Air 11-inch (M3)`, among others) in case Phase 8 adds a UI test; the job should list the available ones with `xcrun simctl list devices available` before picking one, because some images have been missing them.

### 17.2 Adaptive layout

There's one rule: **the horizontal size class decides the structure; the window size decides how many strips fit**. Nobody asks "is this an iPad?".

| Context | `horizontalSizeClass` | Structure |
|---|---|---|
| iPhone portrait, Slide Over, narrow Stage Manager window (< ~600 pt) | compact | Today's: `NavigationStack`, discovery → mixer; mixer with vertical strips in horizontal scrolling (decision §21 D5) |
| Full-screen iPad, wide Split View, wide Stage Manager window | regular | `NavigationSplitView` with a sidebar (discovered and paired Macs, Settings) and the mixer as detail. The sidebar can be hidden and the mixer takes everything. |

Mixer in regular width:

- Two groups, **Output** and **Input**, side by side (or stacked when the window is taller than it is wide: `ViewThatFits` decides). Each group is a row of vertical strips.
- Fixed strip width (the same as the iPhone's, ~88 pt of fader plus margins). If they don't all fit, the group scrolls horizontally; strips never shrink below the touch width. Fader height grows with the window up to a maximum.
- With a narrow window it falls back to the compact layout automatically via the size class. A minimum window size can only be **requested** (`windowResizability(.contentMinSize)` with `frame(minWidth:)`, iOS 17+), and Apple says it's a preference the system honors when it can; on iPadOS 18 with Stage Manager the restriction may come back `nil`. That's why the layout has to survive any compact width, and why the iPhone's compact layout is also the narrow iPad's: there's no third layout.
- iPadOS 26 puts the window controls at the leading edge of the toolbar: toolbar buttons (pair, settings) use the standard `.toolbar`, which the system shifts; no custom controls go there. Shortcuts are declared with `.commands` in the `App`, which on iPadOS 26 also builds the iPad's menu bar; on iPadOS 17 and 18 they keep working as shortcuts.
- Hardware keyboard and trackpad: shortcuts for the output default (`⌘↑` / `⌘↓` raise and lower 5 %, `⌘M` mute) and `hoverEffect` on faders and buttons. They're Phase 8 details; the rest of the layout doesn't depend on them.
- v1's sheets (device picker, settings, pairing) become popovers or the sidebar in regular (`presentationCompactAdaptation` covers the automatic change where it applies).
- `NavigationSplitView` with `.navigationSplitViewStyle(.balanced)`: the sidebar sits beside the mixer instead of overlaying it in portrait, which is what you expect from a control panel. In compact it collapses to a stack on its own, like today.
- Window size: `containerRelativeFrame` for what depends on the available width; `GeometryReader` only inside the fader, as today. An interactive resize (dragging the window's edge) mustn't cut off an in-progress fader drag: the `MixerModel` isn't recreated when the size class changes (the root view changes structure, the model is the same).

Mixer in compact width (iPhone): see §21 D5. The recommendation is horizontal scrolling with two stacked groups (Output above, Input below), each with its strips in a row, and a page indicator. The iPhone in portrait shows 3–4 strips per group without scrolling.

### 17.3 Text

Several v1 strings say "iPhone" ("This iPhone is no longer paired", "removes its key from this iPhone", "Open LevelDeck on the iPhone…" in the Mac's QR window). They're replaced with "this device" / "este dispositivo", or with the model when it helps (`UIDevice.current.model` gives "iPhone" or "iPad"). They're added to the catalog with translations; `check-localizations.py` keeps covering the target.

### 17.4 Per-client-device state

Hidden strips and section state (collapsed, last order) are preferences of the client device, stored in `UserDefaults` keyed by `agentId`. They don't sync between iPhone and iPad (no iCloud, by the "local first" principle; accepted).

## 18. Interface audit and proposals

What follows is an audit of the current UI, done over the v1 code, with proposals per area. **They are options, not decisions.** The spec fixes the structure (which elements exist and how they're organized); the visual design (shapes, color, typography, animation) is iterated separately in Claude Design from these notes. Each proposal says whether it touches structure (and then belongs in a phase) or only visuals (and then is material for the design iteration).

### 18.1 iPhone — Mixer

Current state (`MixerView`, `VerticalFader`): two strips (Output, Input) in an `HStack`; each strip has a title, percentage, an 88 pt-wide fader (rounded rectangle with proportional fill, no cap), a mute button (`bordered`, red tint when muted), the device name as a button with a chevron (opens a sheet), a settability note. On top, a status banner that appears and disappears; at the bottom, the RTT overlay in Debug.

| # | Finding | Proposal | Type |
|---|---|---|---|
| A1 | The status banner pushes the layout when it appears: faders jump in size when reconnecting or showing an error. | Always reserve the banner's space (fixed height) or overlay it (`overlay(alignment: .top)`) so the mixer doesn't move. | Structure (Phase 7) |
| A2 | The fader has no cap or scale; the app icon does have caps and ticks. The proportional fill reads as a progress bar, not a fader. | Option a: a sliding cap over a rail with ticks at 0/25/50/75/100 (consistent with the icon). Option b: keep the fill but with a cap edge and side marks. Option c: keep the bar and reinforce the percentage. | Visual |
| A3 | Percentage on top, mute below, name further down: three different text heights per strip. With N strips, the row of variable-length names (2 lines) misaligns the strips. | Fix the height of each zone in the strip (name in a fixed-height zone with truncation, not 2 variable lines) so every strip aligns its fader. | Structure (Phase 7) |
| A4 | The device name opens a modal picker to change the default. In v2 the picker goes away (every strip is in view). | The name stops being a button. The default mark goes in the strip's header; changing the default is an action on the strip: option a, a "star" button in the header; option b, a context menu (long press) with "Use as Default" and "Hide"; option c, both. | Structure (Phase 7) |
| A5 | Mute uses a red tint when active and the fader dims to gray. Two signals for the same state, and red usually means "recording" in audio. | One signal: dimmed fader with the crossed icon, no red; or red only if the design adopts it as the "mute" color across the app. | Visual |
| A6 | The settability note ("This device doesn't allow…") takes two lines under the strip and changes its height. | Replace with a lock icon next to the disabled control, with the explanation in `accessibilityHint` and in a popover on tap. | Structure (Phase 7) |
| A7 | No visual feedback for "someone else moved this" (another client or the Mac): the fader just moves, with no distinction. | Option: animate the remote change (interpolate the fader over ~120 ms) and not the local one; that way they're distinguished by motion, not color. | Visual |
| A8 | The Debug RTT overlay competes with the layout. | Move it to a popover reached from a hidden gesture (triple tap on the title) or to Settings. | Structure (Phase 7, Debug) |
| A9 | Portrait only; there's no landscape layout. | With v2, iPhone landscape falls into compact and shows the same mixer with more strips visible; it isn't blocked. | Structure (Phase 8) |

### 18.2 iPhone — Discovery, pairing and settings

Current state (`DiscoveryView`, `PairingView`, `SettingsView`): the root screen is the Mac list; when a paired one is found, it pushes the mixer. Settings and pairing are sheets from the bar.

| # | Finding | Proposal | Type |
|---|---|---|---|
| B1 | On launch the Mac list is visible for an instant and then it jumps to the mixer. The screen the user wants is the mixer; the list is a means. | Invert: the root is the mixer (with a "Looking for your Mac…" state when there's no connection) and the Mac list is a sheet or a menu in the title (`Menu` in the bar with the discovered Macs). In regular, the list is the sidebar. | Structure (Phase 8) |
| B2 | `ContentUnavailableView` "Looking for Macs…" and instructions only when the list is empty; if there's an unpaired Mac, the "Pair" button is in the row and also in the bar (two entries to the same flow). | One visible entry: "Pair" in the unpaired Mac's row; the bar icon only when there's no Mac in the list. | Structure (Phase 8) |
| B3 | "Forget" only via swipe: hard to discover. | Add the button in the row (or in the Mac's detail) in addition to the swipe. | Structure (Phase 8) |
| B4 | Settings shows "Protocol v3": developer information. | Move to an "About" section or Debug only. | Visual |
| B5 | The revocation alert ("This iPhone is no longer paired") is correct but says "iPhone". | Text by model (§17.3). | Structure (Phase 8) |

### 18.3 Mac — Menu bar menu

Current state (`MenuContent`, `ChannelControl`, `ServiceStatusView`, `PairedDevicesView`, `LoginItemView`): a 300 pt window with two sliders (Output, Input) with mute and device name, divider, service status (name, **port**, clients), paired devices with a connection dot and a **revoke X with no confirmation**, "Pair New Device…", login item toggle, "Protocol v3" and Quit.

| # | Finding | Proposal | Type |
|---|---|---|---|
| C1 | With one strip per device the menu gets long: 12 strips × ~50 pt = 600 pt plus everything else. | Collapsible Output/Input sections, with the default's strip always visible; maximum height with scrolling (§14.1). Alternative: the menu shows only the defaults and an "All Devices…" button opens a window with the full mixer. | Structure (Phase 6) — the choice is §21 D7 |
| C2 | Revoking a paired device is one click with no confirmation, and destructive (the iPhone has to scan again). | Confirmation (`confirmationDialog`) or revoke from a context menu with the device's name. | Structure (Phase 6) |
| C3 | The service status shows the port and "Protocol v3": technical detail in an end-user UI. | Show "Ready · 2 devices connected"; port and protocol in Debug only or in an "About". | Visual |
| C4 | Login item, paired devices and service status share the menu with the audio, which is what's used daily. | Move paired devices, login item and "About" to a Settings window (`Settings` scene, `⌘,`) and leave the menu for audio and "Pair…". | Structure (Phase 6) — §21 D7 |
| C5 | The Mac's slider doesn't distinguish the default from the others (today there's only the default). | Default mark on the strip and "Use as Default" in the others' context menu, consistent with A4. | Structure (Phase 6) |
| C6 | The menu bar icon shows neither mute nor connection. | Option: an icon variant with the output muted (crossed bar) and a dot when a client is connected. Optional, fits as a visual iteration. | Visual |
| C7 | There's no mixer window: whoever wants to see everything has to open the menu and keep it open. | Same alternative as C1: an optional "Mixer" window (`Window` scene) reusing the menu's strips. | Structure — §21 D7 |

### 18.4 iPad (new)

There's no UI to audit; the proposals fix Phase 8's structure (§17.2) and leave the rest to design:

| # | Proposal | Type |
|---|---|---|
| D1 | Sidebar: Macs (paired first, with connection state), Settings at the bottom. Detail: mixer. | Structure (Phase 8) |
| D2 | Mixer: Output and Input as two titled groups; fixed-width vertical strips; the fader grows with the height. Group header with the default's name and a hidden-strip counter ("2 hidden", tap to show them). | Structure (Phase 8) |
| D3 | A "defaults only" mode (a toggle in the header) that collapses each group to one large strip, to use the iPad as v1's single control when there are many strips. | Structure, optional (Phase 8) |
| D4 | Density: in large windows, show the percentage inside the fader instead of above it, to gain height. | Visual |
| D5 | Keyboard shortcuts and `hoverEffect` (§17.2). | Structure (Phase 8) |

## 19. v2 phases

Numbering continues from v1. Each phase ends with something usable and testable, and with new text in English and Spanish. The order follows the intent's priorities: first the agent (verifiable with the menu alone, like Phase 1), then the protocol and the client, then the iPad, then design, and finally the per-app volume spike.

**Phase 6 — Per-device strips in the agent.** `AudioControlling` v2 (`StripID`, `AudioStrip`, `AudioChange`, §14.2), `CoreAudioController` with per-device listeners and subscription by difference (§14.3), `AudioModel` with strips per scope and a default per scope, targeted reads. The menu shows one strip per device in two collapsible sections, with the default mark, "Use as Default" and a confirmation on revoke (C1, C2, C5). The protocol **doesn't change yet**: `AudioServerBridge` projects the default strips onto the v3 `state`, so the v1 iPhone keeps working while the agent is verified against hardware.
*Done when:*
- the menu shows one strip per output and input device, each controls its device, and external changes (keyboard, System Settings, Audio MIDI Setup, the volume button on Bluetooth headphones) move the right strip and only that one;
- plugging or unplugging a device adds or removes its strip without recreating the other strips' listeners (verified with a Debug log of the listener count: plugging one adds its listeners, it doesn't reset the total);
- each scope's default is marked and can be changed from another strip; if the default disappears, the mark moves to whatever macOS picks;
- a strip without volume or without mute disables only that control;
- the risk checklist in §14.4 is complete in the PR, with the result of each row;
- sleeping and waking with 8+ devices produces neither duplicate strips nor orphaned listeners;
- `AudioModelTests` and `DeviceSelectionTests` are rewritten with the per-strip mock: hot plug and unplug with listener difference, default that disappears, `deviceNotFound` on `setVolume` for a strip that's gone, independent flags per strip, `serviceRestarted` re-reads everything, and the projected v3 `state` stays correct; they pass in CI.

**Phase 7 — Protocol v4 and per-strip mixer on the iPhone.** New models in `LevelDeckKit/Protocol` (§15.5), `ProtocolVersion.current = 4`, `AudioServerBridge` emits `strips` and `defaults`, lazy snapshot and single encoding per tick in the server (§16.1). Client: `MixerState` per `StripID`, invalidation on strip disappearance, on-demand per-strip throttle, observable `StripModel` per strip, `HiddenStrips`, per-strip RTT (§16.2). Compact mixer with two groups and horizontal scrolling (D5), banner with reserved space (A1), fixed-height zones per strip (A3), default mark and action on the strip (A4), lock instead of note (A6), hide and show strips. The device picker and `DevicePickerView` are retired.
*Done when:*
- the iPhone shows every strip of the Mac, each controls its device, and what moves on the Mac or on another client is reflected on the right strip;
- dragging one strip while another client moves another produces no jumps on either; dragging two strips at once with two fingers works and each sends at most 30/s;
- unplugging the device being dragged cancels the pending send and the strip disappears without another device receiving its volume (test with the mock: the invalidated strip sends nothing more);
- changing the default during a drag does **not** invalidate the drag (new rule, §16.2) and the `setVolume` keeps going to the right device;
- the RTT of `setVolume` → `state` with 16 strips in the snapshot stays under 100 ms on the local network, measured with the overlay;
- hiding a strip removes it from the mixer, survives reconnecting and relaunching the app, and a hidden default strip is shown anyway with its mark;
- a Mac with no input devices shows the Input group empty with "No devices", without failing;
- tests: v4 encoding (§15.5), per-strip `MixerStateTests` (hold, invalidation on disappearance, no invalidation on default change, two strips dragged at once), `HiddenStripsTests`, per-strip `RoundTripMeter`, and `LoopbackIntegrationTests` with two clients on different strips of the same scope; they pass in CI;
- manual verification on a physical iPhone with a checklist in the PR.

**Phase 8 — iPad.** Universal target (§17.1), `NavigationSplitView` in regular width with a sidebar and the mixer as detail (D1, D2, B1), groups side by side or stacked depending on the window, Stage Manager with a resizable window, text without "iPhone" (§17.3), keyboard shortcuts and `hoverEffect` (D5), reorganized discovery and settings (B1–B3, B5). Optional, per decision: "defaults only" mode (D3).
*Done when:*
- the app runs on iPad in all four orientations; in Stage Manager the window resizes from ~320 pt wide to full screen and the layout switches from compact to regular and back without losing the connection or the faders' state;
- in regular, the sidebar lists the Macs and the mixer takes the detail; in a one-third Split View, the app falls back to the iPhone's compact layout;
- the iPhone's behavior doesn't change from Phase 7 (same app, same compact layout);
- keyboard: `⌘↑`/`⌘↓`/`⌘M` act on the output default strip; trackpad: controls react to the pointer;
- pairing from the iPad with the camera works and the Mac lists it with its name ("…'s iPad");
- no visible text says "iPhone" when running on iPad; `check-localizations.py` passes;
- CI builds the universal target in Debug and Release; manual verification on a physical iPad with a checklist in the PR (Stage Manager, Split View, Slide Over, external keyboard).

**Phase 9 — Design.** Apply the visual decisions that come out of the Claude Design iteration on the §18 proposals marked "Visual" (A2, A5, A7, B4, C3, C6, D4) plus any structural ones that were deferred. This phase changes neither the protocol nor `LevelDeckKit`; it touches only the views of the three surfaces. Its exact scope is set when the design iteration closes, with its own checklist.
*Done when:*
- the three surfaces (iPhone, iPad, Mac menu) implement the agreed design, with screenshots in the PR compared against the mockups;
- remote and local changes are distinguished as decided (A7);
- accessibility: every strip has a label, value and adjustable action in VoiceOver; Dynamic Type up to the largest accessibility size doesn't break strip alignment;
- `verify.sh` passes with no changes to the `LevelDeckKit` tests (proof that it was visual only).

**Phase 10 — Spike: per-app volume.** A throwaway prototype (separate target, `Spikes/AppVolumeSpike`, outside the apps and packages) that implements the chain in §20.2 for **one** hand-picked app and measures what §20.6 asks for. It doesn't touch `LevelDeckKit`, the protocol or the agent. It ends in `Design/AppVolume/GO-NO-GO.md` with the data and a recommendation.
*Done when:*
- the prototype attenuates one app's audio (Music or Safari) from 100 % to 0 % with a ramp, without clicks, while the other apps play directly;
- the "System Audio Recording Only" permission was requested once with the Apple Development signature and survived three rebuilds; the denied-permission flow doesn't leave the app muted (the §20.3 self-test before muting);
- added latency (signal RTT with and without the tap), the gap when engaging and releasing the tap, the onset loss when a silent app resumes, and CPU idle and active were measured, each on internal speakers, a USB interface and AirPods;
- changing the default output device, changing the sample rate, opening the microphone with AirPods (A2DP → HFP), sleep/wake, and killing the prototype with `kill -9` while attenuating were all tried; each case is in the document with what happened to the app's audio;
- `GO-NO-GO.md` answers every §20.6 criterion with the measured value and ends in "go", "no-go" or "go with conditions", and the v2 section of `INTENT.md` is updated with the answer to its open question.

**Phase 11 — Per-app volume (only if Phase 10 is a "go").** Sketch in §20.7; the detailed spec is written after the spike, with its data. It raises the protocol to v5 and the agent's deployment target to macOS 14.4.
*Done when:* defined when Phase 10 closes. At minimum: one strip per app producing audio, in the menu and in the clients; the agent returns to the "no taps" state when it quits and cleans up leftovers on launch; the permission is explained in the menu before it's requested; and the latency measured in the spike holds in the real implementation.

## 20. Per-app volume: research and spike

Researched over the SDK headers (`AudioHardware.h`, `AudioHardwareTapping.h`, `CATapDescription.h`, SDK 14.5, 15.5 and 26.5), Apple's documentation and sample ("Capturing system audio with Core Audio taps"), an Apple engineer's forum answer about the permission, the AudioCap code (Guilherme Rambo) and a dozen open-source projects that have done per-app volume with taps since 2024. It marks what's verified in Apple sources or code and what's only reported by third parties.

### 20.1 What Core Audio allows

- **There is no per-process volume.** Verified in the headers: the only per-process mute properties (`kAudioHardwarePropertyProcessIsAudible`, `kAudioDevicePropertyProcessMute`, `ProcessInputMute`) apply to the **calling** process itself. There's no equivalent to Windows' `ISimpleAudioVolume`. A `kAudioProcessPropertyIsMuted` constant appeared in a comment in SDK 14.5 and disappeared in 15.5 without ever reaching the enum.
- **What does exist are process taps** (`AudioHardwareCreateProcessTap`, `CATapDescription`), available since **macOS 14.2** per the header (`API_AVAILABLE(macos(14.2))`) and Apple's sample; the community says "14.4" because that's when it was discovered and the permission became reliable, without Apple documenting a functional difference. A tap captures the audio one or more processes send to a device. Its only action on the foreign process is to **silence** it (`CATapMuteBehavior`: `unmuted`, `muted`, `mutedWhenTapped`), all or nothing.
- **Therefore "per-app volume" = re-routing.** Silence the app in the HAL with `mutedWhenTapped`, read its audio through the tap, multiply by the gain and write it to the real device. The agent becomes part of the **audio path** of the apps it attenuates. That's what every open-source project found does (Atoll, per-app-audio, mac-volume-mixer, MacVolumeMixer, buried-anchor, sonicflow, VolBoost, Fader, FineTune) and, by its profile (no driver, "System Audio" permission, purple indicator, 14+ only), what Rogue Amoeba does in SoundSource since deprecating its ACE driver.
- Apps at 100 % and not muted **aren't tapped**: they play directly, with zero latency and no cost. The tap is created when the fader leaves 100 % and destroyed when it returns.
- The Swift overlay (`AudioHardwareSystem`, `AudioHardwareTap`) is macOS 15+; with a 14 target the C API is used. macOS 26 adds `bundleIDs` and `processRestoreEnabled` to `CATapDescription` (tap by bundle ID and restore the tap when the app relaunches): useful, but nothing can depend on them.

### 20.2 Tap architecture (what the spike prototypes)

For each attenuated app (or group of processes of one app):

1. `CATapDescription(stereoMixdownOfProcesses: [AudioObjectID of the processes])`, `isPrivate = true`, `muteBehavior = .mutedWhenTapped`. The processes are HAL `Process` objects (`kAudioHardwarePropertyTranslatePIDToProcessObject`), not PIDs.
2. `AudioHardwareCreateProcessTap` and a read of `kAudioTapPropertyFormat`.
3. A **private aggregate device** whose `MainSubDevice` (clock) is the real output device and whose `TapList` contains the tap with `DriftCompensation = true` and `TapAutoStart = true`. The tap has to go in the creation dictionary; adding it afterwards fails silently.
4. **One IOProc** on the aggregate: the input buffer carries the tap's frames, the output buffer is the real device; gain is applied with a ramp (8–20 ms, `vDSP_vrampmul`) and copied. Same clock for capture and playback, so there's no drift between the two sides. The two-IOProc variant with a ring buffer (capture in one aggregate, playback separately) adds another buffer of latency and forces manual drift handling: discarded.
5. On returning to 100 %: `AudioDeviceStop` → `DestroyIOProcID` → `DestroyAggregateDevice` → `DestroyProcessTap`, in that order. When the tap is destroyed, the app plays directly again.

Why `mutedWhenTapped` and not `muted`: the mute is tied to someone reading the tap. If the IOProc stops or the agent dies, the documented semantics ("for the duration of the read activity on the tap no audio is sent to the audio hardware") say the audio returns to the hardware. With `muted` the silence is unconditional, and there are reports of apps left muted after a mixer crash.

Alternatives evaluated and discarded:

| Alternative | Why not |
|---|---|
| Virtual `AudioServerPlugIn` driver (what BackgroundMusic does; what SoundSource did with ACE) | Root install in `/Library/Audio/Plug-Ins/HAL` and a `coreaudiod` restart; it becomes the default device and breaks v1's output picker; playthrough with two IOProcs; nearly impossible to debug (SIP). Rogue Amoeba deprecated it for the same reasons. Contradicts "invisible on the Mac" and "simple before complete". |
| Audio-only ScreenCaptureKit | Screen recording permission, with the monthly reminder on macOS 15+. Not an option. |
| Audio Units, `PreferredChannelLayout`, device controls | They're properties of the device, not of a foreign client. They don't help. |

### 20.3 The permission

- **What it is.** "System Audio Recording Only" (`kTCCServiceAudioCapture`), in System Settings › Privacy & Security › Screen & System Audio Recording. It's independent of screen recording. It requires `NSAudioCaptureUsageDescription` in the `Info.plist` (macOS 14.2+). It's reported that the key **doesn't work via `INFOPLIST_KEY_*`**: the agent needs a physical, merged `Info.plist`, as the iOS target already has. It's translated in `InfoPlist.xcstrings`.
- **When it's requested.** Verified with an Apple engineer: there's no API to request it; the system asks on its own the **first time an aggregate containing a tap is started** (`AudioDeviceStart`). Creating the tap and reading its format don't trigger it.
- **What happens if it's denied.** `AudioDeviceStart` returns `noErr` and the IOProc receives zeros forever, **but a tap with `muted` or `mutedWhenTapped` silences the app all the same**. That's the main UX risk: denied permission plus mute equals a muted app with no explanation. Rule for the spike and Phase 11: the agent **never** creates a silencing tap without first confirming it receives audio. A self-test like mac-volume-mixer's: an `unmuted` tap on the agent itself playing a −90 dBFS tone; if the tone doesn't come back, the permission isn't there and the menu says so with a button to Settings.
- **How to know whether it's granted.** No public API. AudioCap uses the private `TCCAccessPreflight` SPI loaded with `dlsym`; it's **excluded** by the "system frameworks, nothing private" principle. The self-test is the only acceptable route.
- **Signing.** TCC ties the grant to the signing identity. With ad-hoc signing (`Sign to Run Locally`) the grant is lost on every rebuild; with the Personal Team's "Apple Development" identity and a fixed bundle ID, it persists. The agent is already signed that way (§12), so in Debug there's no re-approval on every build, but it does have to be launched as a `.app` through LaunchServices.
- **Periodic reminder.** macOS 15's ("allow for one month") applies to screen recording without the system picker; no evidence was found that it applies to "System Audio Recording Only", and several projects migrate to taps precisely to avoid it. The spike verifies it by leaving the prototype installed for the duration of the phase.
- **Indicator.** While a tap is capturing, macOS shows the purple recording dot in the menu bar. It's visible and permanent while any app is attenuated. It goes against "invisible on the Mac" and is one of the go/no-go questions: if it bothers, the answer is that the dot only appears when some app is off 100 %.

### 20.4 Latency

Apple publishes no figures. What's reported, consistent across projects:

| Situation | Added latency |
|---|---|
| App at 100 % without mute (no tap) | 0 ms |
| Attenuated app, one IOProc in the aggregate | ~10–20 ms (one aggregate buffer with drift compensation; 512 frames at 48 kHz is 10.7 ms) |
| Engaging or releasing the tap (moving from or to 100 %) | a 50–200 ms gap in that app's audio |
| An app that was silent and starts playing again with the tap active | the first tens of ms are lost (20–150 ms, worse on Bluetooth) |
| Gain change | perceptible in ~10 ms; the per-buffer ramp avoids clicks |
| CPU | 0 % idle (no taps); ~1–2 % with active taps, one vector multiply per buffer |

For a volume mixer (not monitoring or games) 10–20 ms are acceptable; the gap on engaging is what's most noticeable, and that's why the tap is created on leaving 100 % and not on every movement.

### 20.5 Risks

| Risk | Evidence | Mitigation in Phase 11 |
|---|---|---|
| **Sample-rate renegotiation** (44.1 ↔ 48 kHz; AirPods A2DP → HFP when a microphone opens): the tap delivers zeros or fails on format, and with `mutedWhenTapped` **the app stays muted** until rebuilt | Multiple issues (oats, vo, meeting-transcriber, macparakeet) | Observe the aggregate's `NominalSampleRate` and `StreamConfiguration` and the tap's `kAudioTapPropertyFormat`; rebuild tap and aggregate with a debounce (~400 ms) and a retry budget (1/2/5/15/30 s); while rebuilding, destroy the tap first so the app plays directly |
| **macOS 26.x bug:** all-zero buffers after minutes with the IOProc running normally, with no signal that detects it | Apple forum with no answer; per-app-audio implements a watchdog | Watchdog: if the tap delivers only zeros for N seconds while the process reports `IsRunningOutput`, rebuild (max 3 per route, 30 s minimum between attempts) |
| **Agent crash with active taps:** contradictory evidence on whether the app stays muted | For "it recovers": `mutedWhenTapped` semantics, non-persistent private aggregate, "taps cannot outlive the app" (mac-volume-mixer). Against: reports with `muted` and "stranded" taps during device changes | Never `muted` as a persistent state; orderly teardown in `applicationWillTerminate`; cleanup of leftover aggregates on launch. The spike tests it with `kill -9`. |
| **Default output device change:** the aggregate is tied to a UID | Every project handles it by rebuilding | Observe `DefaultOutputDevice` (v2 already does) and rebuild the taps on the new device; v2 already has the device model |
| **Helper processes:** Safari and every WebKit app share `com.apple.WebKit.GPU`; Chrome has an Audio Service; Discord, four processes. The PID that plays isn't the app's | AudioCap and the mixers group by parent app | Group by the responsible app's bundle ID (`NSRunningApplication`); Safari and WebKit as one "Safari and web apps" group. A new helper mid-playback doesn't enter an existing tap until it's rebuilt |
| **`IsRunningOutput` listeners that don't fire** (macOS 15.0.1) | Forum with no answer; every project adds a poll | Listener plus a 1 Hz fallback poll over the process list |
| **Self-exclusion in capture apps:** Discord, Zoom and OBS exclude "their own" audio per process; if the agent re-plays Discord's, the others on the call hear their own voice | Issue in vorssaint-utils | A list of apps that are never tapped (video calls and capture), editable |
| **The agent itself** appears in the audio process list (from the self-test) | AudioCap filters it | Exclude its own PID |
| Spatial audio, AirPlay, multichannel devices | Untested in every project; in 14.2 a bug halved the volume with 4+ channels | The spike tests AirPods with spatial audio; AirPlay is documented as unsupported if it fails |
| Intermittent `'nope'` error (`kAudioCodecIllegalOperationError`) when creating a tap or aggregate | Forum with no answer; associated with leftover aggregates | Clean up leftovers before recreating; retry with backoff |
| `coreaudiod` restarts or the Mac wakes | Header: "any state the client has… must be re-established" | `kAudioHardwarePropertyServiceRestarted` already exists in v1: rebuild every tap there |

### 20.6 Go/no-go criteria

The spike (Phase 10) answers each row with a measured value. "Go" requires every mandatory row to be green.

| # | Criterion | Threshold | Mandatory |
|---|---|---|---|
| G1 | Added latency with the tap active | ≤ 25 ms on internal speakers and USB; ≤ 40 ms on AirPods | Yes |
| G2 | Gap when engaging and releasing the tap | ≤ 250 ms, no click or pop | Yes |
| G3 | Permission denied | No app is left muted; the prototype detects it with the self-test and reports it | Yes |
| G4 | Prototype crash (`kill -9`) with an attenuated app | The app plays again on its own within ≤ 5 s, without restarting it or `coreaudiod` | Yes |
| G5 | Default output change and sample-rate change | The app keeps playing (directly or attenuated) after ≤ 2 s; never permanently muted | Yes |
| G6 | AirPods: open the microphone (A2DP → HFP) with the app attenuated | Same as G5 | Yes |
| G7 | Sleep and wake with an attenuated app | The tap is rebuilt or released; the app plays on wake | Yes |
| G8 | CPU with two attenuated apps | ≤ 3 % on a base Apple Silicon Mac | Yes |
| G9 | Permission with Apple Development signing | Requested once; survives three rebuilds and a Mac restart | Yes |
| G10 | Periodic permission reminder | None during the phase | No (noted) |
| G11 | Purple dot in the menu bar | Acceptable to the intent's user, knowing it appears only with attenuated apps | No (a judgment, not a measurement) |
| G12 | Spatial audio / AirPlay | Works, or is documented as unsupported | No |

"Go with conditions" is the expected outcome if G1–G9 pass and G11 is uncomfortable: it's implemented with a "Per-App Volume" switch, off by default in the menu, that explains the permission and the indicator before turning on.

### 20.7 Phase 11 sketch (only if "go")

Detailed after the spike; what follows fixes the shape so the rest of v2 doesn't contradict it.

- **New module** `AgentTaps` in `LevelDeckAgentKit`, behind an `AppAudioControlling` protocol with a mock, like `AudioControlling`. `AppMixer` keeps one `AppTap` (tap + aggregate + IOProc) per attenuated app and the list of apps producing audio (`ProcessObjectList`, `IsRunningOutput`, fallback poll). The IOProc is real-time code: no allocations, locks or ARC inside the block; the gain is read from an atomic `Float`.
- **Agent deployment target** to macOS 14.4 (iOS doesn't change). With `@available(macOS 14.2, *)` as the header says, but tested on 14.4+.
- **Protocol v5.** The `state` gains `apps: [{ bundleId, name, volume, muted, isPlaying }]` and `appVolumeAvailable: "on" | "off" | "permissionNeeded"`. Commands `setAppVolume { bundleId, value }` and `setAppMute { bundleId, muted }`. Complete snapshot, as always. The identity is the responsible app's bundle ID, not the PID.
- **Client.** A third group of strips, "Apps", with the same `StripModel` and the same synchronization (`StripID` gains an `.app(bundleId)` case). No default picker. The strip's icon is the app's (the agent sends the bundle ID; the client doesn't have the Mac's icons, so either a small PNG goes in a separate `appIcon` message or a generic icon is used: a decision for the Phase 11 spec).
- **Mac menu.** An "Apps" section with the same strips, a "Per-App Volume" switch (off by default if the go is "with conditions") and the permission's state with a button to Settings.
- **Security.** Nothing changes: the new commands go over the same authenticated session. The only new thing on the Mac's surface is the TCC permission, which the user grants by hand.
- **Exclusion list** (video calls, capture) with defaults, editable from the menu.

## 21. Pending decisions

Each row has the spec's recommendation and what's lost with each option. Until they're decided, the spec assumes the recommended one. The same list, with more context, goes at the top of the PR.

| # | Decision | Recommendation | Alternatives and tradeoffs |
|---|---|---|---|
| D1 | **Shape of the v4 `state`** | `strips: { output: [...], input: [...] }` + `defaults: { output, input }` (§15.1) | *Flat device list with one object per scope inside* (`{ id, name, output: {...}?, input: {...}? }`): less repetition of name and transport for interfaces with both scopes, but the client has to flatten to draw strips and the per-scope order is lost. *An `isDefault` flag on the strip instead of `defaults`*: simpler to draw, but "there's no strip for the hidden default" can't be expressed. |
| D2 | **`deviceId` required in `setVolume`/`setMute`** | Required. The client resolves the default with `defaults`. | *Optional = default*: convenient for a future widget that only knows "the output", but it reintroduces v1's race (the default changes between the client deciding and the agent applying) and two code paths in the agent. If the widget comes, an explicit `setDefaultVolume { scope, value }` command is added. |
| D3 | **Strip order** | Stable by name, default marked, no reordering. | *Default first*: more useful on the iPhone with many strips, but a strip jumps position when the default changes, even under the finger. Possible mitigation: the iPhone scrolls to the default on connect. |
| D4 | **Hiding strips** | Yes, on the client, per Mac, in Phase 7; a hidden default is shown anyway with a mark. | *No hiding*: less code and state, but a Mac with Zoom, Teams and three BlackHoles has 8 strips nobody wants to touch. *Hide in the agent (don't report)*: one configuration for every client, but it mixes UI preference with the protocol and the snapshot stops being "everything there is". |
| D5 | **Compact (iPhone) mixer with many strips** | Two stacked groups (Output above, Input below), vertical strips in horizontal scrolling per group, page indicator. | *Output/Input tabs*: more fader height, but you don't see both sides at once (v1 showed them together). *Vertical list with horizontal sliders*: everything fits without scrolling, but it stops being a mixer and loses v1's vertical gesture. |
| D6 | **Several windows on the iPad** | Not in v2 (one scene). | *Yes*: structurally free because the model is per scene, but it duplicates browser and connections, and "two windows of the same Mac" adds nothing. |
| D7 | **Mac menu with many strips** | Collapsible sections with scrolling in the menu (C1), and move paired devices and login item to a Settings window (C4). | *Defaults only in the menu + a "Mixer" window* (C1 alternative, C7): a short menu like today, but the window is one more surface to design and maintain. *Everything in the menu, no separate settings*: zero new windows, but the menu with 12 strips plus paired devices plus login item is uncomfortable. |
| D8 | **HAL writes off the main actor** | Deferred to Phase 6's measurement (§14.3): only if a write exceeds ~5 ms. | *Move now*: avoids the risk up front, but adds an actor and isolation hops to code that's simple and easy to test today. |
| D9 | **Per-app volume** | Do the spike (Phase 10) with the §20.6 go/no-go criteria; no commitment to implement. The research already says it's viable in principle (every open-source mixer from 2024–2026 does it this way) and that the cost is entering the audio path of attenuated apps, with the system audio recording permission and the purple dot in the menu bar. | *Drop it now*: saves the spike, but the question has been open in the intent since v1 and today there is a driver-free path. *Commit to Phase 11 now*: the §20.5 risks (muted app if the tap breaks, denied permission plus mute) are real and only the spike says whether the mitigations are enough. |
| D10 | **Go/no-go thresholds** (§20.6) | The proposed ones: 25 ms added latency, 250 ms gap, recovery in ≤ 5 s after a crash. | They're the spec's judgment, not the intent's: if 40 ms or a half-second gap are acceptable to the user, the spike can be a "go" with looser thresholds. Better to fix them before measuring so the result doesn't bend to the data. |

## 22. v2 testing

Complements §11. Everything automated runs in `scripts/verify.sh` and CI; whatever needs hardware goes in its phase's manual checklist.

- **LevelDeckKit:** v4 encoding (§15.5); per-strip `MixerStateTests` (holding one strip while another changes, invalidation on disappearance and on `volumeSettable` becoming `false`, no invalidation on default change, two simultaneous drags, per-strip `settle`); `HiddenStripsTests` (hide, show, hidden default, persistence per `agentId`); per-strip `RoundTripMeter`; `SendThrottle` unchanged.
- **LevelDeckAgentKit (`AgentAudio`):** `AudioModel` with the per-strip mock: `.strip` re-reads only that strip (the mock counts reads), `.deviceList` adds and removes strips without re-reading the others, `.controlsChanged` re-resolves one strip, `.defaultDevice` moves the mark, `.serviceRestarted` and `restart()` re-read everything, `deviceNotFound` and `notSettable` per strip, lazy snapshot (N events in one window produce one construction). `AgentCoreAudio` is verified against hardware with the §14.4 checklist.
- **Loopback integration:** `LoopbackIntegrationTests` with two clients on different strips of the same scope and on the same strip; `deviceNotFound` only to whoever asked; the v4 `state` arrives identical to both; a session receiving 100 strip events in 100 ms receives at most 4 `state` messages (coalescing). `PairingIntegrationTests`, `HelloAuthIntegrationTests` and `ReconnectTests` don't change: security doesn't change.
- **Performance (manual, Phases 7 and 8):** RTT with 16 strips in the snapshot under 100 ms; on the iPad, dragging one strip with 16 on screen doesn't drop below 60 fps (Instruments, SwiftUI view body count: only the dragged strip re-evaluates at 30/s).
- **Spike (Phase 10):** the §20.6 measurements are the "test"; the prototype has no automated tests.
