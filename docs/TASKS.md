# OpenWisper — Technical task breakdown & fleet plan

Orchestrator: **Fable 5 (max)** — architecture, contracts, task decomposition,
final review/verification. Implementation is delegated to the Opus fleet in two
tiers per the operator's routing: **Opus 5 tier** = more complicated UI/backend,
**Opus 4.8 tier** = less complicated UI/backend. (Both tiers dispatch through
the `opus-developer` worker; the harness resolves the `opus` model alias to the
newest available Opus.)

## Ground rules (all Wave-A workers)

1. `Sources/OpenWisperCore/**` is **FROZEN**. Code against its contracts. If a
   contract genuinely blocks you, note it in your report — do not edit Core.
2. You own ONLY the paths listed for your task. Never touch another task's files.
3. `Package.swift` may be edited by **W1 only**, and only the `CWhisper`,
   `WhisperLocal`, `whisper-smoke` target entries.
4. Build discipline while Wave A runs in parallel: `swift build --target <yours>`
   (and running your own standalone executable target) ONLY. Never bare
   `swift build`, `swift test`, or `make` — other agents are writing files
   concurrently.
5. Zero third-party Swift dependencies. URLSession for HTTP.
6. No git operations, no commits.

## Wave A — parallel implementation

| # | Task | Tier | Owns |
|---|---|---|---|
| W1 | whisper.cpp vendoring + local engine + smoke test | Opus 5 (backend, hard) | `scripts/fetch_whisper.sh`, `scripts/download_model.sh`, `Sources/CWhisper/**`, `Sources/WhisperLocal/**`, `Sources/whisper-smoke/**`, `Resources/samples/`, Package.swift (its 3 targets) |
| W2 | Hotkey event tap + mic recorder + dictation state machine | Opus 5 (backend, hard) | `Sources/Spine/**`, `Tests/UnitTests/DictationControllerTests.swift` |
| W3 | Cloud STT + LLM cleanup + text insertion | Opus 4.8 (backend) | `Sources/CloudAI/**`, `Sources/InsertIO/**`, `Tests/UnitTests/{WavEncoderTests,CloudPayloadTests}.swift` |
| W4 | Floating recording pill (NSPanel + SwiftUI) + demo | Opus 5 (UI, hard) | `Sources/PillUI/**`, `Sources/pill-demo/**` |
| W5 | Menu bar UI + launch-at-login + app bundling | Opus 4.8 (UI) | `Sources/MenuBarUI/**`, `scripts/make_app.sh`, `Resources/Info.plist` |
| W6 | README (permissions walkthrough, build, config reference) | Opus 4.8 (docs) | `README.md` |

## Wave B — integration (Opus 5 tier)

Replace `Sources/OpenWisperApp/main.swift` with the real AppDelegate wiring
(engine/cleanup selection per config+env, permissions onboarding, status bar
actions, live engine switching), then: full `swift build -c release`,
`swift test`, `make app`, launch check, whisper smoke, fix every integration
issue anywhere in the tree, update this file's status column.

## Wave C — verification (Fable 5)

Review of hot paths (tap lifecycle, clipboard restore, state machine, linking),
independent rebuild + smoke, requirements checklist against the original spec,
README accuracy pass, final report.

## Status

| Task | Status |
|---|---|
| Scaffold (contracts, config, permissions, build skeleton) | done |
| W1 whisper engine | done — `make smoke` green: jfk.wav → correct transcript, 0.09 s inference on 11 s of audio (0.01× realtime), context stays resident, `unload()`/reload verified |
| W2 spine | done — event tap + recorder + state machine; 21 controller/hotkey tests green |
| W3 cloud + insertion | done — Groq/OpenAI STT, Groq/OpenAI/Anthropic cleanup, paste + type inserters; 30 payload/encoder tests green |
| W4 pill | done — `swift run pill-demo` cycles every state and exits 0; panel never becomes key |
| W5 menu bar + bundling | done — status item driven entirely by `StatusBarActions`; `make app` assembles + ad-hoc signs, `codesign --verify --strict` and `plutil -lint` both pass |
| W6 README | done |
| Wave B integration | done — real `AppDelegate` wiring (engine factory, live engine switching, config reload, onboarding, single-instance guard); tests migrated to swift-testing (58/58 green on this XCTest-less host); debug + release builds clean; bundle launches, survives, quits with exit 0 and no ggml Metal abort |
| Wave C verification | done — orchestrator review of EngineFactory/AppDelegate/OnboardingPrompt + hot paths (clipboard restore, event tap): no defects; independent re-run all green (58/58 tests, `make app` + strict codesign, launch ≥5 s alive, clean quit, `make smoke` OK); README reconciled with post-W6 behavior changes (model fallback, `CODESIGN_IDENTITY` install flow) |
| Wave D app window & history | done — `TranscriptHistoryStore` + `HistoryRecordingInserter` (DictationController untouched), `history` config section, `MainWindowUI` with History/Model/Permissions, programmatic main menu so ⌘C/⌘W work in an LSUIElement window, "Open OpenWisper…" in the status menu, `applicationShouldHandleReopen`, `make setup`, `window-demo` snapshots; 107/107 tests green, debug + release builds clean, bundle launches and quits cleanly |
| App icon (Sonnet worker, verified by Fable) | done — monkey artwork composited to the Big Sur squircle grid (824/1024, transparent corners, baked shadow), 10-size `AppIcon.icns` via iconutil, `CFBundleIconFile` + `make_app.sh` copy; design source kept in `Resources/AppIcon/` |
| Wave E solo UI restyle (Fable, operator-requested solo) | done — see Wave E below; 107/107 green after, six snapshots (light+dark) inspected, bundle launch/reopen/quit clean |
| Wave F distribution & consumer polish (Fable 5 + Cursor 4.5 fleet) | done — see Wave F below |
| Deploy/TCC repair (Fable) | done — operator hit "two OpenWispers" + grants that never stuck: dist *and* /Applications were LS-registered under one bundle ID with different ad-hoc CDHashes, and `make install` used to replace the bundle under a running instance (zombie + single-instance guard = launches silently swallowed). Fixes: install pre-quits and relaunches, `lsregister -f` install / `-u` dist, `make_app.sh` auto-picks the "OpenWisper Dev" identity when present, modal onboarding replaced by the window's Permissions page. README updated (tccutil clean-slate block). |

## Wave F — distribution & consumer polish

Goal: a non-technical user can download a DMG from a landing page, drag the
app to Applications, and be dictating minutes later — no clone, no terminal,
no dotfiles. Orchestrated by Fable 5; two scoped tasks delegated to Cursor 4.5
(grok) workers and reviewed by Fable.

| # | Task | Owner | Result |
|---|---|---|---|
| F1 | In-app model download — `ModelDownloader` (URLSession, progress, cancel, atomic move), download card on the Model page, engine re-resolve on finish | Fable 5 | done |
| F2 | In-app API keys — `Env.setValue` writer (0600, preserves unrelated lines), per-provider Add/Replace/Remove rows on the Model page, cloud engine card click opens the key field | Fable 5 | done |
| F3 | DMG packaging — `scripts/make_dmg.sh` + `make dmg` (UDZO, Applications symlink, READ ME FIRST.txt, versioned + stable names) | Cursor 4.5 | done — mounted, codesign-verified, idempotent |
| F4 | Non-technical copy pass over every user-facing string (no make/paths/env vars/LLM/whisper.cpp jargon; errors point at in-app fixes) | Cursor 4.5 | done — reviewed by Fable, one follow-up (warning alert button now opens the Model page) |
| F5 | Landing page — `docs/index.html` (GitHub Pages `main`/`docs`), download button → releases/latest DMG, Gatekeeper first-open walkthrough, light+dark | Fable 5 | done — verified in browser both appearances |

Verification: `swift build` clean, 117/117 tests (10 new Env-writer tests),
`window-demo` 6/6 PNGs (README screenshots regenerated with the new copy),
`make dmg` end-to-end + mount + strict codesign inside the image, model URL
resolves (200, 487.6 MB). Release flow: `make dmg`, then attach
`dist/OpenWisper.dmg` to a GitHub release; the site's download button uses
`releases/latest/download/OpenWisper.dmg`.

## Wave D — app window & history

Open-sourcing pass. OpenWisper was menu-bar-only (`LSUIElement`); this wave adds
the app window, a persistent local transcript history, and a one-command setup
for people arriving at a fresh clone.

| # | Task | Owns |
|---|---|---|
| D1 | Transcript history + config section | `Sources/OpenWisperCore/{TranscriptHistory,Config,AppPaths,Constants,Fakes}.swift`, `Tests/UnitTests/HistoryTests.swift` |
| D2 | The app window (History / Model / Permissions) | `Sources/MainWindowUI/**`, `Sources/window-demo/**`, Package.swift (its 2 targets) |
| D3 | App wiring | `Sources/OpenWisperApp/AppDelegate.swift`, `Sources/MenuBarUI/StatusBarController.swift` |
| D4 | `make setup` + docs | `Makefile`, `README.md`, `ARCHITECTURE.md`, `CLAUDE.md`, this file |

Design notes worth keeping:

- **History is a `TextInserter` decorator**, not a `DictationController`
  feature. `HistoryRecordingInserter` records the transcript and *then*
  delegates, so a paste that lands nowhere — or an `insert` that throws — still
  leaves the words recoverable. `DictationController` was not touched.
- **MainWindowUI follows the MenuBarUI pattern**: a `MainWindowActions` struct
  of closures, injected by the AppDelegate. The module never sees the engine,
  the cleaner or `Env`; API keys reach it as presence booleans only.
- **The main menu is load-bearing.** An `LSUIElement` app has no menu bar, so
  `⌘C`/`⌘V`/`⌘A`/`⌘W` do not work in its windows at all until `NSApp.mainMenu`
  exists. `AppDelegate.installMainMenu()` builds a minimal one that is never
  displayed; without it, one-click copy and the search field would be broken.
- **`window-demo` renders through `CALayer.render(in:)`, not
  `NSView.cacheDisplay`.** `cacheDisplay` walks the `draw(_:)` path, which
  catches SwiftUI content AppKit hosts in real views (`List` rows, `Form`
  scroll views) and silently misses everything drawn into the hosting view's
  own layer — page titles, the search field, the footer bar all came out blank.

### Wave D — verification log

| Step | Result |
|---|---|
| `swift build` / `swift build -c release` | clean; only the known cosmetic `swiftLanguageVersions:` manifest deprecation |
| `swift test` | `Test run with 107 tests in 7 suites passed` (83 before this wave) |
| `swift run window-demo <dir>` | exit 0, three PNGs written, no window ever appears |
| `make app` → `codesign --verify --strict` → `plutil -lint` | bundle assembled + ad-hoc signed, signature verifies, Info.plist lints |
| launch (`OPENWISPER_SKIP_ONBOARDING=1`) | alive ≥ 5 s, clean quit via Apple event, no ggml/Metal exit-abort, no crash report |

## Wave E — solo UI restyle (Fable 5, no fleet)

Operator asked for the window to stop looking like a stock settings pane —
"more inspired, more minimalistic, nicer colors and controls, homemade taste" —
and explicitly requested it be done solo by the orchestrator model. View layer
only; `MainWindowActions` / `MainWindowModel` plumbing from Wave D untouched.

- `Theme.swift` — the design language in one file: icon-derived palette
  (cornflower blue accent, fur-brown chips, face-cream hero, warm paper/charcoal
  backgrounds), every color a light/dark `NSAppearance` pair; SF Rounded for
  display type only; `OWCard` / `Chip` / `StatusChip` / capsule button styles /
  `HoverReader`.
- Custom chrome: hidden title bar + full-height sidebar (brand mark + rounded
  selection pills); `isMovableByWindowBackground` keeps the window draggable.
- History: transcript-first cards, hover-revealed Copy/Delete, Copy morphs to a
  green ✓, monkey-branded empty states. Model: the engine picker is four radio
  cards each carrying its own live status (model size on disk / key presence).
  Permissions: cream "you're all set" hero vs amber attention banner, tinted
  icon tiles, status chips.
- Brand image ships as a SwiftPM resource (`monkey-512.jpg`, 38 KB) resolved
  defensively (no `Bundle.module` trap); `make_app.sh` now copies `*.bundle`
  into `Contents/Resources`.
- `window-demo` renders each page in **both appearances** (six PNGs). Two
  capture fixes learned the hard way: a `.fullSizeContentView` window's layer
  tree renders scaled/cropped offscreen, so the demo keeps plain chrome; and
  the pure-SwiftUI layer tree bakes `contentsScale` into `render(in:)`, so the
  demo no longer pre-scales the context (the old explicit `scaleBy` drew
  everything double-sized once the AppKit `List`/`Form` views were gone).

### Wave B — verification log

Run from a clean `.build` with
`$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift`:

| Step | Result |
|---|---|
| `swift build` | clean, no warnings |
| `swift test` | `Test run with 58 tests in 4 suites passed` |
| `swift build -c release` | clean; only the known cosmetic `swiftLanguageVersions:` manifest deprecation |
| `make app` → `codesign --verify --strict` → `plutil -lint` | bundle assembled (3.0 MB, ad-hoc signed), signature verifies, Info.plist lints |
| launch (`OPENWISPER_SKIP_ONBOARDING=1`) | alive ≥ 7 s, hotkey tap armed, model preloaded in 8.06 s on a background task, no dyld/runtime errors |
| single-instance guard | second copy logs "already running" and exits 0; first keeps running |
| clean quit (Apple event) | exit 0 with the model resident — no `GGML_ASSERT` exit-abort |
| `make smoke` | OK, transcript correct, context resident across utterances |
| `swift run pill-demo` | exit 0, `app active: false`, `key window: none` |

**Test framework:** this host has Command Line Tools but no Xcode, so there is no
XCTest runtime — `swift test` could not even *build* the old suite. All four test
files were migrated to **swift-testing** (`import Testing`, `@Suite`/`@Test`,
`#expect`/`#require`), which the 6.3.3 toolchain does ship. Every assertion was
preserved; nothing was weakened or dropped.

**`ui.playSounds`** was documented in the README and ARCHITECTURE.md but had no
consumer anywhere in the tree — it fell between the Wave-A task boundaries. It is
implemented in `AppDelegate` off `DictationController.recordingStateChanged`
(Tink on start, Pop on stop), still defaulting to `false`.
