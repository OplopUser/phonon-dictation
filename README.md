# Phonon Dictation

Hold the 🎤 key on your Mac, talk, and your words are typed into whatever app you're in.
Speech recognition runs locally with [Phonon-2](https://github.com/fermionresearch/phonon) (164 MB, English). No audio leaves the Mac, and nothing is logged or saved.

- **Hold to talk, or press to start and press again to stop.** Pick the mode in the menu-bar menu; the app remembers it. Text appears about every 5 seconds while recording, and the rest is pasted when you stop.
- **Spoken cues:** it says "Start" when it begins listening and "Stop" when it stops. You can turn them off in the menu.
- **No third-party tools.** A small Swift menu-bar app, plus macOS's own `hidutil` and Login Items.
- Needs Apple silicon and macOS 14 or later.

## Setup

```bash
git clone <this repo> && cd phonon-dictation
/opt/homebrew/bin/python3.13 -m venv .venv        # tested with Homebrew Python 3.13
.venv/bin/pip install fermion-research mlx mlx-audio mlx-lm soundfile scipy zstandard
xcode-select --install                            # if you don't have Apple's command line tools
scripts/create-signing-identity.sh                # local signing certificate, so permissions survive rebuilds
./build.sh                                        # builds and installs ~/Applications/Phonon Dictation.app
open ~/Applications/"Phonon Dictation.app"        # first launch downloads the model (164 MB)
```

The app needs **Microphone** and **Accessibility** access (Accessibility lets it paste). If either is missing when you press 🎤, the app asks for it then and there: it shows the macOS prompt or opens the right page in System Settings. Then press 🎤 again.
Turn on **Start at Login** in the menu-bar menu.

`scripts/create-signing-identity.sh` makes a self-signed certificate in your login keychain, and `build.sh` signs with it. macOS ties permissions to the app's signature. With the certificate the signature stays the same across rebuilds, so you only grant permissions once. Without it, the app is signed ad hoc, and every rebuild looks like a new app that needs the permissions again.

## How it works

| Piece | File |
|---|---|
| Menu-bar app: menu, hold or press-to-start/stop mode, permissions; starts and stops everything | `Sources/main.swift` |
| Remaps 🎤 → F19 with `hidutil` and listens for F19 press and release | `Sources/HotKey.swift` |
| Microphone → 16 kHz mono | `Sources/Recorder.swift` |
| Decides which words are final and when to paste them | `Sources/Streamer.swift` |
| Runs `phonon serve` on 127.0.0.1:8010 and calls it | `Sources/Transcriber.swift` |
| Pastes with ⌘V, then restores your clipboard | `Sources/Paster.swift` |

**The 🎤 key.** On launch the app remaps the Dictation key (HID usage `0x0C/0xCF`) to F19, so Apple Dictation never sees it, and catches F19 with a Carbon hotkey. This hotkey needs no Input Monitoring permission. The remap lasts until logout, and quitting the app removes it, which gives the key back to Apple Dictation.

**Streaming.** About every 5 seconds the app transcribes the audio and pastes the new words that end more than 1 second before the end. Those words have enough context to be final. When you let go, the rest is pasted.

Each pass transcribes from where you started talking, or from your last pause of at least 0.3 s. It never starts in the middle of speech, because Phonon-2 often skips a whole sentence when a clip does that (about 1 in 5 clips in testing). Audio from before a pause is dropped once a dictation passes 20 seconds, so each pass stays fast.

**Spoken cues.** `build.sh` generates "Start" and "Stop" with macOS `say`. The mic would hear "Start" and Phonon would type it, so each recording stays muted until the word ends, plus 0.2 s for speaker delay (about 0.55 s in total). "Stop" plays after the mic is off.

**Cleanup.** Half a second of silence goes after each clip, because without it Phonon tends to invent a final "but" or "and". Words heard in near-silence are dropped, because the model sometimes invents an "Okay." there.

## Tests

```bash
Tests/run.sh
```

This generates speech with macOS `say`: normal and fast speech, a 55-second dictation, a short note, and an 8-second pause. It streams each clip through the same code the app uses and checks the pasted text against one transcription of the whole clip. Lost, doubled or invented words fail the test. It uses the app's Phonon server if the app is running, or starts one.
