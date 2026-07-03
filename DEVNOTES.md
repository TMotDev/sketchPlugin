# Development notes / handoff

Context for whoever (human or LLM) continues this work. Established
during development (July 2026) against KOReader **v2026.03** (installed
on device; `koreader-src` clone is master — the two matched for every
API used here), tested on a **Boox Go 10.3 gen 1** (Android 12, EMR pen,
1860×2480 mono e-ink, 227 dpi, serial 60F6786D "Go103").

## Working environment

- `D:\dev\koreader\` contains, besides this repo (`sketch.koplugin/`):
  - `koreader-src/` — shallow clone of koreader/koreader for API
    reference; tag `v2026.03` fetched too (`git show v2026.03:<path>` to
    read the exact installed sources).
  - `koreader-base-src/` — shallow clone of koreader/koreader-base
    (`ffi/framebuffer_android.lua`, `ffi/input_android.lua`).
  - `launcher-src/` — shallow clone of koreader/android-luajit-launcher
    (`assets/android.lua` = the `android` Lua module: JNI glue, FFI
    cdefs for ANativeWindow/ARect, `einkUpdate`; Kotlin EPD drivers
    under `app/src/main/java/org/koreader/launcher/device/`).
  - `pencil-src/` — clone of mysticknits/pencil.koplugin (Kobo-only).
    Its stroke engine was adapted here. On Kobo it intercepts raw input
    by shipping a patched `frontend/device/input.lua` with a
    `registerStylusCallback` API that removes ("dominates") stylus slots
    from `MTSlots` before gesture detection — the same idea this plugin
    implements by wrapping the live Input instance (no core file edits).
- No Lua interpreter on the dev machine (Windows). Syntax checking:
  `pip install luaparser` then
  `python -c "from luaparser import ast; ast.parse(open('main.lua', encoding='utf-8').read())"`.
  No runnable emulator on Windows; all behavioral testing is
  sideload-on-device (copy folder to `/sdcard/koreader/plugins/`,
  restart KOReader).
- adb is set up and authorized against the device.

## Measuring & debugging

- KOReader-on-Android logs go to **logcat** (`adb logcat -s KOReader:V`),
  NOT crash.log (which doesn't exist on Android even after a Lua crash —
  the crash window on screen is the only place the traceback shows).
- Per-stroke perf: `adb logcat -c`, draw, then
  `adb logcat -d -s KOReader:V | Select-String sketch-perf` (PowerShell).
  Line format: `N pts (M ev)` = points kept / input frames offered
  (~60/s expected); `avg/max` flush ms; `lock/blit` ms (only non-zero on
  the dirty-rect path); `flush=` state; `interval=` the adaptive cadence.
  The mode-entry line lists which paths are active.
- NATIVE crash (FORTIFY / SIGABRT): reproduce, then IMMEDIATELY
  `adb logcat -d -b crash` — the tombstone rotates out fast. A KOReader
  crash *window* on screen = Lua error (its traceback is only there).
- KOReader/launcher startup lines rotate out of the logcat buffer
  quickly — have the user exit + relaunch, then dump
  `adb logcat -d -t 500`.

## Verified platform facts (each cost real debugging time — trust these)

1. **Android input is tool-type-blind.** `koreader-base/ffi/input_android.lua`
   translates Android MotionEvents to KOReader touch slots keeping only
   x, y, pointer id, timestamp. Tool type (`TOOL_TYPE_STYLUS`/`ERASER`)
   and pressure are discarded. Hence the explicit-mode design. The
   `AMotionEvent_getHistorical*`/`getToolType` symbols aren't even used
   (getToolType isn't cdef'd in the launcher glue).
2. **UIManager delivers input ONLY to the topmost non-toast window**
   (`frontend/ui/uimanager.lua`, `sendEvent`). Lower windows get nothing
   unless flagged `is_always_active`. That is why sketch mode makes the
   fullscreen `SketchCanvas` window itself the drawing surface.
3. **Containers dispatch events children-first**
   (`widgetcontainer.lua:handleEvent` → `propagateEvent` before self):
   the tool island's Buttons get priority over the canvas's fullscreen
   gesture handlers without explicit routing.
4. **Gesture plumbing:** raw gestures arrive as `Event:new("Gesture", ges)`
   → `onGesture(self, ges)`. `ges_events` handlers get
   `(self, args, ges)`. `GestureRange` accepts
   `range = function() return geom end`. A contact produces `touch`
   immediately, then `pan`(+`pan_release`) or `hold`
   (+`hold_pan`/`hold_release`) or `tap`; a fast flick ends as `swipe`
   INSTEAD of `pan_release` (must finalize there too). Multi-finger
   gestures are separate ges types. NOTE (on-device): with raw input
   capture active, forwarding unmatched gestures to ReaderUI no longer
   yields working two-finger gestures in sketch mode — the claimed first
   contact is released mid-stream and the detector pairs buddy contacts
   only at contact creation, so the pair never assembles. Accepted; with
   raw input toggled off the old pass-through behavior returns.
5. **Android framebuffer** (`koreader-base/ffi/framebuffer_android.lua`):
   `Screen.bb` is a persistent BBRGB32 you may paint into at any time
   outside the UIManager paint cycle. Every `refresh*(x,y,w,h)` call
   blits the **entire** bb to the ANativeWindow, then *may* call
   `android.einkUpdate(mode, delay, x, y, x+w, y+h)`. Refreshes are
   synchronous in the UI thread: while one runs, input events queue.
   **On Onyx, einkUpdate never runs for partial/UI/fast refreshes**:
   `OnyxEPDController.getMode()` returns `"full-only"` → `isEinkFull()`
   is false → `refreshFastImp` etc. are gated to the window blit alone,
   and the e-ink update is left to Onyx's system-driven refresh (their
   compositor watches posted buffers; the per-app refresh mode applies).
   Only full refreshes go through `requestEpdMode`, which reflects into
   hidden `View.refreshScreen`/`setWaveformAndScheme` methods — the Onyx
   SDK jar is not linked in the launcher.
6. `InputContainer:_init()` creates `key_events`/`ges_events` tables, so
   a plugin module with none registered survives stray `onGesture`
   dispatches (ReaderUI propagates every forwarded gesture through all
   its modules, including this plugin).
7. **The gesture detector eats the start of every stroke.**
   `gesturedetector.lua`: a contact only leaves tapState for panState
   after moving `PAN_THRESHOLD` = `scaleByDPI(35)` ≈ 50 px ≈ 6 mm on the
   Go 10.3 on one axis. Anything smaller ends as a `tap` → a dot;
   anything larger starts its pan with the first ~50 px collapsed. This
   — not refresh speed — is why tiny circles/letters were impossible
   before raw input capture.
8. **Raw input interception point.** In `Input:waitEvent`
   (`frontend/device/input.lua`), every raw event goes through
   `eventAdjustHook` (viewport translation etc.) and is then dispatched
   to `Input:handleTouchEv` — a plain instance method that can be
   wrapped at runtime. At `EV_SYN/SYN_REPORT` time, `Input.MTSlots`
   holds the parsed frame (array of per-slot tables `{slot=, id=, x=,
   y=}`, persistent across frames; `id == -1` means lift; on Android the
   tracking id equals the slot number). `GestureDetector:feedEvent`
   runs *after* that point and creates contacts lazily — so a slot can
   be hidden from it (remove the entry from MTSlots, cf. pencil's
   "domination") and even handed back mid-contact.
   `Input:resetState()` is the funnel for Android's ACTION_CANCEL /
   focus loss; wrap it to not leave a claimed contact hanging.
9. **Android input synthesis limits** (`base/ffi/input_android.lua`):
   only ACTION_DOWN/UP/POINTER_UP+DOWN/MOVE/CANCEL are translated —
   hover events never reach Lua; tool type and pressure are dropped;
   historical samples are NOT read, so the point rate is one point per
   delivered MotionEvent (~60 Hz batched by the display pipeline), not
   the EMR digitizer rate. The module's translation functions are
   file-local — raising the point rate needs a koreader-base patch (or
   shadowing the whole module via `package.loaded`), not a runtime wrap.
10. **The Android full-frame blit is patchable.**
   `framebuffer_android.lua:_updateWindow` locks the ANativeWindow with
   a nil dirty rect and blits the WHOLE shadow bb (18 MB on the Go 10.3)
   on every `refresh*()`. It is an instance method on `Device.screen`,
   and `ANativeWindow_lock` (cdef'd in the launcher's `android.lua`)
   accepts an `ARect*` in/out dirty-bounds parameter. The system may
   EXPAND the returned rect — always repaint what it returns. BUT see
   the measured numbers: on this device the dirty-rect lock is a
   *pessimization* (front-buffer copy-back serializes with the system
   refresh); plain lock + full blit is ~2× faster.
11. **`UIManager:setDirty(widget, ...)` repaints NOTHING for non-window
   widgets.** setDirty matches `widget` against the window stack;
   ReaderView is not a window, so `setDirty(self.view, ...)` never marks
   anything dirty — it only enqueues the *e-ink refresh*, which then
   re-displays the stale shadow buffer (eraser/undo looked dead until an
   island drag forced a repaint). The correct target is
   `self.view.dialog` (= ReaderUI — what ReaderView itself passes).
   Corollary: repainting a *transparent* window (the canvas) does not
   repaint anything beneath it — its previous content's pixels stay on
   screen (the "two islands" bug); repaint from `view.dialog` up.

## Measured performance (Go 10.3, 2026-07-03)

- Input: points ≈ events per stroke, ~50–60/s while writing — the ~60 Hz
  MotionEvent ceiling (fact 9) is the input rate; raw capture drops
  nothing.
- Dirty-rect flush (now default-off): avg 46–58 ms, of which
  **ANativeWindow_lock 39–45 ms** (front-buffer copy-back waits for the
  consumer = serialized with Onyx's system refresh), blit 7–8.6 ms.
  Adaptive interval settled at 66–91 ms (~12 flushes/s).
- Plain full-blit flush (current default): **avg 21–25 ms** (plain
  dequeue ~13–17 ms + 18 MB blit ~8 ms), interval 34–43 ms
  (~25 flushes/s). User-confirmed smoother, especially with a fast Onyx
  per-app refresh mode.
- Direct regional einkUpdate (experiment #1): avg 56–58 ms, no visual
  benefit, suspected window/EPD state corruption (see README experiment
  log). Removed.

Cost model per live-ink refresh (current defaults): plain window lock +
full 18 MB blit + post; no einkUpdate (fact 5) — the EPD update is
Onyx's system refresh, whose waveform/latency follows the per-app
refresh mode. The native Boox notes app remains faster in principle
(hardware pen overlay, composited under the pen before software sees
anything); the remaining gap is the system-refresh pacing + the ~60 Hz
input rate, not our software path.

## Remaining performance ideas, in order of expected value

1. **Onyx per-app refresh mode** (zero-code, user-side): KOReader set to
   Speed/A2/X in the system E-ink center — affects both the ink waveform
   and buffer release. User reports fast-refresh mode helps noticeably.
2. **Raise the input rate** past ~60 Hz: read
   `AMotionEvent_getHistorical*` samples in `base/ffi/input_android.lua`
   (fact 9). Options: koreader-base PR (clean, benefits everyone), or
   shadow the module from a user patch / plugin before Device init via
   `package.loaded` (fragile). EMR digitizers sample at 120–240 Hz, so
   this roughly doubles-to-quadruples curve fidelity for fast writing.
3. **Cheaper undo/redo feel:** undo currently repaints the view + "ui"
   region refresh. Painting over the stroke area with `refreshFast`
   first and letting the delayed cleanup pass beautify later would make
   the button feel instant.
4. **The nuclear option for real latency: Onyx raw pen SDK.** Fork
   android-luajit-launcher (the only layer a plugin genuinely cannot
   reach: Java/Kotlin), add
   `com.onyx.android.sdk.pen.TouchHelper`/RawInputCallback glue so the
   hardware overlay draws the live stroke and Lua only receives the
   final point list. Verified feasible in principle: Saber
   (saber-notes/saber, `packages/onyxsdk_pen`) attaches
   `TouchHelper.create(view, callback)` to a plain `SurfaceView` inside
   a non-Onyx app; SDK on jitpack + `repo.boox.com`
   (`onyxsdk-pen:1.5.4`), needs `org.lsposed.hiddenapibypass`. Catches:
   the launcher's MainActivity is a NativeActivity that on Onyx runs
   view-less (`needsView()==false`) — a (transparent) View must be added
   to host TouchHelper; raw drawing mode locks out system refreshes
   while active; requires rebuilding the APK.
5. Track upstream: core stylus API is **PR #14862** (mysticknits, "add
   stylus callback API for plugin integration", open, milestone
   2026.07) — adds `Input:registerStylusCallback`/`routeStylusEvents`
   doing exactly what our raw-input wrapper does. When it lands, migrate
   `installRawInput` to that API. Nothing Android-side is planned there
   (tool type is still dropped in base's `input_android.lua`), so the
   mode-based UX stays necessary either way.

## Open item

- Width-picker crash (reported twice on-device, traceback never
  captured; KOReader crash *window* appeared → Lua error, not native).
  The picker is now fully pcall-guarded and self-diagnosing: on failure
  it logs `Sketch: width picker failed, falling back to cycling: <err>`
  and cycles widths instead. If the fallback fires, that log line
  contains the root cause — fix from there.
