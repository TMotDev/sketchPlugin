--[[--
Sketch plugin: freehand drawing on book pages for touch/stylus devices.

Designed for Android e-ink devices (e.g. Onyx Boox) where KOReader receives
pen input as ordinary touch events. Instead of distinguishing pen from
finger (which needs core input changes on Android), it uses an explicit
"sketch mode": while active, all single-finger/pen input on the page is ink,
and a small tool island provides tool/width/undo/redo/save/cancel controls.

While sketch mode is active, a fullscreen transparent "canvas" window sits
on top of the reader. This is required because KOReader's UIManager only
delivers input to the topmost window: the canvas handles drawing gestures
itself, gives its child tool island first pick of taps, and forwards
anything it doesn't understand (multi-finger gestures) down to the reader.
(With raw input capture active — the default — multi-finger gestures are
effectively unavailable while sketching, see the "Raw pen input" section;
leave sketch mode via the island buttons or the Back key.)

Stroke storage, rendering and erasing are adapted from pencil.koplugin by
mysticknits (https://github.com/mysticknits/pencil.koplugin, AGPL-3.0).

@module koplugin.sketch
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local SketchGeometry = require("lib/geometry")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local TOOL_PEN = "pen"
local TOOL_ERASER = "eraser"

local PEN_WIDTHS = { 3, 5, 7, 9 }
local ERASER_RADIUS = 20

-- ------------------------------------------------------------------------
-- SketchCanvas: fullscreen input-capturing window shown while sketch mode
-- is active. Owns the tool island as its child widget.
-- ------------------------------------------------------------------------

-- Gestures that belong to an ongoing ink/erase contact. While one is
-- active, they are fed straight to the drawing handlers so a stroke
-- crossing the tool island isn't stolen by its buttons/MovableContainer.
local CONTACT_GESTURES = {
    tap = true,
    pan = true,
    pan_release = true,
    hold = true,
    hold_pan = true,
    hold_release = true,
    swipe = true,
}

local SketchCanvas = InputContainer:extend{
    sketch = nil, -- Sketch plugin instance
}

function SketchCanvas:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }

    if Device:hasKeys() then
        self.key_events = {
            SketchExitKey = { { Device.input.group.Back } },
        }
    end

    local fullscreen = function() return self.dimen end
    local function ges_event(ges)
        return { GestureRange:new{ ges = ges, range = fullscreen } }
    end
    self.ges_events = {
        SketchTouch = ges_event("touch"),
        SketchTap = ges_event("tap"),
        SketchHold = ges_event("hold"),
        SketchHoldPan = ges_event("hold_pan"),
        SketchHoldRelease = ges_event("hold_release"),
        SketchPan = ges_event("pan"),
        SketchPanRelease = ges_event("pan_release"),
        SketchSwipe = ges_event("swipe"),
    }
end

function SketchCanvas:handleEvent(event)
    if self.sketch.drawing_contact and event.handler == "onGesture" then
        local ges = event.args and event.args[1]
        if ges and CONTACT_GESTURES[ges.ges] then
            return self:onGesture(ges)
        end
    end
    -- Normal path: children (tool island) get first pick, then our
    -- own onGesture below.
    return InputContainer.handleEvent(self, event)
end

function SketchCanvas:onGesture(ges)
    if InputContainer.onGesture(self, ges) then
        return true
    end
    -- Gestures we don't handle are multi-finger ones (two-finger tap/swipe,
    -- pinch, ...). Abort any half-started stroke (the first contact of a
    -- multi-finger gesture arrives as a plain "touch" and may have inked a
    -- dot), then hand the gesture to the reader below so the sketch-toggle
    -- gesture and two-finger page turns keep working.
    self.sketch:abortInProgressContact()
    return self.sketch.ui:handleEvent(Event:new("Gesture", ges))
end

-- Gesture handlers: ges_events dispatch arrives as (self, args, ges).
function SketchCanvas:onSketchTouch(_, ges) return self.sketch:onSketchTouch(ges) end
function SketchCanvas:onSketchTap(_, ges) return self.sketch:onSketchTap(ges) end
function SketchCanvas:onSketchHold(_, ges) return self.sketch:onSketchHold(ges) end
function SketchCanvas:onSketchHoldPan(_, ges) return self.sketch:onSketchPan(ges) end
function SketchCanvas:onSketchHoldRelease(_, ges) return self.sketch:onSketchPanRelease(ges) end
function SketchCanvas:onSketchPan(_, ges) return self.sketch:onSketchPan(ges) end
function SketchCanvas:onSketchPanRelease(_, ges) return self.sketch:onSketchPanRelease(ges) end
function SketchCanvas:onSketchSwipe(_, ges) return self.sketch:onSketchSwipe(ges) end

function SketchCanvas:onSketchExitKey()
    self.sketch:exitSketchMode(true)
    return true
end

-- ------------------------------------------------------------------------
-- Sketch: the plugin proper
-- ------------------------------------------------------------------------

local Sketch = InputContainer:extend{
    name = "sketch",
    is_doc_only = true,

    sketch_mode = false,
    current_tool = TOOL_PEN,
    pen_width = 3,

    strokes = nil,        -- array of stroke tables for the whole document
    page_strokes = nil,   -- index: page -> array of stroke indices
    strokes_loaded = false,
    current_stroke = nil, -- in-progress stroke
    drawing_contact = false, -- an ink/erase contact is currently on the screen
    undo_stack = nil,
    redo_stack = nil,
    session_snapshot = nil, -- strokes list as it was when sketch mode was entered
    session_dirty = false,
    eraser_deleted = nil,   -- strokes deleted during one eraser drag

    canvas = nil,         -- SketchCanvas window while sketch mode is active
    toolbar_frame = nil,  -- island FrameContainer, used for hit-testing
    island_movable = nil, -- island MovableContainer; kept to preserve the drag offset across rebuilds

    -- Batched partial refresh while drawing (see addPointToStroke).
    -- Each refresh blocks the input loop for the blit + e-ink update, so a
    -- too-eager cadence makes ink lag *more*, not less: events queue up
    -- behind refreshes. The floor is 15 ms (~60 fps); maybeRefresh measures
    -- each flush and backs the cadence off adaptively when flushes are
    -- slower than that.
    last_refresh_time = 0,
    refresh_interval_ms = 15,
    current_refresh_interval = nil, -- adaptive, >= refresh_interval_ms
    dirty_region = nil,
    flush_scheduled = nil, -- trailing flush so the stroke tail isn't left unrefreshed
    pending_refresh = nil,
    refresh_delay_ms = 600,
    cleanup_region = nil,  -- accumulated bbox needing a grayscale cleanup pass

    -- Raw pen input (see the "Raw pen input" section): pen contacts are
    -- consumed at the input-frame level, below the gesture detector.
    raw_input_enabled = true, -- user setting "sketch_raw_input"
    raw_claimed_slot = nil,   -- input slot currently inking via raw capture
    raw_claim_time = 0,
    raw_slots = nil,          -- slot -> {down=bool}: physical contact tracking
    raw_down_count = 0,       -- contacts currently down (all slots)
    raw_last_erase_time = 0,  -- rate limiter for raw eraser hit-tests

    -- Dirty-rect screen flush (see the "Fast flush" section).
    fast_flush_enabled = true,  -- user setting "sketch_fast_flush"
    fast_flush_broken = false,  -- tripped by a runtime failure, sticky per session
    fast_flush_state = "off",   -- for logging/diagnostics

    -- Per-stroke perf counters, dumped to the log at stroke end.
    perf = nil,

    -- Debounced save, flushed on page turn / close / mode exit
    pending_save = nil,
    save_delay_s = 1.5,
}

function Sketch:init()
    self.strokes = {}
    self.page_strokes = {}
    self.undo_stack = {}
    self.redo_stack = {}

    self.pen_width = G_reader_settings:readSetting("sketch_pen_width") or 3
    self.pen_color = Blitbuffer.COLOR_BLACK
    -- Tunable without code edits via settings.reader.lua, for latency tests.
    self.refresh_interval_ms = G_reader_settings:readSetting("sketch_refresh_interval_ms")
        or self.refresh_interval_ms
    self.raw_input_enabled = G_reader_settings:nilOrTrue("sketch_raw_input")
    self.fast_flush_enabled = G_reader_settings:nilOrTrue("sketch_fast_flush")
    self.raw_slots = {}
    -- The input/framebuffer wrappers (installed lazily on first sketch-mode
    -- entry, see installRawInput/installFastFlush) hold a reference to their
    -- owning plugin instance; rebind them to this instance so the previous
    -- document's instance can be collected.
    if Device.input and Device.input._sketch_raw_owner then
        Device.input._sketch_raw_owner = self
    end
    if Screen._sketch_flush_owner then
        Screen._sketch_flush_owner = self
    end

    self.ui.menu:registerToMainMenu(self)

    self.view = self.ui.view
    self.view:registerViewModule("sketch", self)

    Dispatcher:registerAction("sketch_toggle", {
        category = "none",
        event = "SketchToggle",
        title = _("Sketch: toggle drawing mode"),
        reader = true,
        separator = true,
    })

    if self.ui.doc_settings and self.ui.doc_settings.doc_sidecar_dir then
        self:loadStrokes()
    end

    logger.info("Sketch: initialized")
end

-- ------------------------------------------------------------------------
-- Mode handling
-- ------------------------------------------------------------------------

function Sketch:onSketchToggle()
    if self.sketch_mode then
        self:exitSketchMode(true)
    else
        self:enterSketchMode()
    end
    return true
end

function Sketch:enterSketchMode()
    if self.sketch_mode then return end
    if not self.strokes_loaded then
        self:loadStrokes()
    end
    self.sketch_mode = true
    self.session_dirty = false
    self.drawing_contact = false
    -- Shallow copy of the stroke list: finalized strokes are never mutated,
    -- only added/removed, so restoring this list is a full "cancel".
    self.session_snapshot = {}
    for i, s in ipairs(self.strokes) do
        self.session_snapshot[i] = s
    end
    self.undo_stack = {}
    self.redo_stack = {}

    if self.raw_input_enabled then
        self:installRawInput()
    end
    if self.fast_flush_enabled then
        self:installFastFlush()
    end

    self.canvas = SketchCanvas:new{ sketch = self }
    self:buildIsland()
    UIManager:show(self.canvas)
    logger.info("Sketch: entered sketch mode; raw input:",
        self.raw_input_enabled and "on" or "off",
        "- fast flush:", self.fast_flush_state,
        "- refresh floor:", self.refresh_interval_ms, "ms")
end

-- save == false restores the stroke list to what it was on mode entry.
function Sketch:exitSketchMode(save)
    if not self.sketch_mode then return end
    self:finalizeCurrentStroke()
    self:finalizeErase()
    self.raw_claimed_slot = nil
    self.drawing_contact = false
    self:cancelPendingRefresh()
    if self.flush_scheduled then
        UIManager:unschedule(self.flush_scheduled)
        self.flush_scheduled = nil
    end

    if not save and self.session_dirty then
        self.strokes = self.session_snapshot or {}
        self:rebuildPageIndex()
    end
    self.session_snapshot = nil
    self.undo_stack = {}
    self.redo_stack = {}

    self:flushSave()
    if self.canvas then
        UIManager:close(self.canvas)
        self.canvas = nil
        self.toolbar_frame = nil
        self.width_button = nil
    end
    self.sketch_mode = false
    -- Full repaint: clears discarded ink and any fast-refresh artifacts.
    UIManager:setDirty(self.view.dialog, "partial")
    logger.info("Sketch: left sketch mode, saved =", save and true or false)
end

function Sketch:isInToolbar(pos)
    if not pos then return false end
    local frame = self.toolbar_frame
    if not frame or not frame.dimen then return false end
    return frame.dimen:contains(pos)
end

-- ------------------------------------------------------------------------
-- Drawing gesture handlers (called from SketchCanvas)
-- ------------------------------------------------------------------------

function Sketch:onSketchTouch(ges)
    if not self.sketch_mode then return false end
    if self.raw_claimed_slot then return true end -- raw capture owns the ink
    if self.drawing_contact or self.current_stroke then
        -- Extra contact while already drawing (e.g. second finger of a
        -- multi-finger gesture, or palm): don't start anything new.
        return true
    end
    if self:isInToolbar(ges.pos) then
        -- Island interaction, not ink. Buttons get the tap on lift.
        return true
    end
    -- New ink incoming: postpone the cleanup pass, but keep its accumulated
    -- region — earlier strokes still need their grayscale cleanup later.
    self:cancelPendingRefresh(true)
    self.drawing_contact = true

    if self.current_tool == TOOL_ERASER then
        self.eraser_deleted = self.eraser_deleted or {}
        self:eraseAt(ges.pos.x, ges.pos.y)
        return true
    end

    self:startStroke(ges.pos.x, ges.pos.y)
    return true
end

function Sketch:onSketchPan(ges)
    if not self.sketch_mode then return false end
    if self.raw_claimed_slot then return true end -- raw capture owns the ink

    if not self.drawing_contact then
        -- Contact didn't start as ink (island drag, or the "touch" event was
        -- missed). Recover only if it genuinely started on the page.
        local start = ges.start_pos or ges.pos
        if self:isInToolbar(start) then return true end
        self:cancelPendingRefresh(true)
        self.drawing_contact = true
        if self.current_tool == TOOL_ERASER then
            self.eraser_deleted = self.eraser_deleted or {}
        else
            self:startStroke(start.x, start.y)
        end
    end

    if self.current_tool == TOOL_ERASER then
        self:eraseAt(ges.pos.x, ges.pos.y)
        return true
    end

    self:addPointToStroke(ges.pos.x, ges.pos.y)
    return true
end

function Sketch:onSketchPanRelease(ges)
    if not self.sketch_mode then return false end
    if self.raw_claimed_slot then return true end -- raw capture owns the ink
    if not self.drawing_contact then return true end
    self.drawing_contact = false

    if self.current_tool == TOOL_ERASER then
        self:finalizeErase()
        return true
    end

    self:finalizeCurrentStroke()
    self:scheduleDelayedRefresh()
    return true
end

function Sketch:onSketchTap(ges)
    if not self.sketch_mode then return false end
    if self.raw_claimed_slot then return true end -- raw capture owns the ink

    -- A contact that started as ink always ends as ink, even if the finger
    -- was lifted over the island: finalize before any island hit-test.
    if self.drawing_contact then
        self.drawing_contact = false
        if self.current_tool == TOOL_ERASER then
            if not self:isInToolbar(ges.pos) then
                self:eraseAt(ges.pos.x, ges.pos.y)
            end
            self:finalizeErase()
        elseif self.current_stroke then
            -- Pen lifted without movement: the "touch" handler already
            -- started a one-point stroke, finalize it as a dot.
            self:finalizeCurrentStroke()
            self:scheduleDelayedRefresh()
        end
        return true
    end

    -- No ink contact: island padding taps and other strays land here.
    -- (Taps on the island's buttons were already consumed by the buttons.)
    return true
end

function Sketch:onSketchHold(ges)
    if not self.sketch_mode then return false end
    -- Stationary pen: stroke already started by "touch"; just consume so
    -- nothing else reacts. Movement continues via hold_pan.
    return true
end

function Sketch:onSketchSwipe(ges)
    if not self.sketch_mode then return false end
    -- A fast flick ends the contact as "swipe" instead of "pan_release":
    -- finalize like a release; ink was already drawn by the pan handler.
    return self:onSketchPanRelease(ges)
end

-- Called when a multi-finger gesture is detected: its first contact arrived
-- as a plain "touch" and may have started a stroke (usually a single dot).
-- Drop it, it wasn't meant as ink.
function Sketch:abortInProgressContact()
    if self.raw_claimed_slot then
        -- A raw-captured contact is definitively ink: never let unrelated
        -- gestures (other fingers) abort it. rawAbort clears the claim
        -- before calling us, so the raw path's own abort still works.
        return
    end
    if not self.drawing_contact and not self.current_stroke then return end
    self.drawing_contact = false
    self:finalizeErase() -- eraser deletions already happened; keep them undoable
    if self.current_stroke then
        -- Repaint to wipe the stray ink — only where it was drawn.
        local region = self:strokesRegion({ self.current_stroke })
        self.current_stroke = nil
        UIManager:setDirty(self.view.dialog, "ui", region)
    end
end

-- ------------------------------------------------------------------------
-- Raw pen input
--
-- The gesture detector only reports a "pan" once a contact has moved
-- PAN_THRESHOLD (35 px DPI-scaled ≈ 50 px ≈ 6 mm on a Boox Go 10.3) away
-- from its start: anything smaller ends as a tap (a single dot), and every
-- longer stroke has its first half-centimeter of curvature collapsed into
-- a straight jump. So while sketch mode is active we watch input frames
-- directly: Device.input.handleTouchEv is wrapped, and on each SYN_REPORT
-- the parsed slot data (Input.MTSlots) is inspected *before* KOReader
-- feeds it to the gesture detector. A single contact that starts on the
-- page is "claimed": every one of its points goes straight into the
-- stroke engine (no threshold, no gesture latency — this runs inside the
-- input drain loop, ahead of UIManager dispatch), and its slot is removed
-- from MTSlots so the gesture detector never sees the contact at all —
-- no stray button taps when a stroke ends on the island, no conflicting
-- pan/hold gestures. pencil.koplugin does the same slot "domination" via
-- a patched frontend/device/input.lua; wrapping the live Input instance
-- gets us there without modifying KOReader files.
--
-- Contacts that start on the tool island are not claimed (island taps and
-- drags keep working through the normal widget path). A second contact
-- landing within RAW_MULTITOUCH_GRACE_MS of a claim means the user meant
-- a multi-finger gesture: the ink is aborted and the slot is released to
-- the gesture detector mid-stream. In practice the released pair does NOT
-- reassemble into two-finger gestures (the detector pairs buddy contacts
-- at creation time; verified on device 2026-07-03), so multi-finger
-- gestures are effectively unavailable in sketch mode — accepted; the
-- abort still matters because it wipes the stray dot such attempts leave.
-- After the grace period a second contact (e.g. a resting palm) is simply
-- ignored and inking continues.
--
-- Everything is pcall-guarded: any error reverts to the gesture-based
-- drawing path for the rest of the session.
-- ------------------------------------------------------------------------

-- Linux input ABI constants (frozen kernel ABI; these are the values the
-- Android input translation layer synthesizes, see base ffi/input_android.lua).
local EV_SYN, SYN_REPORT = 0, 0

local RAW_MULTITOUCH_GRACE_MS = 250

function Sketch:installRawInput()
    local input = Device.input
    if not input or type(input.handleTouchEv) ~= "function"
        or type(input.resetState) ~= "function" then
        self.raw_input_enabled = false
        logger.warn("Sketch: no wrappable input instance, raw input disabled")
        return
    end
    -- The wrappers are installed once per app run and only their owner is
    -- rebound afterwards (a new plugin instance is created per document).
    if input._sketch_raw_owner then
        input._sketch_raw_owner = self
        return
    end
    input._sketch_raw_owner = self

    local orig_handleTouchEv = input.handleTouchEv
    input.handleTouchEv = function(inp, ev)
        local owner = inp._sketch_raw_owner
        if owner and owner.raw_input_enabled
            and ev.type == EV_SYN and ev.code == SYN_REPORT then
            local ok, err = pcall(owner.rawProcessFrame, owner, inp)
            if not ok then
                logger.err("Sketch: raw input error, reverting to gestures:", err)
                owner.raw_input_enabled = false
                owner.raw_claimed_slot = nil
                owner.drawing_contact = false
            end
        end
        return orig_handleTouchEv(inp, ev)
    end

    local orig_resetState = input.resetState
    input.resetState = function(inp, ...)
        local owner = inp._sketch_raw_owner
        if owner then
            pcall(owner.rawReset, owner)
        end
        return orig_resetState(inp, ...)
    end
end

-- One parsed input frame: MTSlots holds the slot-state tables touched in
-- this frame (fields: slot, id, x, y). Contact tracking runs whenever raw
-- input is enabled (not just in sketch mode) so the down/up bookkeeping
-- never goes stale; claiming only happens in sketch mode.
function Sketch:rawProcessFrame(inp)
    local slots = inp.MTSlots
    if not slots then return end
    local n = #slots
    if n == 0 then return end

    local any_claimed = false
    for i = 1, n do
        if self:rawProcessSlot(slots[i]) then
            any_claimed = true
        end
    end
    if any_claimed then
        -- Strip claimed entries in place: the gesture detector never gets
        -- to see the inking contact.
        local w = 0
        for i = 1, n do
            local mt = slots[i]
            if mt._sketch_claimed then
                mt._sketch_claimed = nil
            else
                w = w + 1
                slots[w] = mt
            end
        end
        for i = n, w + 1, -1 do
            slots[i] = nil
        end
    end
end

-- Returns true if this slot's frame entry was consumed as ink.
function Sketch:rawProcessSlot(mt)
    local slot = mt.slot
    local st = self.raw_slots[slot]
    if not st then
        st = { down = false }
        self.raw_slots[slot] = st
    end
    local id = mt.id or -1
    local claimed = self.raw_claimed_slot == slot

    if id == -1 then -- contact lift
        if st.down then
            st.down = false
            self.raw_down_count = math.max(0, self.raw_down_count - 1)
        end
        if claimed then
            self:rawFinalize()
            mt._sketch_claimed = true -- hide the lift from the detector too
            return true
        end
        return false
    end

    if not st.down then -- new contact
        st.down = true
        self.raw_down_count = self.raw_down_count + 1
        if self:rawShouldClaim(mt) then
            self.raw_claimed_slot = slot
            self.raw_claim_time = time.now()
            self:rawBegin(mt.x, mt.y)
            mt._sketch_claimed = true
            return true
        end
        if self.raw_claimed_slot
            and time.to_ms(time.now() - self.raw_claim_time) < RAW_MULTITOUCH_GRACE_MS then
            -- Second contact right after a claim: a multi-finger gesture is
            -- starting, not ink. Wipe the stray ink and release the first
            -- contact back to the gesture detector.
            self:rawAbort()
        end
        return false
    end

    -- contact move
    if claimed then
        self:rawMove(mt.x, mt.y)
        mt._sketch_claimed = true
        return true
    end
    return false
end

function Sketch:rawShouldClaim(mt)
    if not self.sketch_mode or not self.canvas then return false end
    -- Never claim while a dialog (ConfirmBox, InfoMessage, ...) sits above
    -- the canvas: the contact belongs to it — claiming would eat its taps
    -- AND ink right over it, since raw capture bypasses window routing.
    if UIManager:getTopmostVisibleWidget() ~= self.canvas then return false end
    if self.raw_claimed_slot then return false end
    -- Only a lone contact can start ink (matches the gesture path: a
    -- second finger means a multi-finger gesture).
    if self.raw_down_count ~= 1 then return false end
    -- The gesture path may already own ink (e.g. raw input was toggled
    -- mid-session); don't fight it.
    if self.drawing_contact or self.current_stroke then return false end
    -- Under a software-rotated screen, gesture coordinates go through
    -- adjustGesCoordinate; raw slot coordinates don't. Rotation is native
    -- (rotation 0) on Android in practice — fall back to gestures otherwise.
    if Screen.bb:getRotation() ~= 0 then return false end
    if mt.x == nil or mt.y == nil then return false end
    return not self:isInToolbar({ x = mt.x, y = mt.y, w = 0, h = 0 })
end

function Sketch:rawBegin(x, y)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    self:cancelPendingRefresh(true)
    self.drawing_contact = true
    if self.current_tool == TOOL_ERASER then
        self.eraser_deleted = self.eraser_deleted or {}
        self.raw_last_erase_time = time.now()
        self:eraseAt(x, y)
    else
        self:startStroke(x, y)
    end
end

function Sketch:rawMove(x, y)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    if self.current_tool == TOOL_ERASER then
        -- Rate-limit: every input frame (~60 Hz) would otherwise run a
        -- hit-test over all page strokes plus a partial refresh.
        local now = time.now()
        if time.to_ms(now - self.raw_last_erase_time) >= 50 then
            self.raw_last_erase_time = now
            self:eraseAt(x, y)
        end
    else
        self:addPointToStroke(x, y)
    end
end

function Sketch:rawFinalize()
    self.raw_claimed_slot = nil
    self.drawing_contact = false
    if self.current_tool == TOOL_ERASER then
        self:finalizeErase()
    else
        self:finalizeCurrentStroke()
        self:scheduleDelayedRefresh()
    end
end

-- A multi-finger gesture began with what we briefly took for ink.
function Sketch:rawAbort()
    self.raw_claimed_slot = nil
    self:abortInProgressContact()
end

-- All contacts were invalidated wholesale (Android ACTION_CANCEL / focus
-- loss funnels into Input:resetState): keep the ink drawn so far, forget
-- every contact.
function Sketch:rawReset()
    if self.raw_claimed_slot then
        self:rawFinalize()
    end
    self.raw_slots = {}
    self.raw_down_count = 0
end

-- ------------------------------------------------------------------------
-- Fast flush (dirty-rect window blit)
--
-- On Android every Screen:refresh*() blits the ENTIRE shadow buffer into
-- the ANativeWindow (1860×2480×4 ≈ 18 MB on a Go 10.3) before the
-- region-limited e-ink update — see base ffi/framebuffer_android.lua
-- _updateWindow, which passes a nil dirty rect to ANativeWindow_lock.
-- For live ink we only ever change a stroke's bounding box, and
-- ANativeWindow_lock accepts a dirty rect: the compositor then copies the
-- unchanged area from the previous buffer itself (cheaply) and we blit
-- only the dirty rows. _updateWindow is an instance method, so it can be
-- patched at runtime from the plugin: when Sketch._sketch_dirty_rect is
-- set on the Screen object our dirty-rect path runs, for every other
-- refresh in the system the stock full blit runs unchanged.
--
-- The patched path mirrors the stock implementation (format branches,
-- inverse/rotation cloning) and honors the possibly-EXPANDED rect the
-- system hands back from ANativeWindow_lock. Any runtime failure disables
-- the fast path for the session and repairs the screen with a stock blit.
-- ------------------------------------------------------------------------

function Sketch:installFastFlush()
    local fb = Screen
    if fb._sketch_flush_owner then
        fb._sketch_flush_owner = self
        self.fast_flush_state = "active"
        return
    end
    if not Device:isAndroid() then
        self.fast_flush_state = "unavailable (not Android)"
        return
    end

    local ok, err = pcall(function()
        local ffi = require("ffi")
        local android = require("android")
        local BB = require("ffi/blitbuffer")
        local C = ffi.C
        assert(type(fb._updateWindow) == "function", "no _updateWindow method")
        assert(android.lib ~= nil and android.app ~= nil, "no android glue")
        assert(android.lib.ANativeWindow_lock ~= nil, "no ANativeWindow_lock")

        local orig_updateWindow = fb._updateWindow
        fb._updateWindow = function(fbself)
            local rect = fbself._sketch_dirty_rect
            if not rect then
                return orig_updateWindow(fbself)
            end
            fbself._sketch_dirty_rect = nil

            local ok2, err2 = pcall(function()
                if android.app.window == nil then
                    error("no native window")
                end
                local t0 = time.now()
                local dirty = ffi.new("ARect[1]")
                dirty[0].left = rect.x
                dirty[0].top = rect.y
                dirty[0].right = rect.x + rect.w
                dirty[0].bottom = rect.y + rect.h
                local buffer = ffi.new("ANativeWindow_Buffer[1]")
                if android.lib.ANativeWindow_lock(android.app.window, buffer, dirty) < 0 then
                    error("window lock failed")
                end
                local t1 = time.now()
                -- The system may EXPAND the dirty bounds (e.g. when it
                -- can't preserve the previous buffer): repaint what it
                -- actually asks for, clamped to the buffer.
                local bx = math.max(0, tonumber(dirty[0].left))
                local by = math.max(0, tonumber(dirty[0].top))
                local bw = math.min(tonumber(buffer[0].width), tonumber(dirty[0].right)) - bx
                local bh = math.min(tonumber(buffer[0].height), tonumber(dirty[0].bottom)) - by

                -- Never leave the window locked: blit errors must still
                -- reach unlockAndPost.
                local blit_ok, blit_err = pcall(function()
                    local bb
                    if buffer[0].format == C.WINDOW_FORMAT_RGBA_8888
                    or buffer[0].format == C.WINDOW_FORMAT_RGBX_8888 then
                        bb = BB.new(buffer[0].width, buffer[0].height, BB.TYPE_BBRGB32,
                            buffer[0].bits, buffer[0].stride * 4, buffer[0].stride)
                    elseif buffer[0].format == C.WINDOW_FORMAT_RGB_565 then
                        bb = BB.new(buffer[0].width, buffer[0].height, BB.TYPE_BBRGB16,
                            buffer[0].bits, buffer[0].stride * 2, buffer[0].stride)
                    else
                        error("unsupported window format " .. tostring(buffer[0].format))
                    end
                    local ext_bb = fbself.full_bb or fbself.bb
                    -- Same rotation/inverse cloning as the stock full blit
                    -- (the fast path is only used at rotation 0, where the
                    -- logical rect equals the physical one).
                    bb:setInverse(ext_bb:getInverse())
                    bb:setRotation(ext_bb:getRotation())
                    if bw > 0 and bh > 0 then
                        if bb:getInverse() == 1 and BB:getUseCBB()
                            and bb:getType() == ext_bb:getType() then
                            bb:invertblitFrom(ext_bb, bx, by, bx, by, bw, bh)
                        else
                            bb:blitFrom(ext_bb, bx, by, bx, by, bw, bh)
                            if bb:getInverse() == 1 and BB:getUseCBB() then
                                bb:invertRect(bx, by, bw, bh)
                            end
                        end
                    end
                end)
                android.lib.ANativeWindow_unlockAndPost(android.app.window)
                if not blit_ok then
                    error(blit_err)
                end
                fbself._sketch_lock_ms = time.to_ms(t1 - t0)
                fbself._sketch_blit_ms = time.to_ms(time.now() - t1)
            end)
            if ok2 then return end

            logger.warn("Sketch: dirty-rect flush failed, disabling it:", err2)
            local owner = fbself._sketch_flush_owner
            if owner then
                owner.fast_flush_broken = true
                owner.fast_flush_state = "broken (" .. tostring(err2) .. ")"
            end
            -- Repair the screen with a stock full update.
            return orig_updateWindow(fbself)
        end
        fb._sketch_flush_owner = self
    end)

    if ok then
        self.fast_flush_state = "active"
    else
        self.fast_flush_state = "unavailable"
        logger.warn("Sketch: fast flush unavailable:", err)
    end
end

-- The dirty-rect path is only valid while coordinates map 1:1 onto the
-- window buffer: no viewport (full_bb) and no software rotation.
function Sketch:canFastFlush()
    return self.fast_flush_enabled
        and not self.fast_flush_broken
        and Screen._sketch_flush_owner ~= nil
        and not Screen.full_bb
        and Screen.bb:getRotation() == 0
end

-- ------------------------------------------------------------------------
-- Stroke building & incremental rendering
-- ------------------------------------------------------------------------

function Sketch:startStroke(x, y)
    self.current_stroke = {
        page = self:getCurrentPage(),
        xpointer = self:getCurrentXPointer(),
        tool = TOOL_PEN,
        points = { { x = x, y = y } },
        width = self.pen_width,
        datetime = os.time(),
    }
    self.last_refresh_time = time.now()
    self.dirty_region = nil
    self.perf = {
        t_start = time.now(),
        frames = 0,     -- input points offered (pre jitter filter)
        flushes = 0, flush_ms = 0, max_flush_ms = 0,
        fast_flushes = 0, lock_ms = 0, blit_ms = 0,
    }

    local w = self.pen_width
    local half_w = math.floor(w / 2)
    Screen.bb:paintRect(x - half_w, y - half_w, w, w, self.pen_color)
    self:expandDirtyRegion(x - half_w, y - half_w, w, w)
    self:maybeRefresh(true)
end

function Sketch:addPointToStroke(x, y)
    if not self.current_stroke then return end
    if self.perf then self.perf.frames = self.perf.frames + 1 end
    local points = self.current_stroke.points
    local n = #points
    local prev = points[n]
    -- Drop sub-pixel jitter only: with raw input capture the point stream
    -- is the stroke's whole fidelity, so keep every real 1px move (small
    -- letters and tiny circles live at this scale).
    local jx, jy = x - prev.x, y - prev.y
    if jx * jx + jy * jy < 1 then return end
    table.insert(points, { x = x, y = y })

    local w = self.current_stroke.width
    self:drawLineSegment(Screen.bb, prev.x, prev.y, x, y, w, self.pen_color)

    local pad = math.floor(w / 2) + 2
    self:expandDirtyRegion(
        math.min(prev.x, x) - pad,
        math.min(prev.y, y) - pad,
        math.abs(x - prev.x) + w + 4,
        math.abs(y - prev.y) + w + 4)
    self:maybeRefresh(false)
end

function Sketch:finalizeCurrentStroke()
    local stroke = self.current_stroke
    self.current_stroke = nil
    if not stroke or #stroke.points < 1 then return end

    table.insert(self.strokes, stroke)
    self:indexStroke(#self.strokes, stroke.page)
    table.insert(self.undo_stack, { type = "add", stroke = stroke })
    self.redo_stack = {}
    self.session_dirty = true
    self:scheduleSave()

    -- Remember where we inked (bbox, padded for stroke width), so the
    -- delayed grayscale cleanup pass can refresh just that area instead of
    -- the whole screen.
    local bbox = SketchGeometry.computeStrokeBbox(stroke)
    if bbox then
        local pad = (stroke.width or 3) + 4
        bbox = { x0 = bbox.x0 - pad, y0 = bbox.y0 - pad,
                 x1 = bbox.x1 + pad, y1 = bbox.y1 + pad }
        self.cleanup_region = SketchGeometry.bboxUnion(self.cleanup_region, bbox)
    end

    -- Flush whatever ink hasn't been refreshed to screen yet.
    self:maybeRefresh(true)

    -- Perf summary for this stroke, greppable in logcat as "sketch-perf".
    local p = self.perf
    if p then
        self.perf = nil
        local dur_ms = time.to_ms(time.now() - p.t_start)
        local nf = p.flushes > 0 and p.flushes or 1
        logger.info(string.format(
            "sketch-perf: stroke %d pts (%d ev) in %d ms; %d flushes (%d fast) avg %.1f max %.1f ms; lock %.1f blit %.1f ms; raw=%s flush=%s interval=%d",
            #stroke.points, p.frames, dur_ms,
            p.flushes, p.fast_flushes,
            p.flush_ms / nf, p.max_flush_ms,
            p.lock_ms / nf, p.blit_ms / nf,
            tostring(self.raw_input_enabled), self.fast_flush_state,
            self.current_refresh_interval or self.refresh_interval_ms))
    end
end

function Sketch:expandDirtyRegion(x, y, w, h)
    if self.dirty_region then
        local r = self.dirty_region
        local x2 = math.max(r.x + r.w, x + w)
        local y2 = math.max(r.y + r.h, y + h)
        r.x = math.min(r.x, x)
        r.y = math.min(r.y, y)
        r.w = x2 - r.x
        r.h = y2 - r.y
    else
        self.dirty_region = { x = x, y = y, w = w, h = h }
    end
end

-- Push the accumulated dirty region to the e-ink screen, rate-limited
-- during a stroke. The cadence is adaptive: each flush is timed, and the
-- interval backs off to 1.5× the last flush cost (never under the
-- refresh_interval_ms floor) — refreshes run synchronously in the input
-- loop, so pushing them faster than they complete makes ink lag *more*.
function Sketch:maybeRefresh(force)
    if not self.dirty_region then return end
    local now = time.now()
    local since_ms = time.to_ms(now - self.last_refresh_time)
    local interval = self.current_refresh_interval or self.refresh_interval_ms
    if not force and since_ms < interval then
        -- Too soon. Make sure the accumulated ink still reaches the screen
        -- even if no further input event arrives (end of a slow stroke).
        if not self.flush_scheduled then
            self.flush_scheduled = function()
                self.flush_scheduled = nil
                self:maybeRefresh(true)
            end
            UIManager:scheduleIn(
                math.max(interval - since_ms, 1) / 1000,
                self.flush_scheduled)
        end
        return
    end
    if self.flush_scheduled then
        UIManager:unschedule(self.flush_scheduled)
        self.flush_scheduled = nil
    end
    self.last_refresh_time = now
    local r = self.dirty_region
    self.dirty_region = nil
    local rx = math.max(0, math.floor(r.x))
    local ry = math.max(0, math.floor(r.y))
    local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
    local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
    if rw <= 0 or rh <= 0 then return end

    local fast = self:canFastFlush()
    local t0 = time.now()
    if fast then
        Screen._sketch_dirty_rect = { x = rx, y = ry, w = rw, h = rh }
    end
    Screen:refreshFast(rx, ry, rw, rh)
    Screen._sketch_dirty_rect = nil -- consumed by the patched _updateWindow
    local cost_ms = time.to_ms(time.now() - t0)

    self.current_refresh_interval = math.max(self.refresh_interval_ms, cost_ms * 1.5)

    local p = self.perf
    if p then
        p.flushes = p.flushes + 1
        p.flush_ms = p.flush_ms + cost_ms
        if cost_ms > p.max_flush_ms then p.max_flush_ms = cost_ms end
        if fast and not self.fast_flush_broken then
            p.fast_flushes = p.fast_flushes + 1
            p.lock_ms = p.lock_ms + (Screen._sketch_lock_ms or 0)
            p.blit_ms = p.blit_ms + (Screen._sketch_blit_ms or 0)
        end
    end
end

-- A "fast" e-ink refresh is binary and leaves artifacts; once the user
-- stops writing for a moment, redo the written area (only!) with a proper
-- grayscale pass. Full-screen refreshes on a 10" panel are what makes
-- drawing UIs feel slow, so everything here is region-limited.
function Sketch:scheduleDelayedRefresh()
    self:cancelPendingRefresh(true)
    self.pending_refresh = function()
        self.pending_refresh = nil
        local region = self:bboxToRegion(self.cleanup_region, 0)
        self.cleanup_region = nil
        UIManager:setDirty(self.view.dialog, "ui", region)
    end
    UIManager:scheduleIn(self.refresh_delay_ms / 1000, self.pending_refresh)
end

function Sketch:cancelPendingRefresh(keep_cleanup_region)
    if self.pending_refresh then
        UIManager:unschedule(self.pending_refresh)
        self.pending_refresh = nil
    end
    if not keep_cleanup_region then
        self.cleanup_region = nil
    end
end

-- Convert an {x0,y0,x1,y1} stroke bbox (plus padding) into a screen-clamped
-- Geom usable as a setDirty refresh region. Returns nil for empty regions.
function Sketch:bboxToRegion(bbox, pad)
    if not bbox then return nil end
    local x0 = math.max(0, math.floor(bbox.x0 - pad))
    local y0 = math.max(0, math.floor(bbox.y0 - pad))
    local x1 = math.min(Screen:getWidth(), math.ceil(bbox.x1 + pad))
    local y1 = math.min(Screen:getHeight(), math.ceil(bbox.y1 + pad))
    if x1 <= x0 or y1 <= y0 then return nil end
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- Union bbox of a list of strokes, as a padded refresh region.
function Sketch:strokesRegion(strokes)
    local bbox
    local max_width = 3
    for _, stroke in ipairs(strokes) do
        bbox = SketchGeometry.bboxUnion(bbox, SketchGeometry.computeStrokeBbox(stroke))
        if stroke.width and stroke.width > max_width then
            max_width = stroke.width
        end
    end
    return self:bboxToRegion(bbox, max_width + 4)
end

-- Render a line segment as stamped squares (BlitBuffer has no line primitive).
-- Same approach as pencil.koplugin.
function Sketch:drawLineSegment(bb, x1, y1, x2, y2, width, color)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    local half_w = math.floor(width / 2)

    if dist < 1 then
        bb:paintRect(x1 - half_w, y1 - half_w, width, width, color)
        return
    end

    local steps = math.ceil(dist)
    for i = 0, steps do
        local t = i / steps
        local x = math.floor(x1 + dx * t)
        local y = math.floor(y1 + dy * t)
        bb:paintRect(x - half_w, y - half_w, width, width, color)
    end
end

function Sketch:renderStroke(bb, stroke)
    if not stroke.points or #stroke.points < 1 then return end
    local width = stroke.width or 3
    local color = self.pen_color

    if #stroke.points == 1 then
        local p = stroke.points[1]
        local half_w = math.floor(width / 2)
        bb:paintRect(p.x - half_w, p.y - half_w, width, width, color)
    else
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            self:drawLineSegment(bb, p1.x, p1.y, p2.x, p2.y, width, color)
        end
    end
end

-- View module hook: ReaderView calls this on every repaint, so saved
-- strokes reappear whenever the page is (re)drawn.
function Sketch:paintTo(bb, x, y)
    local page = self:getCurrentPage()
    local indices = self.page_strokes[page]
    if indices then
        for _, idx in ipairs(indices) do
            local stroke = self.strokes[idx]
            if stroke then
                self:renderStroke(bb, stroke)
            end
        end
    end
    -- Keep live ink visible if something repaints mid-stroke (footer clock,
    -- toolbar interaction, ...).
    if self.current_stroke and self.current_stroke.page == page then
        self:renderStroke(bb, self.current_stroke)
    end
end

-- ------------------------------------------------------------------------
-- Eraser (whole-stroke eraser, like pencil.koplugin)
-- ------------------------------------------------------------------------

function Sketch:eraseAt(x, y)
    local page = self:getCurrentPage()
    local page_indices = self.page_strokes[page]
    if not page_indices or #page_indices == 0 then return end

    local deleted = {}
    local indices_to_remove = {}
    for _, i in ipairs(page_indices) do
        local stroke = self.strokes[i]
        if stroke and SketchGeometry.isPointNearStroke(x, y, stroke, ERASER_RADIUS) then
            table.insert(deleted, stroke)
            table.insert(indices_to_remove, i)
        end
    end
    if #indices_to_remove == 0 then return end

    table.sort(indices_to_remove, function(a, b) return a > b end)
    for _, idx in ipairs(indices_to_remove) do
        table.remove(self.strokes, idx)
    end
    self:rebuildPageIndex()

    for _, stroke in ipairs(deleted) do
        table.insert(self.eraser_deleted, stroke)
    end

    -- Repaint so erased ink disappears under the finger — but only refresh
    -- the erased strokes' area; a full-screen e-ink pass here would make
    -- every eraser hit take ~half a second.
    UIManager:setDirty(self.view.dialog, "ui", self:strokesRegion(deleted))
end

function Sketch:finalizeErase()
    if self.eraser_deleted and #self.eraser_deleted > 0 then
        table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_deleted })
        self.redo_stack = {}
        self.session_dirty = true
        self:scheduleSave()
    end
    self.eraser_deleted = nil
end

-- ------------------------------------------------------------------------
-- Undo / redo
-- ------------------------------------------------------------------------

function Sketch:removeStrokeObject(stroke)
    for i, s in ipairs(self.strokes) do
        if s == stroke then
            table.remove(self.strokes, i)
            return true
        end
    end
    return false
end

function Sketch:undo()
    local op = table.remove(self.undo_stack)
    if not op then
        UIManager:show(InfoMessage:new{ text = _("Nothing to undo"), timeout = 1 })
        return
    end
    if op.type == "add" then
        self:removeStrokeObject(op.stroke)
    else -- delete
        for _, s in ipairs(op.strokes) do
            table.insert(self.strokes, s)
        end
    end
    table.insert(self.redo_stack, op)
    self:afterHistoryChange(op)
end

function Sketch:redo()
    local op = table.remove(self.redo_stack)
    if not op then
        UIManager:show(InfoMessage:new{ text = _("Nothing to redo"), timeout = 1 })
        return
    end
    if op.type == "add" then
        table.insert(self.strokes, op.stroke)
    else -- delete
        for _, s in ipairs(op.strokes) do
            self:removeStrokeObject(s)
        end
    end
    table.insert(self.undo_stack, op)
    self:afterHistoryChange(op)
end

function Sketch:afterHistoryChange(op)
    self:rebuildPageIndex()
    self.session_dirty = true
    self:scheduleSave()
    -- Refresh only the affected strokes' area: a full-screen e-ink pass per
    -- undo/redo tap is what makes it feel slow.
    local region
    if op then
        region = self:strokesRegion(op.type == "add" and { op.stroke } or op.strokes)
    end
    UIManager:setDirty(self.view.dialog, "ui", region)
end

-- ------------------------------------------------------------------------
-- Tool island
-- ------------------------------------------------------------------------

-- (Re)build the island and install it as the canvas' child widget.
function Sketch:buildIsland()
    if not self.canvas then return end

    local btn = function(text, callback)
        return Button:new{
            text = text,
            callback = callback,
            bordersize = 0,
            margin = 0,
            radius = 0,
            padding_h = Size.padding.large,
            padding_v = Size.padding.button,
            text_font_size = 18,
            text_font_bold = false,
            show_parent = self.canvas,
        }
    end
    local span = function() return HorizontalSpan:new{ width = Size.span.horizontal_default } end

    local tool_label = self.current_tool == TOOL_PEN and _("Pen") or _("Eraser")
    local width_label = T(_("%1 px"), self.pen_width)

    -- Kept as a field: the width picker dialog anchors to this button.
    self.width_button = btn(width_label, function() self:showWidthPicker() end)

    local group = HorizontalGroup:new{
        btn(tool_label, function() self:toggleTool() end),
        span(),
        self.width_button,
        span(),
        btn(_("Undo"), function() self:undo() end),
        span(),
        btn(_("Redo"), function() self:redo() end),
        span(),
        btn(_("Save"), function() self:exitSketchMode(true) end),
        span(),
        btn(_("Clear"), function() self:onClearButton() end),
        span(),
        btn(_("Cancel"), function() self:onCancelButton() end),
    }

    self.toolbar_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.default,
        group,
    }

    -- The island is rebuilt whenever its labels change; a fresh
    -- MovableContainer would reset a dragged island back to its origin,
    -- so carry the drag offset over to the new one.
    local offset_x, offset_y = 0, 0
    if self.island_movable then
        offset_x = self.island_movable._moved_offset_x or 0
        offset_y = self.island_movable._moved_offset_y or 0
    end
    self.island_movable = MovableContainer:new{
        self.toolbar_frame,
    }
    self.island_movable._moved_offset_x = offset_x
    self.island_movable._moved_offset_y = offset_y

    self.canvas[1] = BottomContainer:new{
        -- Keep the island clear of the footer; MovableContainer lets the
        -- user drag it elsewhere if it covers something.
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() - Screen:scaleBySize(40) },
        self.island_movable,
    }
end

-- Rebuild so button labels reflect current tool/width.
function Sketch:refreshIsland()
    if not self.sketch_mode or not self.canvas then return end
    self:buildIsland()
    -- Repaint from the reader up, not just the canvas: the canvas is a
    -- transparent container, so repainting it alone would draw the new
    -- island on top of the old one's stale pixels (the "two islands" bug).
    UIManager:setDirty(self.view.dialog, "ui")
end

function Sketch:toggleTool()
    self.current_tool = self.current_tool == TOOL_PEN and TOOL_ERASER or TOOL_PEN
    self:refreshIsland()
end

-- Width picker: a small list anchored to the island's width button —
-- opens upward when the island sits in the lower half of the screen (its
-- default position), downward when it has been dragged to the top.
function Sketch:showWidthPicker()
    local dialog
    local buttons = {}
    for _, w in ipairs(PEN_WIDTHS) do
        table.insert(buttons, {
            {
                text = (w == self.pen_width and "\u{2713} " or "") .. T(_("%1 px"), w),
                callback = function()
                    self.pen_width = w
                    G_reader_settings:saveSetting("sketch_pen_width", w)
                    UIManager:close(dialog)
                    self:refreshIsland()
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        buttons = buttons,
        anchor = function()
            local d = self.width_button and self.width_button.dimen
            if not d then return end -- island not painted yet: centered fallback
            if d.y + math.floor(d.h / 2) > math.floor(Screen:getHeight() / 2) then
                -- Drop-up: dialog bottom sits just above the button.
                return Geom:new{ x = d.x, y = d.y - Size.padding.small, w = 0, h = 0 }
            else
                -- Drop-down: dialog top sits just below the button.
                return Geom:new{ x = d.x, y = d.y + d.h + Size.padding.small, w = 0, h = 0 }, true
            end
        end,
    }
    UIManager:show(dialog)
end

function Sketch:onClearButton()
    local page = self:getCurrentPage()
    local indices = self.page_strokes[page]
    if not indices or #indices == 0 then
        UIManager:show(InfoMessage:new{ text = _("Nothing to clear on this page"), timeout = 1 })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Clear all sketches on this page?"),
        ok_text = _("Clear"),
        ok_callback = function()
            self:clearPageStrokes()
        end,
    })
end

function Sketch:onCancelButton()
    if not self.session_dirty then
        self:exitSketchMode(true)
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Discard the changes made in this sketch session?"),
        ok_text = _("Discard"),
        ok_callback = function()
            self:exitSketchMode(false)
        end,
    })
end

-- ------------------------------------------------------------------------
-- Page tracking
-- ------------------------------------------------------------------------

-- Stable page reference: real page number for paged documents (PDF/DjVu),
-- xpointer-derived page number for rolling documents (EPUB).
function Sketch:getCurrentPage()
    if self.ui.paging then
        return self.view.state.page
    end
    local xp = self.ui.document:getXPointer()
    if xp and self.ui.document.getPageFromXPointer then
        return self.ui.document:getPageFromXPointer(xp)
    end
    return xp
end

-- Extra anchor stored per stroke so a future version can re-resolve pages
-- after reflow (font change etc.). Unused for rendering today.
function Sketch:getCurrentXPointer()
    if self.ui.rolling and self.ui.document and self.ui.document.getXPointer then
        local ok, xp = pcall(self.ui.document.getXPointer, self.ui.document)
        if ok then return xp end
    end
    return nil
end

function Sketch:indexStroke(stroke_idx, page)
    if not self.page_strokes[page] then
        self.page_strokes[page] = {}
    end
    table.insert(self.page_strokes[page], stroke_idx)
end

function Sketch:rebuildPageIndex()
    self.page_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        self:indexStroke(i, stroke.page)
    end
end

-- ------------------------------------------------------------------------
-- Persistence (sidecar file next to KOReader's own metadata)
-- ------------------------------------------------------------------------

function Sketch:getStrokesFilePath()
    if not self.ui or not self.ui.doc_settings then return nil end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if not sidecar_dir then return nil end
    return sidecar_dir .. "/sketch_strokes.lua"
end

function Sketch:loadStrokes()
    local filepath = self:getStrokesFilePath()
    if not filepath then
        self.strokes = {}
        self.page_strokes = {}
        return
    end

    local f = io.open(filepath, "r")
    if not f then
        self.strokes = {}
        self.page_strokes = {}
        self.strokes_loaded = true
        return
    end
    f:close()

    local ok, data = pcall(dofile, filepath)
    if ok and data and data.strokes then
        self.strokes = data.strokes
        self:rebuildPageIndex()
        self.strokes_loaded = true
        logger.info("Sketch: loaded", #self.strokes, "strokes from", filepath)
    else
        logger.warn("Sketch: failed to load strokes from", filepath, "error:", data)
        self.strokes = {}
        self.page_strokes = {}
    end
end

function Sketch:scheduleSave()
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
    end
    self.pending_save = function()
        self.pending_save = nil
        self:saveStrokes()
    end
    UIManager:scheduleIn(self.save_delay_s, self.pending_save)
end

function Sketch:flushSave()
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
        self.pending_save = nil
    end
    self:saveStrokes()
end

function Sketch:saveStrokes()
    local filepath = self:getStrokesFilePath()
    if not filepath then
        logger.warn("Sketch: no sidecar path available, cannot save")
        return
    end
    -- Never overwrite existing data with an empty list unless we actually
    -- loaded that data first (protects against save-before-load).
    if #self.strokes == 0 and not self.strokes_loaded then
        return
    end

    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        local ok, err = lfs.mkdir(sidecar_dir)
        if not ok and err ~= "File exists" then
            logger.warn("Sketch: failed to create sidecar dir:", err)
        end
    end

    local data = {
        version = 1,
        strokes = self.strokes,
    }
    local f, err = io.open(filepath, "w")
    if f then
        f:write("return " .. require("dump")(data))
        f:close()
        logger.info("Sketch: saved", #self.strokes, "strokes to", filepath)
    else
        logger.err("Sketch: failed to write", filepath, "error:", err)
    end
end

-- ------------------------------------------------------------------------
-- Document / page lifecycle
-- ------------------------------------------------------------------------

function Sketch:onReaderReady()
    if not self.strokes_loaded then
        self:loadStrokes()
    end
end

function Sketch:onPageUpdate(pageno)
    self:finalizeCurrentStroke()
    self:finalizeErase()
    self.raw_claimed_slot = nil
    self.drawing_contact = false
    if self.pending_save then
        self:flushSave()
    end
end

Sketch.onUpdatePos = Sketch.onPageUpdate

function Sketch:onCloseDocument()
    if self.sketch_mode then
        self:exitSketchMode(true)
    end
    self:finalizeCurrentStroke()
    self:cancelPendingRefresh()
    self:flushSave()
end

function Sketch:onSuspend()
    self:flushSave()
end

-- ------------------------------------------------------------------------
-- Menu
-- ------------------------------------------------------------------------

function Sketch:addToMainMenu(menu_items)
    menu_items.sketch = {
        text = _("Sketch"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Enter sketch mode"),
                callback = function()
                    self:enterSketchMode()
                end,
                help_text = _("Tip: assign 'Sketch: toggle drawing mode' to a gesture (e.g. two-finger tap on a corner) in Gesture manager."),
            },
            {
                text = _("Clear sketches on this page"),
                enabled_func = function()
                    local page = self:getCurrentPage()
                    return self.page_strokes[page] and #self.page_strokes[page] > 0 or false
                end,
                callback = function()
                    self:clearPageStrokes()
                end,
            },
            {
                text = _("Performance"),
                sub_item_table = {
                    {
                        text = _("Raw pen input"),
                        help_text = _("Read pen points straight from input frames instead of gestures: tiny strokes and stroke starts stop being swallowed, and ink latency drops. Disable if drawing misbehaves."),
                        checked_func = function() return self.raw_input_enabled end,
                        callback = function()
                            self.raw_input_enabled = not self.raw_input_enabled
                            G_reader_settings:saveSetting("sketch_raw_input", self.raw_input_enabled)
                            if self.raw_input_enabled then
                                if self.sketch_mode then self:installRawInput() end
                            elseif self.raw_claimed_slot then
                                self:rawFinalize()
                            end
                        end,
                    },
                    {
                        text = _("Fast partial screen flush"),
                        help_text = _("Blit only the stroke's bounding box to the screen on each live-ink refresh instead of the whole framebuffer. Disable if you see screen corruption while drawing."),
                        checked_func = function()
                            return self.fast_flush_enabled and not self.fast_flush_broken
                        end,
                        callback = function()
                            self.fast_flush_enabled = not self.fast_flush_enabled
                            G_reader_settings:saveSetting("sketch_fast_flush", self.fast_flush_enabled)
                            if self.fast_flush_enabled and self.sketch_mode then
                                self:installFastFlush()
                            end
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Clear all sketches in this book"),
                enabled_func = function()
                    return #self.strokes > 0
                end,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete all %1 sketch strokes in this book?"), #self.strokes),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            self.strokes = {}
                            self:rebuildPageIndex()
                            self.undo_stack = {}
                            self.redo_stack = {}
                            self:flushSave()
                            UIManager:setDirty(self.view.dialog, "ui")
                        end,
                    })
                end,
            },
        },
    }
end

function Sketch:clearPageStrokes()
    local page = self:getCurrentPage()
    local indices = self.page_strokes[page]
    if not indices or #indices == 0 then return end

    local sorted = {}
    for _, idx in ipairs(indices) do
        table.insert(sorted, idx)
    end
    table.sort(sorted, function(a, b) return a > b end)

    local deleted = {}
    for _, idx in ipairs(sorted) do
        if self.strokes[idx] then
            table.insert(deleted, self.strokes[idx])
            table.remove(self.strokes, idx)
        end
    end
    if #deleted > 0 then
        table.insert(self.undo_stack, { type = "delete", strokes = deleted })
        self.redo_stack = {}
        self.session_dirty = true
    end
    self:rebuildPageIndex()
    self:flushSave()
    UIManager:setDirty(self.view.dialog, "ui")
end

return Sketch
