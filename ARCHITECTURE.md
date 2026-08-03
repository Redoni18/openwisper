# OpenWisper — Architecture

System-wide, local-first AI dictation for macOS (a self-hosted Wispr Flow).
Hold a hotkey → speak → release → cleaned-up text appears at the cursor of
whatever app has focus; double-tap the same key instead and the session locks
hands-free until you tap again. No accounts, no telemetry, fully offline with
the local model.

## Stack decisions

| Decision | Choice | Why |
|---|---|---|
| Language / UI | Swift 5.9+, AppKit + SwiftUI islands | Native access to CGEventTap, NSPasteboard, NSPanel, NSStatusItem, SMAppService; no Electron/Python runtime |
| Build | SwiftPM + Makefile + scripts | No Xcode project needed (host has CLT only); `make app` assembles the .app bundle |
| STT local | whisper.cpp via C API, statically linked | Model stays resident in RAM between utterances (no per-utterance model load); Metal GPU via embedded metallib source (no Xcode Metal toolchain required) |
| STT cloud | Groq / OpenAI `audio/transcriptions` | OpenAI-compatible; picked by `transcription.engine` config flag when a key exists |
| Cleanup | Groq / OpenAI / Anthropic chat API | Short strict prompt; hard timeout with fallback to the raw transcript |
| Insertion | Pasteboard + synthetic Cmd-V (default) or unicode typing | Paste is fast and reliable; the transcript stays on the clipboard by default as a paste-landed-nowhere safety net (`insert.copyToClipboard: false` restores the previous clipboard instead) |
| Min macOS | 14.0 | SMAppService (13+), modern SwiftUI |
| Dependencies | Zero third-party Swift packages | URLSession for HTTP; hermetic build |

## Runtime flow

```
      ┌────────────┐  flagsChanged/keyDown   ┌──────────────────┐
      │ CGEventTap │ ──────────────────────► │ HotkeyListener   │ (listen-only tap,
      │ (session)  │                         │  fn / named key  │  Input Monitoring)
      └────────────┘                         └───────┬──────────┘
                                              down / up / esc (main thread)
                                                     ▼
 ┌──────────────────────────── DictationController (state machine) ───────────────────────────┐
 │ hold    down → recording ─up→ processing ─done→ idle       esc → cancel                    │
 │ toggle  down → recording ─down→ processing ─done→ idle                                     │
 │ flow    down → recording ─┬─ up ≥ minHoldMs ──────→ processing ─done→ idle                 │
 │                           └─ up < minHoldMs → tapWait (still recording, one clip)          │
 │                                ├─ 2nd down ≤ doubleTapWindowMs → locked (hands-free;       │
 │                                │    next down stops+processes, its up is drained)          │
 │                                └─ window expires → discard, nothing processed              │
 │                           locked/toggle also auto-stop at transcription.maxSeconds         │
 │                                                                                            │
 │ recording:  Recorder (AVAudioEngine → 16 kHz mono Float32) ──levels──► Pill (recording)    │
 │ processing: Transcriber.transcribe(clip)          ──────────────────►  Pill (processing)   │
 │             └─ local: whisper.cpp ctx (resident)                                           │
 │             └─ cloud: WAV16 → Groq/OpenAI multipart                                        │
 │             TranscriptCleaner.clean(raw)  [timeout → raw]                                  │
 │             TextInserter.insert(text)                                                      │
 │             └─ HistoryRecordingInserter: append to history.json, THEN delegate             │
 │             └─ PasteboardInserter:       clipboard snapshot → Cmd-V → restore              │
 └────────────────────────────────────────────────────────────────────────────────────────────┘
                     ▲                            ▲                    ▲
        NSStatusItem menu (enable/disable,        │                    │
        engine, launch-at-login, window,   floating NSPanel pill   NSWindow (History /
        permissions, quit)                                         Model / Permissions)
```

History is recorded at **insertion** time, by a `TextInserter` decorator the
AppDelegate wraps around whichever inserter the config asks for — not by
`DictationController`, which knows nothing about it. The transcript is written
*before* the paste is attempted, so an insertion that lands nowhere (or throws)
still leaves the words recoverable in the History page.

## Module map (SwiftPM targets)

| Target | Contents | Owner task |
|---|---|---|
| `OpenWisperCore` | Frozen contracts (`Protocols.swift`), config + .env, permissions, constants, logging, fakes | Fable (scaffold) — **frozen during Wave A** |
| `CWhisper` | C headers/modulemap for whisper.cpp | W1 |
| `WhisperLocal` | `LocalWhisperTranscriber`, resident `whisper_context`, links `Vendor/whisper-install/lib` | W1 |
| `CloudAI` | `WavEncoder`, `CloudTranscriber` (Groq/OpenAI), `LLMCleaner` (Groq/OpenAI/Anthropic) | W3 |
| `InsertIO` | `PasteboardInserter` (snapshot → Cmd-V → restore), `TypeInserter` | W3 |
| `PillUI` | `PillController`: non-activating NSPanel + SwiftUI waveform pill — interactive (✕ cancels via `RecordingIndicator.onCancel`, drag to move, position persisted in UserDefaults). Two presentations: **notch-docked** (`NotchGeometry`/`NotchShape`/`NotchPillView` — a black shape drawn flush to the screen's top edge, centred on the camera cutout, so it reads as the notch expanding; all content sits below the cutout, which has no pixels) and **floating** (used on notch-less displays). | W4, redesigned solo |
| `MenuBarUI` | `StatusBarController`, launch-at-login (SMAppService), Info.plist + bundling script | W5 |
| `MainWindowUI` | The app window: `MainWindowController` (one AppKit `NSWindow`, hidden title bar, hosting SwiftUI) + `MainWindowModel` + the History / Model / Permissions pages. Talks to the app only through `MainWindowActions` closures, exactly as MenuBarUI does — it never sees the engine, the cleaner or the env. `Theme.swift` is the design language: an icon-derived palette (cornflower blue, fur brown, face cream over warm paper/charcoal), light+dark dynamic colors, card/chip/button styles; the brand image ships as a SwiftPM resource bundle that `make_app.sh` copies into the app. | Wave D; restyled solo (Wave E) |
| `Spine` | `HotkeyListener` (CGEventTap), `Recorder` (AVAudioEngine), `DictationController` | W2 |
| `OpenWisper` (exe) | AppDelegate wiring everything per config | Wave B integration |
| `whisper-smoke` (exe) | Offline E2E: model + jfk.wav → text | W1 |
| `pill-demo` (exe) | Visual pill check, cycles states, exits | W4 |
| `window-demo` (exe) | Offscreen PNG snapshots of each window page from canned state — every page in both appearances, six files. No TCC, no model, no visible window. Never links WhisperLocal. | Wave D |

## Engine & cleanup selection

- `transcription.engine`: `local` (default) · `groq` · `openai` · `auto`.
  `auto` = local if the model file exists, else groq if `GROQ_API_KEY`, else
  openai if `OPENAI_API_KEY`. A cloud engine without its key is a config error
  surfaced via the menu bar + pill error state, falling back to local when
  possible.
- `cleanup.provider`: `auto` (first of groq → openai → anthropic with a key) ·
  explicit provider. No key at all → cleanup silently skipped (offline mode);
  dictation still works with the raw transcript.
- Cleanup failure/timeout (`cleanup.timeoutSeconds`, default 6 s) → raw
  transcript is pasted. **The utterance is never lost.**

## Config file

`~/Library/Application Support/OpenWisper/config.json`, auto-created with
defaults on first run, tolerant of missing keys (each falls back to its
default). Schema (defaults shown):

```json
{
  "hotkey":        { "key": "fn", "mode": "flow", "minHoldMs": 250,
                     "doubleTapWindowMs": 300 },
  "transcription": { "engine": "local", "modelPath": null, "language": "en",
                     "groqModel": "whisper-large-v3-turbo",
                     "openaiModel": "whisper-1", "maxSeconds": 600 },
  "cleanup":       { "enabled": true, "provider": "auto", "model": null,
                     "timeoutSeconds": 6 },
  "insert":        { "mode": "paste", "restoreClipboardDelayMs": 600,
                     "copyToClipboard": true },
  "ui":            { "showPill": true, "playSounds": false, "useNotch": true },
  "history":       { "enabled": true, "maxEntries": 200 }
}
```

Hotkey names: `fn`, `rightCommand`, `leftCommand`, `rightOption`, `leftOption`,
`leftControl`, `rightControl`, `f13`…`f19`, or `keycode:NN`. `.env` lives next
to config.json (process env and a repo-root `.env` override it for dev runs).

`hotkey.mode` is `flow` (default: hold-to-talk *and* double-tap-to-lock on the
same key) · `hold` (pure push-to-talk) · `toggle` (tap on, tap off); anything
unrecognised falls back to `flow` with a log line. `minHoldMs` is the tap-vs-hold
threshold in both `hold` and `flow`; `doubleTapWindowMs` is `flow`-only and
bounded to 0…5000 ms by the controller so a nonsense value cannot hold the
microphone open. Existing config files that pin `"mode": "hold"` are unaffected.
Mode is re-read per event, so a config reload switches modes without a rebuild.

## Permissions model (documented in README)

| Permission | Used by | Why |
|---|---|---|
| Microphone | `Recorder` | capture speech (prompted by macOS on first record) |
| Input Monitoring | `HotkeyListener` | listen-only CGEventTap for the global hotkey |
| Accessibility | `PasteboardInserter`/`TypeInserter` | posting synthetic Cmd-V / keystrokes |

Also: System Settings → Keyboard → "Press 🌐 key to" must be **Do Nothing** so
holding fn doesn't trigger Apple's emoji picker/dictation.

## Threading model

- Hotkey callbacks are marshalled to the **main thread**; `DictationController`
  is `@MainActor`.
- Audio taps run on AVAudioEngine's render thread; samples accumulate under a
  lock; level callbacks are throttled ≤ 20 Hz.
- whisper.cpp inference runs on a background executor (it is CPU/GPU-heavy and
  blocking); the context is created once and reused (serialized access).
- UI (pill, status item) is main-actor only.

## Failure policy

| Failure | Behavior |
|---|---|
| Hold shorter than `minHoldMs` (`hold` mode) | discard silently (accidental tap) |
| Single tap not doubled inside `doubleTapWindowMs` (`flow` mode) | keep recording until the window expires, then discard silently — same outcome as the accidental tap above, just decided ~300 ms later |
| Esc while holding, in the tap-wait window, or hands-free | cancel, nothing inserted |
| Hands-free session reaches `transcription.maxSeconds` | auto-stop and process, exactly as if the user had stopped it (never leave the mic open) |
| Mic permission missing | pill error + menu hint, System Settings deep link |
| Tap creation fails (Input Monitoring) | menu shows warning state; "Recheck permissions" retries |
| Model file missing (local engine) | pill error "Run make model", menu hint |
| Cloud STT error/timeout | pill error with short reason |
| Cleanup error/timeout | **fallback to raw transcript** (never lose the utterance) |
| Empty transcript | brief "empty" error state, nothing inserted |
| Clipboard changed by another app before restore | skip restore (never clobber) |

## Privacy

No accounts, no telemetry, no network I/O at all unless a cloud engine or
cleanup provider is configured with a key. Audio never touches disk (RAM only).
Logs go to the local unified log only, and no transcript text is ever logged.

The one thing written to disk that contains user speech is
`history.json` (`TranscriptHistoryStore`): the inserted transcript, its
timestamp and the engine that produced it, appended at insertion time, capped at
`history.maxEntries` (default 200, oldest dropped), mode `0600`, never sent
anywhere. `history.enabled: false` stops it; "Clear All" in the window (or
deleting the file) removes it.

## Build pipeline

```
make setup  # deps → model → install → open. The fresh-clone path.

make deps   # clone whisper.cpp @ pinned tag → cmake static build (Metal embedded)
            # → merge .a's into Vendor/whisper-install/lib/libwhisper_merged.a
            # → copy headers into Sources/CWhisper/include
make model  # download ggml-small.en.bin → ~/Library/Application Support/OpenWisper/models
make app    # swift build -c release → dist/OpenWisper.app (LSUIElement, ad-hoc signed)
make install
```

Ad-hoc signing means TCC grants must be re-done after rebuilds; README explains
the stable self-signed-certificate alternative.
