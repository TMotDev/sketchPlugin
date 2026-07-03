# sketch.koplugin

Freehand drawing on book pages for KOReader — built for **Android e-ink devices
with EMR pens** (e.g. Onyx Boox), where KOReader receives pen input as ordinary
touch events.

Because KOReader on Android currently discards the stylus tool type, this
plugin does **not** try to tell pen and finger apart. Instead it uses an
explicit **sketch mode**:

- Out of sketch mode: the plugin does nothing, KOReader behaves normally.
- In sketch mode: all single-contact input on the page is ink (pen or finger).
  A small tool island offers **Pen/Eraser · width · Undo · Redo · Save · Cancel**.
- Multi-finger gestures are effectively unavailable while sketching (an
  accepted trade-off of the raw input capture); leave sketch mode with the
  island's **Save**/**Cancel** buttons or the device **Back** key.

Strokes are stored as vectors in the book's `.sdr` sidecar folder
(`sketch_strokes.lua`), keyed by page number, and re-rendered whenever you
revisit the page.

Stroke rendering/erasing/storage adapted from
[pencil.koplugin](https://github.com/mysticknits/pencil.koplugin) by
mysticknits (AGPL-3.0). This plugin is AGPL-3.0 as well.

## Install

1. Copy the whole `sketch.koplugin` folder into KOReader's user plugin
   directory. On Android that is the `plugins` folder inside the KOReader
   data directory, typically:
   `/sdcard/koreader/plugins/sketch.koplugin/`
   (create the `plugins` folder if it doesn't exist).
2. Restart KOReader.
3. Open a book → menu → Tools (wrench icon, page 2) → **Sketch**.

## Recommended setup

Assign the toggle to a gesture: menu → Settings → Taps and gestures →
Gesture manager → e.g. *Two-finger tap, bottom right* → General →
**Sketch: toggle drawing mode**.

On Onyx/Boox devices, also set a fast per-app refresh mode for KOReader
(system E-ink center / app optimization → refresh mode → Speed, A2 or X):
KOReader's live ink is displayed by Onyx's system-driven refresh, so this
setting directly controls inking smoothness.

## Usage

- Enter sketch mode (gesture or Tools → Sketch → Enter sketch mode).
- Tools → Sketch → **Performance** has two switches (both default on):
  **Raw pen input** (full-fidelity, low-latency point capture) and
  **Fast partial screen flush** (dirty-rect blitting). Turn one off if
  drawing ever misbehaves — that reverts to the slower but battle-tested
  path.
- Draw with the pen. The tool island at the bottom:
  - **Pen/Eraser** — toggles tool. The eraser deletes whole strokes it touches.
  - **N px** — cycles pen width (3/5/7/9).
  - **Undo / Redo** — per-session history, works across pages.
  - **Save** — saves and leaves sketch mode.
  - **Cancel** — discards everything drawn/erased this session, leaves mode.
  - Drag the island if it is in the way.
- The device Back key saves and leaves sketch mode.

## Limitations (by design, for now)

- Pen and finger are treated identically in sketch mode (Android input
  limitation; palm rejection relies on the device's EMR palm rejection).
- Strokes are anchored to the page *as currently laid out*. For EPUBs,
  changing font size/margins/rotation after drawing will misplace sketches
  (an xpointer is stored per stroke for future re-anchoring).
- Fast (A2) refresh while drawing is binary black/white; a clean grayscale
  refresh runs ~0.6 s after you stop writing.
- No notes browser (deliberate, decided 2026-07-03): bookmark the drawn
  page to find sketches again.

---

# Development notes / handoff

Context dump for whoever (human or LLM) continues this work. Everything
below was established during initial development (July 2026) against
KOReader master and tested on a **Boox Go 10.3 gen 1** (Android, EMR pen,
1860×2480 mono e-ink).

## Working environment

- `D:\dev\koreader\` contains, besides this repo (`sketch.koplugin/`):
  - `koreader-src/` — shallow clone of koreader/koreader, for API reference.
  - `koreader-base-src/` — shallow clone of koreader/koreader-base
    (`ffi/framebuffer_android.lua`, `ffi/input_android.lua` — the two files
    the performance work patches around).
  - `launcher-src/` — shallow clone of koreader/android-luajit-launcher
    (`assets/android.lua` = the `android` Lua module: JNI glue, FFI cdefs
    for ANativeWindow/ARect, `einkUpdate`; Kotlin EPD drivers under
    `app/src/main/java/org/koreader/launcher/device/`).
  - `pencil-src/` — clone of mysticknits/pencil.koplugin: the Kobo-only
    stylus plugin this one's stroke engine was adapted from. Its
    `main.lua` (~4200 lines) is the best reference for anything not yet
    ported: bookmark sync, PNG capture of annotations, color picker,
    rotation handling, stroke grouping. NOTE: on Kobo it also intercepts
    raw input by shipping a patched `frontend/device/input.lua` with a
    `registerStylusCallback` API that removes ("dominates") stylus slots
    from `MTSlots` before gesture detection — the same idea this plugin
    implements by wrapping the live Input instance (no core file edits).
- No Lua interpreter on the dev machine (Windows). Syntax checking is done
  with `pip install luaparser` + `python -c "from luaparser import ast; ast.parse(open('main.lua', encoding='utf-8').read())"`.
  There is no runnable emulator on Windows; all behavioral testing is
  sideload-on-device (copy folder to `/sdcard/koreader/plugins/`, restart).
- KOReader-on-Android logs go to **logcat** (`adb logcat`), NOT crash.log.
  `logger.info` calls in this plugin are already in place at mode
  enter/exit and save/load.
- **adb is set up and verified** against the device (USB debugging
  authorized; device serial 60F6786D, model "Go103").
  `adb logcat -d -s KOReader:V` shows the plugin's log lines.
  The KOReader/launcher startup lines rotate out of the buffer quickly —
  to see them, have the user exit + relaunch KOReader, then dump
  `adb logcat -d -t 500`.

## Verified platform facts (each cost real debugging time — trust these)

1. **Android input is tool-type-blind.** `koreader-base/ffi/input_android.lua`
   translates Android MotionEvents to KOReader touch slots keeping only
   x, y, pointer id, timestamp. Tool type (`TOOL_TYPE_STYLUS`/`ERASER`) and
   pressure are discarded. Hence the explicit-mode design: in sketch mode
   everything single-contact is ink. Pen/finger discrimination would need a
   koreader-base patch calling `AMotionEvent_getToolType()` via FFI —
   possibly doable as a runtime user patch (`koreader/patches/`), untried.
2. **UIManager delivers input ONLY to the topmost non-toast window**
   (`frontend/ui/uimanager.lua`, `sendEvent`). Lower windows get nothing
   unless flagged `is_always_active`. First version registered drawing
   touch zones on ReaderUI while showing a toolbar window above — buttons
   worked, drawing was completely dead. That is why the current design
   makes the fullscreen `SketchCanvas` window itself the drawing surface.
3. **Containers dispatch events children-first**
   (`widgetcontainer.lua:handleEvent` → `propagateEvent` before self). This
   is what gives the tool island's Buttons priority over the canvas's own
   fullscreen gesture handlers without any explicit routing.
4. **Gesture plumbing:** raw gestures arrive as `Event:new("Gesture", ges)`
   → `onGesture(self, ges)`. `ges_events` handlers get `(self, args, ges)`.
   `GestureRange` accepts `range = function() return geom end`. A contact
   produces `touch` immediately, then `pan`(+`pan_release`) or `hold`
   (+`hold_pan`/`hold_release`) or `tap`; a fast flick ends as `swipe`
   INSTEAD of `pan_release` (must finalize there too, or strokes hang).
   Multi-finger gestures (`two_finger_*`, pinch) are separate ges types —
   the canvas forwards anything it didn't register down to ReaderUI via
   `ui:handleEvent(Event:new("Gesture", ges))`. NOTE (2026-07-03,
   on-device): with raw input capture active this no longer produces
   working two-finger gestures in sketch mode — the first contact is
   claimed and released mid-stream, and the detector pairs buddy contacts
   only at contact creation, so the pair never assembles. Accepted as
   fine; exit is via the island buttons or the Back key. (With raw input
   toggled off, the old pass-through behavior returns.)
5. **Android framebuffer** (`koreader-base/ffi/framebuffer_android.lua`):
   `Screen.bb` is a persistent BBRGB32 you may paint into at any time
   outside the UIManager paint cycle. Every `refresh*(x,y,w,h)` call blits
   the **entire** bb to the ANativeWindow, then *may* call
   `android.einkUpdate(mode, delay, x, y, x+w, y+h)`. Refreshes are
   synchronous in the UI thread: while one runs, input events queue.
   **On Onyx, einkUpdate never runs for partial/UI/fast refreshes**
   (verified 2026-07-03 in launcher master): `OnyxEPDController.getMode()`
   returns `"full-only"` → `isEinkFull()` is false → `refreshFastImp` etc.
   are gated to the window blit alone, and the e-ink update is left to
   Onyx's system-driven refresh (their compositor watches posted buffers).
   Only full refreshes go through `requestEpdMode`, which reflects into
   hidden `View.refreshScreen`/`setWaveformAndScheme` methods — the Onyx
   SDK jar is not linked. So on this device the live-ink software cost is
   the blit, nothing else; e-ink waveform/latency for partials is decided
   by the Onyx system (per-app refresh mode applies, see Recommended
   setup).
6. `InputContainer:_init()` creates `key_events`/`ges_events`/zone tables,
   so a plugin module with none of them registered survives stray
   `onGesture` dispatches (this matters because ReaderUI propagates every
   forwarded gesture through all its modules, including this plugin).
7. **The gesture detector eats the start of every stroke.**
   `gesturedetector.lua`: a contact only leaves tapState for panState after
   moving `PAN_THRESHOLD` = `scaleByDPI(35)` ≈ 50 px ≈ 6 mm on the
   Go 10.3 (227 dpi) on one axis. Anything smaller ends as a `tap` → a
   dot; anything larger starts its pan with the first ~50 px collapsed.
   This — not refresh speed — is why tiny circles/letters were impossible.
8. **Raw input interception point.** In `Input:waitEvent`
   (`frontend/device/input.lua`), every raw event goes through
   `eventAdjustHook` (viewport translation etc.) and is then dispatched to
   `Input:handleTouchEv` — a plain instance method that can be wrapped at
   runtime. At `EV_SYN/SYN_REPORT` time, `Input.MTSlots` holds the parsed
   frame (array of per-slot tables `{slot=, id=, x=, y=}`, persistent
   across frames; `id == -1` means lift; on Android the tracking id equals
   the slot number). `GestureDetector:feedEvent(MTSlots)` runs *after*
   that point, and creates contacts lazily — so a slot can be hidden from
   it (remove the entry from MTSlots, cf. pencil's "domination") and even
   handed back mid-contact (it picks the contact up as a fresh down).
   `Input:resetState()` is the funnel for Android's ACTION_CANCEL / focus
   loss; wrap it to not leave a claimed contact hanging.
9. **Android input synthesis limits** (`base/ffi/input_android.lua`):
   only ACTION_DOWN/UP/POINTER_UP+DOWN/MOVE/CANCEL are translated —
   hover events never reach Lua; tool type and pressure are dropped;
   historical samples (`AMotionEvent_getHistorical*`) are NOT read, so the
   point rate is one point per delivered MotionEvent (~60 Hz batched by
   the display pipeline), not the EMR digitizer rate. The module's
   translation functions are file-local — raising the point rate needs a
   koreader-base patch (or shadowing the whole module via
   `package.loaded`), not a runtime wrap.
10. **The Android full-frame blit is patchable.**
   `framebuffer_android.lua:_updateWindow` locks the ANativeWindow with a
   nil dirty rect and blits the WHOLE shadow bb (18 MB on the Go 10.3) on
   every `refresh*()`. It is an instance method on `Device.screen`, and
   `ANativeWindow_lock` (cdef'd in the launcher's `android.lua`) accepts
   an `ARect*` in/out dirty-bounds parameter: pass the stroke bbox, blit
   only those rows, and the compositor copies the untouched area from the
   front buffer itself. The system may EXPAND the returned rect (e.g.
   right after a buffer reallocation) — always repaint what it returns.
   `refreshFastImp` = `_updateWindow()` + (only where `isEinkFull()`)
   region-limited `einkUpdate(fast,...)` — on Onyx the einkUpdate half is
   gated off (fact 5), so patching `_updateWindow` alone converts
   `Screen:refreshFast(region)` into a true partial flush, and the dirty
   rect doubles as a region hint to Onyx's system refresh.

## Architecture (main.lua, ~1450 lines)

- `Sketch` (plugin module, registered in ReaderUI): state, stroke engine,
  persistence, menu, Dispatcher action `sketch_toggle` → event
  `SketchToggle`.
- **Raw pen input** ("Raw pen input" section in main.lua, default on,
  setting `sketch_raw_input`): `Device.input.handleTouchEv` and
  `Input.resetState` are wrapped once (lazily, on first sketch-mode entry;
  wrappers are owner-rebound across plugin instances, never stacked). At
  each SYN_REPORT the frame's MTSlots are examined *before* gesture
  detection: a lone contact starting on the page is **claimed** — every
  point feeds the stroke engine directly (no PAN_THRESHOLD, no gesture
  round-trip) and the slot is stripped from MTSlots so the gesture
  detector never sees that contact (no island button mis-taps, no
  conflicting gestures). Island-area contacts are never claimed (buttons
  and dragging work normally). A second contact within 250 ms of a claim
  = multi-finger gesture attempt: ink is aborted (region-limited wipe) and
  the slot is released to the detector mid-stream. In practice the
  released pair does NOT reassemble into two-finger gestures (buddy
  pairing happens at contact creation, verified on device 2026-07-03) —
  multi-finger gestures are simply unavailable in sketch mode; the abort
  still matters because it wipes the stray dot such attempts leave. Later
  extra contacts (resting palm) are ignored and inking continues. While a
  claim is active all single-contact gesture handlers consume-and-ignore.
  Any Lua error in the raw path logs, reverts to gesture drawing for the
  session, and never breaks input. Claiming is skipped under software
  rotation (gesture path handles coordinate adjustment there).
- **Fast flush** ("Fast flush" section, default on, setting
  `sketch_fast_flush`, Android-only): `Screen._updateWindow` is patched
  (again owner-rebound, installed once). When `Screen._sketch_dirty_rect`
  is set — only ever around the live-ink `Screen:refreshFast(region)` in
  `maybeRefresh` — the patched method locks the ANativeWindow with that
  rect and blits only it (mirroring the stock format/inverse branches,
  honoring system-expanded bounds); every other refresh in KOReader takes
  the stock full-blit path unchanged. Runtime failure → log, sticky
  fallback to full blits, screen repaired with a stock update.
  `canFastFlush` additionally requires rotation 0 and no viewport.
- **Adaptive refresh cadence**: `maybeRefresh` times each flush and sets
  the next minimum interval to 1.5× the measured cost, floored at
  `refresh_interval_ms` (now 15 ms; still overridable via the
  `sketch_refresh_interval_ms` setting). Trailing flush unchanged.
- **Per-stroke perf log**: every finalized pen stroke logs one
  `sketch-perf:` line (points kept/events seen, duration, flush count,
  avg/max flush ms, lock/blit ms when the fast path ran, which paths are
  active). `adb logcat -s KOReader:V | grep sketch-perf`.
- `SketchCanvas` (fullscreen InputContainer window shown during sketch
  mode): registers fullscreen `ges_events` for touch/tap/hold/hold_pan/
  hold_release/pan/pan_release/swipe delegating to `Sketch:onSketch*`.
  Two special mechanisms:
  - `handleEvent` bypass: while `sketch.drawing_contact` is true,
    CONTACT_GESTURES skip the children entirely so a stroke crossing the
    island isn't stolen by its MovableContainer/Buttons. Verified working
    on device.
  - `onGesture` fallback: unmatched gestures → `abortInProgressContact()`
    (kills the stray dot from the first contact of a multi-finger gesture)
    → forward to ReaderUI.
- Tool island: FrameContainer in MovableContainer in BottomContainer,
  installed as `canvas[1]`. Hit-testing uses `toolbar_frame.dimen`
  (only valid after first paint). Island is REBUILT (not updated) when
  tool/width labels change — this resets its dragged position, a known
  wart.
- Live ink: painted directly into `Screen.bb` (`paintRect` stamped
  squares — BlitBuffer has no line primitive), refreshed with
  `Screen:refreshFast(region)` rate-limited to one per 33 ms with a
  trailing flush (`flush_scheduled`) so slow strokes don't wait for the
  next event. A grayscale `setDirty(view, "ui", region)` cleanup pass runs
  0.6 s after writing stops, region = accumulated bbox of strokes since
  last cleanup (`cleanup_region`).
- Persistence: strokes (vector points + width + page + optional epub
  xpointer + datetime) in `<book>.sdr/sketch_strokes.lua` via
  `require("dump")`, loaded with `dofile`. Debounced save (1.5 s), flushed
  on page turn/suspend/close/mode exit. Guard: never save an empty list
  unless a load already succeeded.
- Rendering on revisit: `Sketch:paintTo` is a ReaderView view module —
  called on every ReaderView repaint, draws current page's strokes +
  in-progress stroke.
- Undo/redo: op stacks holding stroke object references
  (`{type="add", stroke=}` / `{type="delete", strokes={}}`); Cancel =
  restore shallow snapshot of the strokes array taken at mode entry
  (stroke objects are never mutated after finalization, so this is safe).

## Performance: status, analysis, next steps

**2026-07-03 overhaul, device-tested the same day. User verdict: "way
better than before, not identical to native FreeMark but now usable".**
What shipped: raw input capture (kills the 50 px gesture threshold →
tiny strokes render, stroke starts aren't clipped, points captured at
input-frame time ahead of UIManager), dirty-rect window flush (kills the
18 MB full-frame blit per live-ink refresh), adaptive refresh cadence
(15 ms floor, backs off to 1.5× measured flush cost), per-stroke
`sketch-perf` logging, and a region-limited abort wipe. Everything is
toggleable (Sketch → Performance) and self-reverts on runtime errors, so
the worst case equals the previous behavior.

**Measured on device (2026-07-03, normal handwriting):**

    sketch-perf: stroke 30 pts (32 ev) in 599 ms; 9 flushes (9 fast)
      avg 47.4 max 53.0 ms; lock 39.4 blit 7.9 ms;
      raw=true flush=active interval=73

- Points ≈ events (25–37 per stroke, ~50/s while writing): raw capture
  keeps every input frame; the ~60 Hz MotionEvent ceiling (fact 9) is
  confirmed as the input rate.
- The dirty-rect blit works: **blit 7–8 ms** (the 18 MB blit is gone).
- The dominant cost is now **ANativeWindow_lock at 39–45 ms**: the lock
  blocks until the compositor frees a buffer, i.e. we wait for Onyx's
  system refresh to consume the previously posted frame. Total flush avg
  47–53 ms → the adaptive interval settles at ~70–90 ms (~12 flushes/s),
  which is exactly what keeps input responsive despite the slow lock.

To re-measure: `adb logcat -c`, draw, then
`adb logcat -d -s KOReader:V | Select-String sketch-perf` (PowerShell).
The mode-entry log line shows which paths are active
(`raw input: on - fast flush: active`).

Cost model per live-ink refresh on the Go 10.3: dirty-rect lock (blocks
on the compositor, ~40 ms) + region blit (~8 ms) + post — there is no
einkUpdate on this path at all (fact 5); the EPD update itself is
performed by Onyx's system refresh, whose waveform/latency follows the
per-app refresh mode. The native Boox notes app remains faster in
principle (hardware pen overlay, composited under the pen before software
sees anything); the remaining gap is the lock wait + the ~60 Hz input
rate, not our software path.

Remaining ideas, in order of expected value:

1. **Attack the ~40 ms lock wait.** Zero-code first: set Onyx's per-app
   refresh mode for KOReader (system E-ink center: Speed/A2/X modes) and
   compare `lock` in sketch-perf — a faster system waveform should free
   buffers sooner. Code-side afterwards: investigate
   `ANativeWindow_setBuffersGeometry` / buffer-count effects so the lock
   returns a free buffer immediately instead of waiting out the refresh.
2. **Raise the input rate** past ~60 Hz: `AMotionEvent_getHistorical*`
   samples are dropped in `base/ffi/input_android.lua` (fact 9). Options:
   koreader-base PR (clean, benefits everyone), or shadow the module from
   a user patch / plugin before Device init via `package.loaded`
   (fragile). EMR digitizers sample at 120–240 Hz, so this roughly
   doubles-to-quadruples curve fidelity for fast writing.
3. **Cheaper undo/redo feel:** undo currently repaints the view + "ui"
   region refresh. Painting over the stroke area with `refreshFast` first
   and letting the delayed cleanup pass beautify later would make the
   button feel instant.
4. **The nuclear option for real latency: Onyx raw pen SDK.** Fork
   android-luajit-launcher (the only layer a plugin genuinely cannot
   reach: Java/Kotlin), add
   `com.onyx.android.sdk.pen.TouchHelper`/RawInputCallback glue so the
   hardware overlay draws the live stroke and Lua only receives the final
   point list. Verified feasible in principle (2026-07-03): Saber
   (saber-notes/saber, `packages/onyxsdk_pen`) attaches
   `TouchHelper.create(view, callback)` to a plain `SurfaceView` inside a
   non-Onyx app; SDK on jitpack + `repo.boox.com`
   (`onyxsdk-pen:1.5.4`), needs `org.lsposed.hiddenapibypass`. Catches:
   the launcher's MainActivity is a NativeActivity that on Onyx runs
   view-less (`needsView()==false`) — a (transparent) View must be added
   to host TouchHelper (no precedent found for pure-native-content
   attachment); raw drawing mode locks out system refreshes while active;
   requires rebuilding the APK. Only route to native inking feel.
5. Track upstream (checked 2026-07-03): core stylus API is **PR #14862**
   (mysticknits, "add stylus callback API for plugin integration",
   open, milestone 2026.07) — adds
   `Input:registerStylusCallback`/`routeStylusEvents` doing exactly what
   our raw-input wrapper does (slot data before gesture detection,
   return true to swallow). When it lands, migrate `installRawInput` to
   that API. Nothing Android-side is planned there (tool type is still
   dropped in base's `input_android.lua`; the Kindle Scribe PR #14908
   and SDL-stylus draft #15344 don't touch Android), so the mode-based
   UX stays necessary either way.

## Known bugs / warts (beyond the by-design limitations above)

- Island's dragged position resets when its labels change (rebuild).
- Screen rotation or EPUB reflow misplaces strokes (no re-anchoring yet;
  pencil-src has rotation-handling code to steal).
- If an island drag escapes the island frame in one event, inking can
  start mid-drag (rare; MovableContainer usually keeps the contact).
- "Nothing to undo/redo" InfoMessage briefly steals input.
- Strokes near the screen bottom draw over the island/footer area.
- `paintTo` assumes the view is painted at origin 0,0 fullscreen.

## Feature roadmap (user-agreed priorities)

1. **Performance** — overhauled and device-tested 2026-07-03; usable now.
   Further work only if wanted (see remaining ideas above).
2. **Bug fixes** — next up; the user will provide the list.
3. ~~Notes browser~~ — DROPPED (2026-07-03, user decision): bookmarking
   the drawn page covers "find my sketches again"; don't build it.
4. Pen/finger discrimination via input_android user patch — explicitly
   LOW priority; only if it comes out clean. The mode-based UX is
   acceptable to the user.
5. Nice-to-haves: partial-stroke eraser, width picker dialog instead of
   cycling, per-page clear on the island, color support for color e-ink.
