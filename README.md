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
- Two-finger gestures pass through, so the gesture you use to enter sketch
  mode can also leave it, and two-finger page turns still work while sketching.

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

## Usage

- Enter sketch mode (gesture or Tools → Sketch → Enter sketch mode).
- Draw with the pen. The tool island at the bottom:
  - **Pen/Eraser** — toggles tool. The eraser deletes whole strokes it touches.
  - **N px** — cycles pen width (3/5/7/9).
  - **Undo / Redo** — per-session history, works across pages.
  - **Save** — saves and leaves sketch mode.
  - **Cancel** — discards everything drawn/erased this session, leaves mode.
  - Drag the island if it is in the way.
- Turn pages while sketching with a two-finger swipe.
- The device Back key saves and leaves sketch mode.

## Limitations (by design, for now)

- Pen and finger are treated identically in sketch mode (Android input
  limitation; palm rejection relies on the device's EMR palm rejection).
- Strokes are anchored to the page *as currently laid out*. For EPUBs,
  changing font size/margins/rotation after drawing will misplace sketches
  (an xpointer is stored per stroke for future re-anchoring).
- Fast (A2) refresh while drawing is binary black/white; a clean grayscale
  refresh runs ~0.6 s after you stop writing.
- No notes browser yet — planned: list of sketched pages with previews,
  integrated next to bookmarks.

---

# Development notes / handoff

Context dump for whoever (human or LLM) continues this work. Everything
below was established during initial development (July 2026) against
KOReader master and tested on a **Boox Go 10.3 gen 1** (Android, EMR pen,
1860×2480 mono e-ink).

## Working environment

- `D:\dev\koreader\` contains, besides this repo (`sketch.koplugin/`):
  - `koreader-src/` — shallow clone of koreader/koreader, for API reference.
  - `pencil-src/` — clone of mysticknits/pencil.koplugin: the Kobo-only
    stylus plugin this one's stroke engine was adapted from. Its
    `main.lua` (~4200 lines) is the best reference for anything not yet
    ported: bookmark sync, PNG capture of annotations, color picker,
    rotation handling, stroke grouping.
- No Lua interpreter on the dev machine (Windows). Syntax checking is done
  with `pip install luaparser` + `python -c "from luaparser import ast; ast.parse(open('main.lua', encoding='utf-8').read())"`.
  There is no runnable emulator on Windows; all behavioral testing is
  sideload-on-device (copy folder to `/sdcard/koreader/plugins/`, restart).
- KOReader-on-Android logs go to **logcat** (`adb logcat`), NOT crash.log.
  `logger.info` calls in this plugin are already in place at mode
  enter/exit and save/load.

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
   `ui:handleEvent(Event:new("Gesture", ges))`, which is what keeps the
   toggle gesture and two-finger page turns alive in sketch mode.
5. **Android framebuffer** (`koreader-base/ffi/framebuffer_android.lua`):
   `Screen.bb` is a persistent BBRGB32 you may paint into at any time
   outside the UIManager paint cycle. Every `refresh*(x,y,w,h)` call blits
   the **entire** bb to the ANativeWindow, then calls
   `android.einkUpdate(mode, delay, x, y, x+w, y+h)` — the e-ink update is
   region-limited but the blit is not. Refreshes are synchronous in the UI
   thread: while one runs, input events queue.
6. `InputContainer:_init()` creates `key_events`/`ges_events`/zone tables,
   so a plugin module with none of them registered survives stray
   `onGesture` dispatches (this matters because ReaderUI propagates every
   forwarded gesture through all its modules, including this plugin).

## Architecture (main.lua, ~900 lines)

- `Sketch` (plugin module, registered in ReaderUI): state, stroke engine,
  persistence, menu, Dispatcher action `sketch_toggle` → event
  `SketchToggle`.
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

## Performance: status, analysis, untried ideas

Status after first tuning pass: drawing works, user reports "still laggy,
maybe a bit faster". The native Boox notes app is instant because it uses
Onyx's **hardware pen overlay** (ink composited under the pen before
software sees it) — that is unreachable from a normal drawing path; the
realistic goal is "comfortable", not "native".

Current cost model (per refresh): full-bb JNI blit (1860×2480×4 ≈ 18 MB)
+ regional einkUpdate, synchronous in the input loop. At 33 ms cadence
during a stroke. Undo/redo/eraser/cleanup all use region-limited "ui"
refreshes (they were full-screen — that was the worst of the initial
slowness).

Untried ideas, roughly in order of expected value:

1. **Measure before optimizing further.** Wrap the `Screen:refreshFast`
   call in `time.now()` deltas and `logger.info` the ms cost (visible in
   logcat). If one refresh costs ≥33 ms, the cadence is self-defeating and
   should adapt (e.g. next-refresh-delay = 2× last measured cost).
   Also measure whether cost scales with region size or is ~fixed.
2. **Check which e-ink platform the launcher detected** (logcat prints it
   at startup; android-luajit-launcher has per-vendor EPD controllers,
   Onyx included). If the Onyx path isn't being hit, `refreshFast` may be
   falling back to a generic (slow) update. KOReader's Android e-ink
   settings (top menu → gear → Screen → E-ink) may also matter.
3. **Blit only the dirty rect.** The full-bb blit per refresh is plugin-
   invisible but fixable in `framebuffer_android.lua` (`_updateWindow`) —
   ANativeWindow_lock accepts a dirty rect. Could be prototyped as a
   KOReader user patch and upstreamed; would cut the fixed cost of every
   partial refresh dramatically on big screens.
4. **Coalesce input before refreshing:** instead of refreshing inside the
   pan handler, only accumulate the dirty region there and schedule the
   flush via `UIManager:nextTick` — all pan events queued in the same
   input batch then paint before one refresh. Combine with (1)'s adaptive
   interval.
5. **Cheaper undo/redo feel:** undo currently repaints the view + "ui"
   region refresh. Painting over the stroke area with `refreshFast` first
   and letting the delayed cleanup pass beautify later would make the
   button feel instant.
6. **The nuclear option for real latency: Onyx raw pen SDK.** Fork
   android-luajit-launcher, add JNI glue for
   `com.onyx.android.sdk.pen.TouchHelper`/RawInputCallback (needs a View —
   NativeActivity's content view may suffice; genuinely uncertain), let
   the hardware overlay draw the live stroke and only hand the final
   point list to Lua. This is the only route to native-app inking feel,
   and also the most work by far.
7. Track upstream: KOReader maintainers said (discussion #15039) that
   SimonLiu423 + mysticknits plan to bring annotation support into core.
   Check whether `registerStylusCallback` or similar has landed in
   koreader master since 2026-07; aligning with that API would obsolete
   parts of this plugin.

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

1. **Performance** (current focus — see above).
2. **Notes browser**: list of sketched pages for the current book
   (page number + stroke count, tap to jump), reachable from the Sketch
   menu; later PNG previews (pencil-src `captureGroupImage` shows how to
   render a page region to an image file) and integration next to the
   swipe-up bookmarks view.
3. Pen/finger discrimination via input_android user patch — explicitly
   LOW priority; only if it comes out clean. The mode-based UX is
   acceptable to the user.
4. Nice-to-haves: partial-stroke eraser, width picker dialog instead of
   cycling, per-page clear on the island, color support for color e-ink.
