# sketch.koplugin

Freehand **EMR pen drawing on book pages** for
[KOReader](https://github.com/koreader/koreader) on Android e-ink
devices. Written for — and only tested on — an **Onyx Boox Go 10.3**.

> **Disclaimer**: this entire plugin was written by Claude (Anthropic's
> Fable model), directed and device-tested by a human, for one specific
> device and use case. I'm just sharing it because it might work for
> others too. **Use at your own risk** — expect rough edges on anything
> that isn't a Boox Go 10.3 running KOReader v2026.03.

## Videos

*(coming soon)*

## What it does

KOReader on Android currently discards the stylus tool type, so the
plugin does not try to tell pen and finger apart. Instead it uses an
explicit **sketch mode**:

- Out of sketch mode: the plugin does nothing, KOReader behaves normally.
- In sketch mode: all single-contact input on the page is ink (pen or
  finger). A small draggable tool island offers
  **Pen/Eraser · width · Undo · Redo · Save · Clear · Cancel**.
- Pen input is captured at the input-frame level (below KOReader's
  gesture detector), so tiny strokes and stroke starts aren't swallowed
  and ink latency stays low.
- Multi-finger gestures are effectively unavailable while sketching (an
  accepted trade-off of that input capture); leave sketch mode with the
  island's **Save**/**Cancel** buttons or the device **Back** key.

Strokes are stored as vectors in the book's `.sdr` sidecar folder
(`sketch_strokes.lua`), keyed by page number, and re-rendered whenever
you revisit the page.

## Install

1. Copy the whole `sketch.koplugin` folder into KOReader's user plugin
   directory. On Android that is the `plugins` folder inside the KOReader
   data directory, typically:
   `/sdcard/koreader/plugins/sketch.koplugin/`
   (create the `plugins` folder if it doesn't exist).
2. Restart KOReader.
3. Open a book → menu → Tools (wrench icon, page 2) → **Sketch**.

Recommended setup:

- Assign the toggle to a gesture: menu → Settings → Taps and gestures →
  Gesture manager → e.g. *Two-finger tap, bottom right* → General →
  **Sketch: toggle drawing mode**.
- On Onyx/Boox devices, set a fast per-app refresh mode for KOReader
  (system E-ink center / app optimization → refresh mode → Speed, A2 or
  X): KOReader's live ink is displayed by Onyx's system-driven refresh,
  so this setting directly controls inking smoothness.

## Usage

- Enter sketch mode (gesture or Tools → Sketch → Enter sketch mode).
- Draw with the pen. The tool island at the bottom:
  - **Pen/Eraser** — toggles tool. The eraser deletes whole strokes it
    touches.
  - **N px** — opens a width picker (3/5/7/9) anchored to the button:
    it drops up when the island is in the lower half of the screen,
    down otherwise.
  - **Undo / Redo** — per-session history, works across pages.
  - **Save** — saves and leaves sketch mode.
  - **Clear** — clears all sketches on the current page (asks first;
    undoable while the session lasts).
  - **Cancel** — discards everything drawn/erased this session, leaves
    mode.
  - Drag the island if it is in the way.
- The device Back key saves and leaves sketch mode.
- Tools → Sketch → **Performance**: **Raw pen input** (full-fidelity,
  low-latency point capture; default on — turn it off if drawing ever
  misbehaves) and **Dirty-rect screen flush** (default off — measured
  slower than plain full blits on Onyx; kept for testing on other
  devices).

## Limitations & known issues

- Pen and finger are treated identically in sketch mode (Android input
  limitation; palm rejection relies on the device's EMR palm rejection).
- Strokes are anchored to the page *as currently laid out*. For EPUBs,
  changing font size/margins/rotation after drawing will misplace
  sketches (an xpointer is stored per stroke for future re-anchoring).
- Fast refresh while drawing is binary black/white; a clean grayscale
  refresh runs ~0.6 s after you stop writing.
- Multi-finger gestures don't work inside sketch mode (by trade-off, see
  above); everything works normally outside it.
- No notes browser (deliberate): bookmark the drawn page to find
  sketches again.
- The width picker crashed once on-device with no capturable traceback;
  it is now fully guarded — if the dialog ever fails, it logs
  `width picker failed` (visible via `adb logcat -s KOReader:V`) and
  falls back to cycling the widths, so the button keeps working either
  way. If you see the fallback happen, that log line is the bug report.
- If an island drag escapes the island frame in one event, inking can
  start mid-drag (rare; the container usually keeps the contact).
- "Nothing to undo/redo" InfoMessage briefly steals input.
- Strokes near the screen bottom draw over the island/footer area.
- Rendering assumes the view is painted fullscreen at origin.
- Eraser hits and undo/redo trigger a full reader repaint each (rate
  limited for the eraser) — correct but heavier than the inking path.

## Acknowledgements

This plugin stands on other people's work:

- [pencil.koplugin](https://github.com/mysticknits/pencil.koplugin) by
  **mysticknits** — the stroke engine (rendering, erasing, storage) was
  adapted from it, and its raw-input "slot domination" design validated
  this plugin's input approach. AGPL-3.0, like this plugin.
- [eraser.koplugin](https://github.com/SimonLiu423/eraser.koplugin) and
  the pencil.koplugin fork by **SimonLiu423** — groundwork for stylus
  support around KOReader.
- [KOReader](https://github.com/koreader/koreader) and
  [android-luajit-launcher](https://github.com/koreader/android-luajit-launcher)
  — the platform all of this runs on (and gets runtime-patched into).
- KOReader PR [#14862](https://github.com/koreader/koreader/pull/14862)
  (stylus callback API for plugins) and discussion
  [#15039](https://github.com/koreader/koreader/discussions/15039) —
  the upstream effort this plugin's input interception mirrors; once
  that API lands, this plugin should migrate to it.

License: **AGPL-3.0**.

## Architecture (main.lua, ~1500 lines)

- `Sketch` (plugin module, registered in ReaderUI): state, stroke engine,
  persistence, menu, Dispatcher action `sketch_toggle` → event
  `SketchToggle`.
- **Raw pen input** ("Raw pen input" section in main.lua, default on,
  setting `sketch_raw_input`): `Device.input.handleTouchEv` and
  `Input.resetState` are wrapped once (lazily, on first sketch-mode
  entry; wrappers are owner-rebound across plugin instances, never
  stacked). At each SYN_REPORT the frame's MTSlots are examined *before*
  gesture detection: a lone contact starting on the page is **claimed** —
  every point feeds the stroke engine directly (no PAN_THRESHOLD, no
  gesture round-trip) and the slot is stripped from MTSlots so the
  gesture detector never sees that contact (no island button mis-taps,
  no conflicting gestures). Island-area contacts are never claimed
  (buttons and dragging work normally), and claiming is refused while
  any dialog sits above the canvas. A second contact within 250 ms of a
  claim aborts the ink (region-limited wipe) and releases the slot; the
  released pair does NOT reassemble into two-finger gestures (the
  detector pairs buddy contacts at creation), so multi-finger gestures
  are unavailable in sketch mode — accepted. Later extra contacts
  (resting palm) are ignored and inking continues. Any Lua error in the
  raw path logs, reverts to gesture-based drawing for the session, and
  never breaks input. Claiming is also skipped under software rotation
  (the gesture path handles coordinate adjustment there).
- **Live ink**: painted directly into `Screen.bb` (stamped squares along
  segments — BlitBuffer has no line primitive), flushed with
  `Screen:refreshFast(region)` on an adaptive cadence: each flush is
  timed and the next minimum interval is 1.5× the measured cost, floored
  at 15 ms (`sketch_refresh_interval_ms` setting overrides the floor),
  with a trailing flush so slow strokes don't wait. A grayscale cleanup
  pass (`setDirty(view.dialog, "ui", region)`) runs 0.6 s after writing
  stops over the accumulated stroke bbox.
- **Fast flush** ("Fast flush" section; default OFF — the dirty-rect
  window lock measured ~2× slower than plain full blits on Onyx, see the
  experiment log; setting `sketch_fast_flush`, Android-only): patches
  `Screen._updateWindow` so that when `Screen._sketch_dirty_rect` is set
  (only ever around the live-ink flush), the ANativeWindow is locked
  with that rect and only it is blitted; every other refresh takes the
  stock full-blit path unchanged. Runtime failure → sticky fallback.
- **Per-stroke perf log**: every finalized pen stroke logs one
  `sketch-perf:` line (points kept/events seen, duration, flush count,
  avg/max flush ms, active paths) — `adb logcat -s KOReader:V`.
- `SketchCanvas` (fullscreen InputContainer window shown during sketch
  mode): registers fullscreen `ges_events` delegating to `Sketch`
  handlers (the gesture path is the fallback when raw input is off, and
  handles everything the raw path doesn't claim). Two mechanisms:
  - `handleEvent` bypass: while an ink contact is active, contact
    gestures skip the children so a stroke crossing the island isn't
    stolen by its buttons.
  - `onGesture` fallback: unmatched gestures are forwarded down to
    ReaderUI (with raw input off this restores two-finger pass-through).
- Tool island: FrameContainer in MovableContainer in BottomContainer,
  installed as `canvas[1]`. Hit-testing uses `toolbar_frame.dimen`. The
  island is rebuilt when its labels change; the MovableContainer drag
  offset is carried over so it stays where the user dragged it.
- Persistence: strokes (vector points + width + page + optional EPUB
  xpointer + datetime) in `<book>.sdr/sketch_strokes.lua` via
  `require("dump")`, loaded with `dofile`. Debounced save (1.5 s),
  flushed on page turn/suspend/close/mode exit. Guard: never save an
  empty list unless a load already succeeded.
- Rendering on revisit: `Sketch:paintTo` is a ReaderView view module —
  called on every ReaderView repaint, draws the current page's strokes +
  the in-progress stroke.
- Undo/redo: op stacks holding stroke object references; Cancel restores
  a shallow snapshot of the strokes array taken at mode entry (stroke
  objects are never mutated after finalization).
- Repaint rule (learned the hard way): `UIManager:setDirty` must target
  a *window-level* widget — this plugin uses `self.view.dialog`
  (ReaderUI). Targeting `self.view` enqueues only the e-ink refresh and
  repaints nothing.

## Performance experiment log *(dev section — remove in the final version)*

Summary of the measured baseline on the Go 10.3 (details in
[DEVNOTES.md](DEVNOTES.md)): input arrives at ~60 Hz and raw capture
keeps every point; a live-ink flush is a plain window lock + full 18 MB
blit + post at **avg 21–25 ms → ~25 flushes/s**; no einkUpdate is
involved (Onyx runs KOReader as "full-only": the system refresh displays
the ink, so the per-app refresh mode matters a lot).

- **#1 — direct regional einkUpdate** (2026-07-03). Made every live-ink
  flush also call `android.einkUpdate(fast=PARTIAL+DU, delay_fast, x, y,
  right, bottom)` through the launcher's reflection into hidden
  `View.refreshScreen`, hoping for a fixed fast waveform and earlier
  buffer release. **Verdict: FAILED — code removed.** Measurably slower
  (avg 56–58 ms vs 46–50 ms without), and strongly suspected of
  corrupting the window/EPD state: immediately after its use the
  dirty-rect lock started failing permanently, and a heavy dialog paint
  aborted natively (`FORTIFY: pthread_mutex_lock called on a destroyed
  mutex`). The Kotlin side's `preventSystemRefresh()` (waveform scheme
  "None" via reflection) is the suspected culprit. Do not reintroduce.
- **#2 — drop the dirty-rect flush, keep plain full blits**
  (2026-07-03). Accidental A/B from device logs: full-blit flushes avg
  21–25 ms / interval 34–43 ms vs dirty-rect 46–58 ms / interval
  66–91 ms — the dirty-rect lock's front-buffer copy-back serializes
  with the system refresh, while a plain dequeue doesn't (the 18 MB blit
  itself is only ~8 ms). **Verdict: ADOPTED — `sketch_fast_flush` now
  defaults OFF.** User-confirmed faster, especially with a fast Onyx
  per-app refresh mode. Live ink now flushes ~25×/s.

## Feature roadmap *(dev section — remove in the final version)*

1. Performance — usable after the 2026-07-03 overhaul + experiment #2;
   further ideas listed in [DEVNOTES.md](DEVNOTES.md).
2. Width-picker crash: guarded + self-diagnosing (see Limitations);
   awaiting a clean re-test, fix properly once a `width picker failed`
   log line surfaces.
3. Pen/finger discrimination via a koreader-base input patch —
   explicitly LOW priority; the mode-based UX is acceptable.
4. Nice-to-haves: partial-stroke eraser, color support for color e-ink.

---

Development notes for maintainers — working environment, verified
platform facts, measurement how-to, remaining performance ideas — live
in [DEVNOTES.md](DEVNOTES.md).
