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
