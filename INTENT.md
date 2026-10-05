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

## v2 — approved

> Status: **approved** (2026-09-24). Written by the agent from the goals I gave it and approved with the decisions recorded in `SPEC.md` §21. From here on, this section and v1 (above) together are the intent in force; the v2 spec (`SPEC.md`, Part II) derives from this section.

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

### Open questions, answered

- **The mixer on the iPhone with ten strips:** horizontal scrolling, Output above and Input below. But the gesture (a vertical fader inside a horizontal scroll) gets validated on a real iPhone before the mixer is built; if it can't be made to feel right, it becomes two tabs, Output and Input.
- **Strip order:** stable, by name, with the default highlighted. The fader I'm dragging never moves because something else changed: strips are identified by device, never by position, and a device plugged in mid-drag waits until I let go.
- **Per-app volume:** I accept exploring it with a spike, on one condition beyond the measurements: an app at 100 % must have no tap at all. Its audio never goes through the agent and gains no latency; only the apps I actually turn down pay the cost, and only while they're turned down.

---

## v3 — draft

> Status: **draft** (2026-10-05). Written by the agent from a conversation; **not in force** until approved. While it's a draft, v1 and v2 (above) are the intent in force, including "Out of scope: … other Mac functions that aren't audio". The v3 spec (`SPEC.md`, Part III) is also a draft and only fixes the spike; nothing from v3 gets built until this section is approved and the spike is a "go".

### Why a v3

I use the iPad as a second display for my Mac (Sidecar). To turn it on or off I have to be at the Mac: Control Center › Screen Mirroring › iPad. It's the same friction v1 removed for the volume: a Mac function I use often, behind a menu, when the device I'd like to press is the one I'm holding.

LevelDeck already has the hard part of a remote control for my Mac: an agent that lives in the menu bar and starts on its own, discovery, QR pairing, TLS-PSK with one key per device, revocation and reconnection. A second app would duplicate all of that (two agents, two pairings, two login items) for one more button. So the capability goes into LevelDeck.

### What LevelDeck becomes

From "remote control for the Mac's audio" to **"remote control for my Mac from my iPhone and iPad, starting with audio"**.

That's not a license to add anything. LevelDeck doesn't become a generic "control center" or a plugin system. Each new capability enters the way v2 and v3 did: its own section in this document, approved, with its own definition of "it works" and its own out of scope. Audio stays the core: it's what opens first and what gets the most space.

### What "it works" means

- From the iPhone or the iPad I see whether Sidecar is connected and to which iPad, and with one tap I connect or disconnect it.
- From the iPad itself, one tap and that iPad becomes the Mac's display. LevelDeck disappears behind Sidecar; that's expected. When Sidecar ends (from the iPad's sidebar, from the Mac or from the iPhone), LevelDeck comes back and reconnects on its own.
- If Sidecar is connected or disconnected outside LevelDeck (Control Center, the iPad's sidebar, closing the lid), every connected device reflects it. The v1 rule holds: both sides always tell the same truth.
- If Sidecar can't be controlled (a macOS update broke it, the iPad isn't eligible, Bluetooth or Handoff is off), LevelDeck says so plainly and **the audio works exactly the same**. Sidecar never takes the audio down with it.
- The display starts appearing within a few seconds of the tap, about as fast as from Control Center.

### What I want to control

1. Connect and disconnect Sidecar to any of my eligible iPads.

Nothing else in v3. Mirror vs. extend, the display arrangement and the sidebar or Touch Bar settings stay in System Settings › Displays.

### Principles

The v1 and v2 ones, with **one bounded exception** that this section asks to approve:

- **Apple-native, with one private framework, fenced.** Apple offers no public API to control Sidecar; the only clean route is the private `SidecarCore` framework (the UI-scripting alternative needs the Accessibility permission and breaks with every redesign of Control Center). v2 excluded private APIs for per-app volume (`SPEC.md` §20.3); v3 allows **this one** under four conditions:
  1. It's loaded at runtime, never linked. If it's missing or its shape changed, Sidecar shows as unavailable and nothing else is affected.
  2. It lives behind its own protocol, in its own module, like `AudioControlling`. The audio code doesn't know it exists.
  3. It's used only to act (connect, disconnect, list). Observing the state uses public APIs wherever possible.
  4. The exception doesn't extend to anything else. A future capability that also needs private APIs asks for its own exception.
- **The security model isn't touched.** Same pairing, same keys, same `hello`. What's new is what a paired device can do: take over a display of my Mac. Accepted, because paired devices are mine and revocation already exists.

### Out of scope (for v3)

- Everything still out from v1 and v2: App Store, control outside the local network, DAWs and media, other platforms.
- Other Mac functions (brightness, lock the screen, sleep, open apps, media keys). Each one, if it ever comes, needs its own section.
- AirPlay mirroring to a TV or another Mac, and Universal Control.
- Sidecar settings (mirror or extend, arrangement, sidebar, Touch Bar).
- Choosing wired vs. wireless Sidecar: whatever macOS picks.

### Open questions

- **Approve the private-framework exception?** It's the decision this whole section rests on. If not, v3 is dropped and the reason is documented: the alternative (UI scripting) contradicts "invisible on the Mac" and "simple before complete".
- **Spike before or after v2?** The spike doesn't touch the apps and can run at any moment; the implementation needs protocol v4 and the iPad layout (v2 Phases 7 and 8). Proposal: spike whenever, implementation after Phase 8.
- **Where it lives in the interface.** Proposal: on the iPad, a "Display" item in the sidebar (or a button in the toolbar); on the iPhone, a compact row above the mixer. It must not push the faders out of their place.
- **Is "LevelDeck" still the right name** for a remote control that does more than audio? Proposal: keep it; a "deck" is a control surface, and audio stays the core.
