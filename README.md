# Phonon Dictation

Hold the 🎤 key on your Mac, talk, and your words are typed into whatever app you're in.
Speech recognition runs locally with [Phonon-2](https://github.com/fermionresearch/phonon) (164 MB, English). No audio leaves the Mac, and nothing is logged or saved.

- **Hold to talk.** Text appears about every 5 seconds while you hold the key, and the rest is pasted when you let go.
- **No third-party tools.** A small Swift menu-bar app, plus macOS's own `hidutil` and Login Items.
- Needs Apple silicon and macOS 14 or later.

## Setup

```bash
git clone <this repo> && cd phonon-dictation
/opt/homebrew/bin/python3.13 -m venv .venv        # tested with Homebrew Python 3.13
.venv/bin/pip install fermion-research mlx mlx-audio mlx-lm soundfile scipy zstandard
xcode-select --install                            # if you don't have Apple's command line tools
./build.sh                                        # builds and installs ~/Applications/Phonon Dictation.app
open ~/Applications/"Phonon Dictation.app"        # first launch downloads the model (164 MB)
```

On first launch, allow **Microphone** and **Accessibility** (System Settings → Privacy & Security).
If one is missing, the 🎤 key beeps and the menu-bar menu says which permission to turn on.
Then turn on **Start at Login** in the menu-bar menu.

The app is signed locally (no Apple developer certificate), so after each rebuild macOS asks for the permissions again. Remove the old "Phonon Dictation" entry under Accessibility and allow the new one.

## How it works

| Piece | File |
|---|---|
| Menu-bar app; starts and stops everything | `Sources/main.swift` |
| Remaps 🎤 → F19 with `hidutil` and listens for F19 press and release | `Sources/HotKey.swift` |
| Microphone → 16 kHz mono | `Sources/Recorder.swift` |
| Decides which words are final and when to paste them | `Sources/Streamer.swift` |
| Runs `phonon serve` on 127.0.0.1:8010 and calls it | `Sources/Transcriber.swift` |
| Pastes with ⌘V, then restores your clipboard | `Sources/Paster.swift` |

**The 🎤 key.** On launch the app remaps the Dictation key (HID usage `0x0C/0xCF`) to F19, so Apple Dictation never sees it, and catches F19 with a Carbon hotkey. This hotkey needs no Input Monitoring permission. The remap lasts until logout, and quitting the app removes it, which gives the key back to Apple Dictation.

**Streaming.** About every 5 seconds the app transcribes the audio and pastes the new words that end more than 1 second before the end. Those words have enough context to be final. When you let go, the rest is pasted.

Each pass transcribes from where you started talking, or from your last pause of at least 0.3 s. It never starts in the middle of speech, because Phonon-2 often skips a whole sentence when a clip does that (about 1 in 5 clips in testing). Audio from before a pause is dropped once a dictation passes 20 seconds, so each pass stays fast.

**Cleanup.** Half a second of silence goes after each clip, because without it Phonon tends to invent a final "but" or "and". Words heard in near-silence are dropped, because the model sometimes invents an "Okay." there.

## Tests

```bash
Tests/run.sh
```

This generates speech with macOS `say`: normal and fast speech, a 55-second dictation, a short note, and an 8-second pause. It streams each clip through the same code the app uses and checks the pasted text against one transcription of the whole clip. Lost, doubled or invented words fail the test. It uses the app's Phonon server if the app is running, or starts one.
