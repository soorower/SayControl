# SayControl

**Speak. It's written.**

Hold **fn**, talk, let go: your words are typed wherever the cursor is, in any
app on your Mac. Hold **fn** and **control** together and say what to change
instead ("make it shorter", "turn this into a polite email"), and the
selection, or the whole box, is rewritten in place.

A menu-bar app in plain Swift and AppKit for macOS 13 or later, Apple Silicon
and Intel. This repository is the whole app, under the [MIT licence](LICENSE).
The site is [saycontrol.com](https://saycontrol.com).

## Where your words are written

Settings › Models keeps two jobs apart: **transcription** turns your voice
into text, and **polish** tidies that text (and runs command mode). Each can
run in one of these places:

- **SayControl Cloud.** Your voice goes to SayControl's server, which has it
  transcribed by third-party providers and polished, and sends back the text.
  Nothing to set up. Free has a weekly allowance; Pro has none.
- **This Mac** (transcription only). Open models run on the Mac itself and
  need no internet: Cohere Transcribe, Qwen3-ASR, Parakeet, Nemotron, Voxtral
  and Whisper. Most of them write while you talk. Which ones keep up live is
  measured on your own Mac the first time each one loads; the rest write when
  you let go.
- **Your own API key.** Transcription on OpenAI, ElevenLabs, AssemblyAI,
  Soniox, xAI, Google, OpenRouter and others; polish on Claude, OpenAI,
  OpenRouter, Cerebras, Groq or Google, with the models your key can use.
  Connect checks a key with its provider before saving it, and your provider
  bills you.

**Where this stands today:** the release on saycontrol.com runs on SayControl
Cloud and asks you to sign in. The Models page, with This Mac and your own
key, is in the dev build (see [Building](#building)), which also asks you to
sign in for now.

## What it does

- **Learns your words.** Fix a word right after it lands and the fix is
  remembered, with the word beside it when the mishearing is a real word, so
  "art browser" becomes "Arc browser" without touching "art" anywhere else.
- **Reads the room.** As you start, it skims the front window for names and
  jargon and hands them to the recognizer, so they come out spelled right.
  ("Read the screen for names" in Settings turns it off.)
- **Cleans up and writes in your register.** Ums and false starts go before
  the text is pasted, and **Tones** picks casual through formal for Personal,
  Work, Email and Agents, by the app you're dictating into. A tone changes
  punctuation, casing and layout, never your words.
- **Phrases.** Say "my email address" and your address lands in full; an
  expansion is pasted exactly as you wrote it.
- **Spoken controls.** "Scratch that", "send it", "take a screenshot", "copy
  the file path", "attach the PDF from downloads", "open terminal in the
  downloads folder".
- **Commands in the terminal.** Dictate "add everything and commit saying ship
  the fix" into a terminal and
  `git add . && git commit -m "ship the fix"` arrives at the prompt. Every
  command it can write is spelled out in [`Sources/Shell.swift`](Sources/Shell.swift);
  no model invents one, and nothing runs until you press Return.
- **A voice for your coding agents.** Claude Code and Codex tell you out loud
  when they finish or need you, and you answer them by voice.

## Private by design

Your history, recordings, dictionary, phrases and daily totals stay on your
Mac, in `~/.config/sayctrl`. Local model weights live in
`~/Library/Application Support/SayCtrl/Models`, and **Delete** removes them.
On This Mac your voice goes nowhere. On your own key it goes to that
provider. On SayControl Cloud your voice and text pass through SayControl's
server; what is kept, and for how long, is in the
[privacy policy](https://saycontrol.com/privacy). "Read the screen for names"
is the one setting that sends more than your voice, and it says so.

## Building

```sh
./scripts/build.sh                 # SayControl.app, the shipping app (com.sayctrl.app)
SAYCTRL_DEV=1 ./scripts/build.sh   # "SayCtrl Dev.app" (com.sayctrl.app.dev)
```

Needs macOS 13 or later, the Xcode command line tools and cmake. The first
build fetches [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
[CrispASR](https://github.com/CrispStrobe/CrispASR) and
[Sparkle](https://sparkle-project.org) at pinned versions into `vendor/` and
compiles the speech engines, which takes a few minutes; later builds reuse
them. The app is one universal binary with the engines compiled in: Metal on
Apple Silicon, the CPU on Intel. Model weights download from Hugging Face
when you pick one.

The two builds are two apps to macOS, with their own settings
(`~/.config/sayctrl-dev` for the dev one) and their own privacy grants, so
they can run side by side. `Config.retail` decides which UI a copy shows: the
shipping app keeps to what the release offers, and the dev build keeps every
provider, every key box and the dev tools. `SAYCTRL_RETAIL=1` previews the
shipping UI in a dev build.

Builds are signed with the hardened runtime and
[`SayCtrl.entitlements`](SayCtrl.entitlements) (microphone, Apple Events),
by whichever Apple certificate the keychain has (`SIGN_IDENTITY` overrides).
Without one the build is signed ad-hoc: it runs, but every rebuild is a new
app to macOS, so it asks for Accessibility, Input Monitoring and the
microphone again.

`Sources/` is the app, `scripts/` the build and release tooling (with
`scripts/engines/`, the glue around CrispASR), `Resources/` the sounds, font
and voice clips that ship in the bundle, `design/` the HTML mock-ups each
screen was built from, and `gpu-server/` an experiment that runs two models
on a rented GPU for the dev build's Own GPU provider.

Releases are cut by `scripts/release.sh`: notarised DMG, update zip and a
signed Sparkle appcast. It needs the Developer ID certificate, a notary
profile and the Sparkle signing key, so only official releases go through it.

## Credits

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and ggml (MIT) run
  Whisper and Parakeet.
- [CrispASR](https://github.com/CrispStrobe/CrispASR) (MIT) runs Cohere
  Transcribe, Qwen3-ASR, Voxtral and Nemotron. `scripts/engines/qwen3_run.cpp`
  and `voxtral4b_run.cpp` are adapted from its command-line examples, and
  `nemotron_stream.cpp` builds on its Nemotron backend; both projects are
  Copyright (c) 2023-2026 The ggml authors.
- [Sparkle](https://sparkle-project.org) (MIT) installs updates.
- [Bricolage Grotesque](https://github.com/ateliertriay/bricolage), under the
  SIL Open Font License ([`Resources/Fonts/OFL.txt`](Resources/Fonts/OFL.txt)).
- The models, downloaded from Hugging Face, are their makers' work under
  their own licences: Cohere Transcribe, Qwen3-ASR and Voxtral (Apache 2.0),
  Parakeet (NVIDIA, CC BY 4.0), Nemotron (NVIDIA, OpenMDW 1.1) and Whisper
  (OpenAI, MIT).

## Licence and name

The code is MIT: use it, change it, ship it. The licence covers the code, not
the SayControl name or icon, so a copy you ship should go by its own name.
Found a security problem? See [SECURITY.md](SECURITY.md).
