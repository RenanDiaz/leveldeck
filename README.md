# LevelDeck

Remote control for the Mac's audio from the iPhone. An agent in the Mac's menu bar exposes output and input volume and mute over the local network, and the iPhone app shows them as a mixer with faders synced in real time.

Swift and SwiftUI on both sides, system frameworks only. No servers, accounts, cloud or third-party dependencies.

> **Project documents.** The why is in [`INTENT.md`](INTENT.md) and the how in [`SPEC.md`](SPEC.md). This README only explains how to build, install and use. If anything here contradicts the spec, the spec wins; if the spec contradicts the intent, the intent wins.

## What it does

- **Zero-configuration discovery.** The iPhone finds the Mac over Bonjour (`_leveldeck._tcp`) and connects on its own to the ones it's already paired with.
- **Output and input.** Volume and mute for both, with a picker for the active device (headphones, USB interfaces, monitors, virtual devices).
- **Two-way sync.** If the volume changes from the Mac's keyboard or from another iPhone, every client reflects it. The fader you're dragging doesn't jump from the echo.
- **Non-settable controls.** If a device doesn't allow changing the volume or the mute (e.g. HDMI), that control is disabled without affecting the other one.
- **Only your devices.** Pairing via QR and TLS-PSK with one key per iPhone; revoking from the Mac cuts the connection instantly.
- **Resilient.** Reconnects on its own after the Mac sleeps, the network changes or the app returns to the foreground. The agent starts at login.
- **English and Spanish** in both apps.

## Status

v1 complete through phases 0–5 (see [`SPEC.md` §9](SPEC.md#9-phases)). Per-app volume and Control Center widgets are left for after v1 (§10).

## Requirements

| | Version |
|---|---|
| Build Mac | macOS with Xcode 16+ (Swift 6) |
| Agent | macOS 14+ |
| App | iOS 17+ (iPhone) |
| Tools | [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) |

The Xcode project is **not versioned**: it's generated from [`project.yml`](project.yml).

## Getting started

```bash
# 1. Signing Team ID (local file, outside git)
cp Configs/Local.xcconfig.example Configs/Local.xcconfig
#    edit DEVELOPMENT_TEAM with your Team ID

# 2. Generate the project
xcodegen generate

# 3. Open in Xcode
open LevelDeck.xcodeproj
```

Run `xcodegen generate` again whenever you add or remove files, or change `project.yml`.

In Xcode:

1. **LevelDeckAgent** scheme → *My Mac* → Run. The icon shows up in the menu bar (not in the Dock).
2. **LevelDeck** scheme → your iPhone → Run. The first time, iOS asks for local network permission: accept it. On macOS 15+ the Mac asks too.

### Pairing

1. In the agent's menu: **Pair New Device…** A window opens with a QR code that expires in 2 minutes.
2. On the iPhone, the Mac shows up in the list: tap **Pair** and scan the QR code.
3. Done. From then on the iPhone connects on its own, without scanning again.

The simulator has no camera: in Debug builds the QR window shows the code as text so you can paste it.

To revoke an iPhone, do it from the device list in the agent's menu. **Forget** in the iPhone's settings only deletes the iPhone's key; the Mac keeps listing it until you revoke it.

## Verification

```bash
scripts/verify.sh
```

Runs the same thing as CI (GitHub Actions on `macos-15`, on every push to `main` and `claude/**` and on every PR):

1. `xcodegen generate`
2. `LevelDeckKit` tests (protocol, pairing, sync and loopback integration with TLS-PSK)
3. `LevelDeckAgentKit` tests (audio logic with a CoreAudio mock)
4. Build of both apps in Debug and Release, unsigned
5. Check that the development plaintext transport doesn't exist in the Release apps
6. [`scripts/check-localizations.py`](scripts/check-localizations.py): every string in the apps has a Spanish translation

To iterate on a package without generating the project:

```bash
swift test --package-path Packages/LevelDeckKit
swift test --package-path Packages/LevelDeckAgentKit
```

Real CoreAudio, the camera, Bonjour on a physical iPhone and the login item can't be tested in CI: each phase has a manual checklist in its PR, based on the spec's "Done when" criteria.

## Structure

```
leveldeck/
├── INTENT.md, SPEC.md       # what and why / how
├── project.yml              # XcodeGen: source of truth for the project
├── Configs/                 # shared xcconfig; Local.xcconfig (Team ID) outside git
├── LevelDeckAgent/          # macOS menu bar app
├── LevelDeck/               # iOS app
├── Packages/
│   ├── LevelDeckKit/        # shared: Protocol, Transport, Sync, Pairing
│   └── LevelDeckAgentKit/   # macOS only: AgentAudio (logic) and AgentCoreAudio (CoreAudio)
├── Design/AppIcon/          # icon source art (not used by the build)
└── scripts/                 # verify.sh and check-localizations.py
```

The logic lives in the packages, where it's tested in isolation; the apps are mostly views. Details in [`SPEC.md` §4](SPEC.md#4-repository-structure).

## How it works, in short

- **Transport.** WebSocket over TLS 1.2 with a pre-shared key (`TLS_PSK_WITH_AES_128_GCM_SHA256`), using Network.framework. There's no unencrypted channel: pairing also happens over TLS-PSK with the key from the QR code.
- **Identity.** Each iPhone has its own key and identity. On connect, the Mac sends a `nonce` and the `hello` answers with its HMAC, so no device can pass itself off as another.
- **Protocol.** JSON, version 3. The agent always sends the full state snapshot (no diffs), coalesced to at most 30 per second. See [`SPEC.md` §8](SPEC.md#8-protocol).
- **Keys.** In the Keychain on both sides: the iPhone's doesn't migrate with backups; the Mac uses the login keychain.

Known and accepted security limitations (no forward secrecy, QR code reusable within its 2-minute window) in [`SPEC.md` §7.2 and §10](SPEC.md#10-after-v1).

## Distribution

Personal project, outside the App Store. It's installed from Xcode on your own devices. With a free Apple ID, iOS signing expires after 7 days; with a paid developer account you can use TestFlight or one-year signing. The agent is signed locally and doesn't need notarization for personal use.
