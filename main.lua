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
anything it doesn't understand (multi-finger gestures) down to the reader,
so the sketch-toggle gesture and two-finger page turns keep working.

Stroke storage, rendering and erasing are adapted from pencil.koplugin by
mysticknits (https://github.com/mysticknits/pencil.koplugin, AGPL-3.0).

@module koplugin.sketch
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
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

    -- Batched partial refresh while drawing (see addPointToStroke).
    -- Each refresh blocks the input loop for the blit + e-ink update, so a
    -- too-eager cadence makes ink lag *more*, not less: events queue up
    -- behind refreshes. 33 ms (~30 fps) is plenty for e-ink.
    last_refresh_time = 0,
    refresh_interval_ms = 33,
    dirty_region = nil,
    flush_scheduled = nil, -- trailing flush so the stroke tail isn't left unrefreshed
    pending_refresh = nil,
    refresh_delay_ms = 600,
    cleanup_region = nil,  -- accumulated bbox needing a grayscale cleanup pass

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

    self.canvas = SketchCanvas:new{ sketch = self }
    self:buildIsland()
    UIManager:show(self.canvas)
    logger.info("Sketch: entered sketch mode")
end

-- save == false restores the stroke list to what it was on mode entry.
function Sketch:exitSketchMode(save)
    if not self.sketch_mode then return end
    self:finalizeCurrentStroke()
    self:finalizeErase()
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
    end
    self.sketch_mode = false
    -- Full repaint: clears discarded ink and any fast-refresh artifacts.
    UIManager:setDirty(self.view, "partial")
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
    if not self.drawing_contact and not self.current_stroke then return end
    self.drawing_contact = false
    self:finalizeErase() -- eraser deletions already happened; keep them undoable
    if self.current_stroke then
        self.current_stroke = nil
        -- Repaint to wipe the stray ink.
        UIManager:setDirty(self.view, "ui")
    end
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

    local w = self.pen_width
    local half_w = math.floor(w / 2)
    Screen.bb:paintRect(x - half_w, y - half_w, w, w, self.pen_color)
    self:expandDirtyRegion(x - half_w, y - half_w, w, w)
    self:maybeRefresh(true)
end

function Sketch:addPointToStroke(x, y)
    if not self.current_stroke then return end
    local points = self.current_stroke.points
    local n = #points
    local prev = points[n]
    -- Drop sub-2px jitter: invisible at e-ink DPI, and fewer points means
    -- faster paints, redraws and saves.
    local jx, jy = x - prev.x, y - prev.y
    if jx * jx + jy * jy < 4 then return end
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

-- Push the accumulated dirty region to the e-ink screen, rate-limited to
-- one partial refresh per refresh_interval_ms during a stroke.
function Sketch:maybeRefresh(force)
    if not self.dirty_region then return end
    local now = time.now()
    local since_ms = time.to_ms(now - self.last_refresh_time)
    if not force and since_ms < self.refresh_interval_ms then
        -- Too soon. Make sure the accumulated ink still reaches the screen
        -- even if no further pan event arrives (end of a slow stroke).
        if not self.flush_scheduled then
            self.flush_scheduled = function()
                self.flush_scheduled = nil
                self:maybeRefresh(true)
            end
            UIManager:scheduleIn(
                math.max(self.refresh_interval_ms - since_ms, 1) / 1000,
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
    local rx = math.max(0, math.floor(r.x))
    local ry = math.max(0, math.floor(r.y))
    local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
    local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
    if rw > 0 and rh > 0 then
        Screen:refreshFast(rx, ry, rw, rh)
    end
    self.dirty_region = nil
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
        UIManager:setDirty(self.view, "ui", region)
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
    UIManager:setDirty(self.view, "ui", self:strokesRegion(deleted))
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
    UIManager:setDirty(self.view, "ui", region)
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

    local group = HorizontalGroup:new{
        btn(tool_label, function() self:toggleTool() end),
        span(),
        btn(width_label, function() self:cyclePenWidth() end),
        span(),
        btn(_("Undo"), function() self:undo() end),
        span(),
        btn(_("Redo"), function() self:redo() end),
        span(),
        btn(_("Save"), function() self:exitSketchMode(true) end),
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

    self.canvas[1] = BottomContainer:new{
        -- Keep the island clear of the footer; MovableContainer lets the
        -- user drag it elsewhere if it covers something.
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() - Screen:scaleBySize(40) },
        MovableContainer:new{
            self.toolbar_frame,
        },
    }
end

-- Rebuild so button labels reflect current tool/width.
function Sketch:refreshIsland()
    if not self.sketch_mode or not self.canvas then return end
    self:buildIsland()
    UIManager:setDirty(self.canvas, "ui")
end

function Sketch:toggleTool()
    self.current_tool = self.current_tool == TOOL_PEN and TOOL_ERASER or TOOL_PEN
    self:refreshIsland()
end

function Sketch:cyclePenWidth()
    for i, w in ipairs(PEN_WIDTHS) do
        if w == self.pen_width then
            self.pen_width = PEN_WIDTHS[i % #PEN_WIDTHS + 1]
            break
        end
    end
    if not self.pen_width then self.pen_width = PEN_WIDTHS[1] end
    G_reader_settings:saveSetting("sketch_pen_width", self.pen_width)
    self:refreshIsland()
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
                            UIManager:setDirty(self.view, "ui")
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
    UIManager:setDirty(self.view, "ui")
end

return Sketch
