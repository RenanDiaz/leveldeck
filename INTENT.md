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
