# INTENT — LevelDeck

> Remote control for the Mac's audio from the iPhone

## Why it exists

I want to control my Mac's audio from my iPhone as naturally as Logic Remote controls a Logic session, but applied to system audio instead of a DAW.

Today, to adjust the volume I have to be in front of the Mac: using the keyboard, the menu bar or settings. I want the iPhone to work like a physical control surface: pick it up, move a fader, done.

## What "it works" means

- I open the app on the iPhone and, without configuring anything, it finds my Mac and I can control it right away.
- I move a fader and the volume changes instantly, with no perceptible lag.
- If the volume changes on the Mac (keyboard, another app), the iPhone reflects it. Both sides always tell the same truth.
- It feels like an instrument, not a form: direct gestures, immediate response and clear feedback.
- Only my devices can control my Mac.

## What I want to control

In order of importance (1 and 2 have the same priority):

1. Main output volume and mute.
2. Input volume (microphone or interface) and mute.
3. Choosing the active output and input devices.
4. Per-app volume. It's desirable, but I know macOS doesn't offer it natively. I want to understand the cost before committing to it.

## Principles

- **Apple-native.** Swift and SwiftUI on both sides, with system frameworks. No web layers or extra runtimes.
- **Local first.** Everything happens on the local network, with no external servers, accounts or cloud.
- **Invisible on the Mac.** The agent lives quietly in the menu bar, starts on its own and stays out of the way.
- **Simple before complete.** I'd rather have an app that does a few things perfectly than one that does many things halfway.

## Out of scope (for now)

- Publishing it on the App Store. It's a personal project, for my devices.
- Control outside the local network.
- Controlling DAWs, media playback or other Mac functions that aren't audio.
- Support for Windows, Android or other platforms.

## Open questions

- Is per-app volume worth it, given that it requires a virtual audio driver?
- How do the iPhone and the Mac pair the first time, securely and without friction?
- Does it make sense to also control the volume from a widget or from the iPhone's Control Center, without opening the app?
- What should the interface look like: a mixer with several faders or a single large control?

## How it will be built

With Claude Code or another coding agent, starting from this document. The technical spec is derived from here. If the spec and this intent contradict each other, this document takes precedence until it's updated.

---

## v2 — draft for approval

> Status: **draft**. The agent wrote it from the goals I gave it; until I approve it, v1 (above) is the only intent in force. The v2 spec (`SPEC.md`, Part II) derives from this section.

### Why a v2

v1 does what I asked: I pick up the iPhone, move a fader and the Mac responds. But it only controls the default device on each side. My Mac has more than one audio destination at a time (speakers, headphones, the interface, the virtual devices from Zoom and Teams) and today, to touch the volume of one that isn't the default, I first have to make it the default. That breaks the control-surface metaphor: in a mixer every channel has its own fader; you don't "select" the channel before moving it.

And the surface I use most often next to the Mac isn't the iPhone, it's the iPad. In landscape, with more width, that's where a mixer with several strips makes sense.

### What "it works" means

- I see one strip per output device and one per input device, each with its fader and mute. I move any of them and that device changes, whether or not it's the default.
- The default on each side stands out visually and I can change it from its strip, without opening a separate picker.
- If I plug something into the Mac or unplug it, strips appear and disappear on their own, on every connected device.
- If a device changes from the Mac (keyboard, System Settings, another app), its strip reflects it. The v1 rule still holds: both sides always tell the same truth, now for every device.
- I can hide the strips I don't care about (the virtual ones that video-call apps install), and that choice is mine, on my device, not the Mac's.
- It's a single app that runs on iPhone and iPad. On the iPad it feels designed for the iPad: landscape, strips side by side, and it adapts to any window size in Stage Manager instead of looking like a stretched iPhone.
- With many strips, moving a fader is still instant. The number of devices can't make the app feel slower.

### What I want to control

In order of priority:

1. Volume and mute of any output and input device, not just the default. The default is marked and can be changed.
2. All of the above from the iPad, with its own layout.
3. A better-looking interface. The spec fixes the structure (what's on screen and how it's organized); I iterate on the visual design separately, with proposals, not decisions.
4. Per-app volume, **only if it's viable**. macOS 14.4 brings Core Audio process taps that might allow it without a driver. I want a short spike with an explicit go/no-go before committing: if the permission, the latency or the risks aren't acceptable, it's dropped and the reason is documented.

### Principles that stay

The v1 ones, unchanged: Apple-native, local first, invisible on the Mac, simple before complete. Plus two that v1 made explicit and that v2 doesn't negotiate:

- **One complete snapshot.** The agent keeps sending the whole state in every message, now with every strip. I'd rather pay a few kilobytes per second than reintroduce the sync bugs that diffs bring.
- **The v1 security model isn't touched.** QR pairing, TLS-PSK with one key per device, challenge-response for the `hello`, revocation. v2 adds audio capabilities, not attack surface.

### Out of scope (for now)

- Still out: App Store, control outside the local network, DAWs and media, other platforms.
- Several windows of the app on the iPad at once (Stage Manager with two LevelDeck windows). One window, resizable.
- Widget and Control Center. Still on the "later" list.
- A Mac client (controlling one Mac from another). The code would allow it, but I don't need it.

### Open questions

- What does the mixer look like on the iPhone with ten strips? Horizontal scrolling, two tabs (Output and Input) or a compact view with horizontal sliders?
- Are strips in stable name order with the default highlighted, or is the default always first?
- Per-app volume: do I accept the agent inserting itself into those apps' audio path (capture, attenuate and play back), with the system audio recording permission that requires?
