-- SPDX-License-Identifier: GPL-3.0-or-later
-- The Swift engine tests (Tests/TrigITEngineTests: ShowEngineTests,
-- FiringRulesTests, FailoverTests, NoteTriggerTests), ported one for one:
-- scripted readings go in, only the events that come out are checked.

local engine = require("engine")
local timecode = require("timecode")

-- MARK: Helpers, as Timeline and DualTimeline in the Swift tests

local function song(id, name, start, finish, extra)
    local s = { id = id, name = name, start = start, ["end"] = finish, startActions = {}, stopActions = {} }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

local resolume = { id = "10", name = "Resolume", host = "10.0.0.20", port = 7000, usesOSC = true }

local function osc(id, address)
    return { id = id, destination = resolume.id, type = "osc", osc = { address = address, arguments = {} } }
end

local function of(kind, events, field)
    local out = {}
    for _, event in ipairs(events) do
        if event.kind == kind then out[#out + 1] = field and event[field] or event end
    end
    return out
end

local function has(events, predicate)
    for _, event in ipairs(events) do if predicate(event) then return true end end
    return false
end
local function kindIs(kind) return function(e) return e.kind == kind end end
local function count(events, kind) return #of(kind, events) end

local Timeline = {}
Timeline.__index = Timeline

-- Readings one per frame at `rate`, with a clock that advances in step.
local function timeline(set, rate, armed)
    return setmetatable({ engine = engine.new(set, armed), rate = rate or "25", events = {}, now = 1000 }, Timeline)
end

function Timeline:add(events) for _, e in ipairs(events) do self.events[#self.events + 1] = e end end

-- Plays `frames` frames from `start` (a Jump unless it is the natural next
-- frame) or on from the last position.
function Timeline:play(start, frames)
    local index = start and timecode.index(start, self.rate)
        or (self.position and timecode.index(self.position, self.rate) + 1) or 0
    for _ = 1, frames do
        local position = timecode.fromIndex(index, self.rate)
        self:add(self.engine:handle({ timecode = position, frameRate = self.rate, timestamp = self.now }))
        self.position = position
        index = index + 1
        self.now = self.now + 1 / timecode.RATES[self.rate].real
    end
end

-- No readings for `seconds`, while the clock ticks every 10 ms.
function Timeline:silence(seconds)
    local finish = self.now + seconds
    while self.now < finish - 0.000001 do
        self.now = self.now + 0.01
        self:add(self.engine:tick(self.now))
    end
end

-- Where playback would be `seconds` after the last reading.
function Timeline:after(seconds)
    local real = timecode.RATES[self.rate].real
    return timecode.fromIndex(timecode.index(self.position or "00:00:00:00", self.rate)
        + math.floor(seconds * real + 0.5), self.rate)
end

function Timeline:fired() return of("fired", self.events, "song") end
function Timeline:ended()
    local out = {}
    for _, e in ipairs(of("ended", self.events)) do out[#out + 1] = { e.song, e.cause } end
    return out
end
function Timeline:sentActions()
    local out = {}
    for _, e in ipairs(of("send", self.events)) do out[#out + 1] = e.action.id end
    return out
end
function Timeline:songChanges()
    local out = {}
    for _, e in ipairs(of("currentSongChanged", self.events)) do out[#out + 1] = e.song or false end
    return out
end
function Timeline:clear() self.events = {} end
function Timeline:fire(id) self:add(self.engine:fire(id)) end
function Timeline:fireStop(id) self:add(self.engine:fireStop(id)) end
function Timeline:note(trigger, velocity) self:add(self.engine:handleNoteOn(trigger.channel, trigger.note, velocity or 100)) end
function Timeline:setArmed(armed) self:add(self.engine:setArmed(armed)) end

-- MARK: ShowEngineTests

describe("following timecode", function()
    local intro = song("1", "Intro", "01:00:00:00", "01:03:00:00")
    local anthem = song("2", "Anthem", "01:03:00:01", "01:06:00:00")
    local outro = song("3", "Outro", "02:00:00:00", "02:04:00:00")
    local t
    before_each(function() t = timeline({ songs = { intro, anthem, outro } }) end)

    it("plays into a Song and fires it once", function()
        t:play("00:59:59:10", 10)
        assert.same({}, t:fired())
        t:play(nil, 50)
        assert.same({ "1" }, t:fired())
    end)

    it("fires a Song on a first reading inside it", function()
        t:play("01:01:00:00", 1)
        assert.same({ "1" }, t:fired())
    end)

    it("fires a Song a Jump lands inside", function()
        t:play("00:30:00:00", 25)
        t:play("02:02:10:00", 25)
        assert.same({ "3" }, t:fired())
        assert.is_true(has(t.events, function(e)
            return e.kind == "jumped" and e.from == "00:30:00:24" and e.to == "02:02:10:00"
        end))
    end)

    it("doesn't fire again when playing or jumping within the same Song", function()
        t:play("01:00:00:00", 100)
        t:play("01:02:00:00", 25)
        t:play("01:00:30:00", 25)
        assert.same({ "1" }, t:fired())
        assert.equal(2, count(t.events, "jumped"))
    end)

    it("fires the next Song when playing straight into it", function()
        t:play("01:02:59:20", 20)
        assert.same({ "1", "2" }, t:fired())
    end)

    it("fires a Song again after leaving it and coming back", function()
        t:play("01:00:00:00", 25)
        t:play("01:30:00:00", 25)
        t:play("01:00:10:00", 25)
        assert.same({ "1", "1" }, t:fired())
    end)

    it("fires both when jumping to another Song and back", function()
        t:play("01:00:00:00", 25)
        t:play("02:00:00:00", 25)
        t:play("01:01:00:00", 25)
        assert.same({ "1", "3", "1" }, t:fired())
    end)

    it("fires nothing in a gap, and reports no Song change", function()
        t:play("01:10:00:00", 250)
        t:play("00:00:00:00", 25)
        assert.same({}, t:fired())
        assert.same({}, t:songChanges())
    end)

    it("clears the current Song when leaving into a gap", function()
        t:play("01:05:59:20", 10)
        assert.is_nil(t.engine.currentSong)
        assert.same({ "2", false }, t:songChanges())
    end)

    it("never sees natural playback as a Jump, at any frame rate", function()
        for rate, info in pairs(timecode.RATES) do
            local tl = timeline({}, rate)
            tl:play("00:09:59:00", 3 * 60 * info.nominal)
            assert.equal(0, count(tl.events, "jumped"), rate)
        end
    end)

    it("reports the frame rate and changes to it", function()
        t:play("00:00:00:00", 5)
        t.rate = "30"
        t:play(nil, 5)
        assert.same({ "25", "30" }, of("frameRateChanged", t.events, "frameRate"))
        assert.equal("30", t.engine.frameRate)
    end)

    it("fires nothing on a Set edit until the next reading", function()
        t:play("03:00:00:00", 5)
        local encore = song("9", "Encore", "03:00:00:00", "03:10:00:00")
        t.engine:updateSet({ songs = { encore } })
        assert.same({}, t:fired())
        t:play(nil, 1)
        assert.same({ "9" }, t:fired())
    end)
end)

-- MARK: FiringRulesTests

describe("Stop, Dropout, Ending and manual firing", function()
    local startA, stopA, startB, stopB = osc("1", "/song/a/start"), osc("2", "/song/a/stop"), osc("3", "/song/b/start"), osc("4", "/song/b/stop")
    -- A plays straight into B; C comes later after a gap.
    local songA = song("1", "A", "01:00:00:00", "01:00:10:00", { startActions = { startA }, stopActions = { stopA } })
    local songB = song("2", "B", "01:00:10:01", "01:00:20:00", { startActions = { startB }, stopActions = { stopB } })
    local songC = song("3", "C", "02:00:00:00", "02:00:10:00")
    local function make(armed, stopTime)
        return timeline({ songs = { songA, songB, songC }, destinations = { resolume }, stopTime = stopTime or 2 }, "25", armed ~= false)
    end

    it("treats a gap just under the Stop time as a Dropout that doesn't refire", function()
        local t = make()
        t:play("01:00:01:00", 25)
        t:silence(1.9)
        t:play(t:after(1.9), 25)
        assert.same({ "1" }, t:fired())
        assert.equal(0, count(t.events, "stopped"))
        assert.is_true(has(t.events, kindIs("dropout")))
        assert.same({ "1" }, t:sentActions())
    end)

    it("treats a gap just over the Stop time as a Stop, and resuming refires", function()
        local t = make()
        t:play("01:00:01:00", 25)
        t:silence(2.1)
        assert.equal(1, count(t.events, "stopped"))
        assert.equal("1", t.engine.currentSong)
        t:play(nil, 25)
        assert.same({ "1", "1" }, t:fired())
        assert.same({ "1", "1" }, t:sentActions())
        assert.same({}, t:ended())
    end)

    it("takes the Stop time from the Set, within its range", function()
        local t = make(true, 0.5)
        t:play("01:00:01:00", 25)
        t:silence(0.6)
        assert.equal(1, count(t.events, "stopped"))
        local floor = make(true, 0) -- clamped to 0.5 s
        floor:play("01:00:01:00", 25)
        floor:silence(0.4)
        assert.equal(0, count(floor.events, "stopped"))
    end)

    it("reports a Stop once, and a resume after it is neither a Jump nor a Dropout", function()
        local t = make()
        t:play("00:30:00:00", 25)
        t:silence(10)
        t:play("00:45:00:00", 25)
        assert.equal(1, count(t.events, "stopped"))
        assert.equal(0, count(t.events, "jumped"))
        assert.equal(0, count(t.events, "dropout"))
    end)

    it("doesn't see silence before any timecode as a Stop", function()
        local t = make()
        t:silence(5)
        assert.same({}, t.events)
    end)

    it("keeps the Song current through a Stop inside it, without Ending it", function()
        local t = make()
        t:play("01:00:05:00", 10)
        t:silence(3)
        assert.equal(1, count(t.events, "stopped"))
        assert.same({}, t:ended())
        assert.same({ "1" }, t:sentActions())
        assert.equal("1", t.engine.currentSong)
        assert.same({ "1" }, t:songChanges())
    end)

    it("still Ends the Song when playing past its end after a Stop", function()
        local t = make()
        t:play("01:00:09:00", 10)
        t:silence(3)
        t:play(nil, 30)
        assert.same({ { "1", "playedPastEnd" } }, t:ended())
        assert.same({ "1", "1", "2", "3" }, t:sentActions())
    end)

    it("Ends nothing on a Stop in a gap", function()
        local t = make()
        t:play("01:30:00:00", 10)
        t:silence(3)
        assert.same({}, t:ended())
    end)

    it("Ends a Song played past its end", function()
        local t = make()
        t:play("02:00:09:20", 10)
        assert.same({ { "3", "playedPastEnd" } }, t:ended())
        assert.is_nil(t.engine.currentSong)
    end)

    it("sends Stop Actions before the next Song's Start Actions", function()
        local t = make()
        t:play("01:00:09:20", 10)
        assert.same({ "1", "2", "3" }, t:sentActions())
        local endedAt, firedAt
        for i, e in ipairs(t.events) do
            if e.kind == "ended" and e.song == "1" then endedAt = i end
            if e.kind == "fired" and e.song == "2" then firedAt = i end
        end
        assert.is_true(endedAt < firedAt)
    end)

    it("sends no Stop Actions on a Jump out of a Song", function()
        local t = make()
        t:play("01:00:05:00", 10)
        t:play("02:00:05:00", 10)
        t:play("01:30:00:00", 10)
        assert.same({}, t:ended())
        assert.same({ "1" }, t:sentActions())
    end)

    it("doesn't End a Song when playing backwards out of its start", function()
        local t = make()
        t:play("01:00:10:05", 1)
        t:clear()
        for _, frame in ipairs({ "01:00:10:04", "01:00:10:03", "01:00:10:02", "01:00:10:01", "01:00:10:00", "01:00:09:24" }) do
            t:play(frame, 1)
        end
        for _, e in ipairs(t:ended()) do assert.is_false(e[1] == "2" and e[2] == "playedPastEnd") end
    end)

    it("Ends a Song exactly once when resuming past its last frame after a Stop", function()
        local t = make()
        t:play("01:00:19:15", 11)
        assert.equal("01:00:20:00", t.engine.playhead)
        t:silence(5)
        t:play("01:00:20:01", 10)
        assert.same({ { "2", "playedPastEnd" } }, t:ended())
        assert.same({ "3", "4" }, t:sentActions())
    end)

    it("doesn't End anything when resuming elsewhere after a Stop", function()
        local t = make()
        t:play("01:00:05:00", 10)
        t:silence(3)
        t:play("02:00:01:00", 10)
        assert.same({}, t:ended())
        assert.same({ "1" }, t:sentActions())
        assert.equal("3", t.engine.currentSong)
    end)

    it("clears the current Song without Ending it when resuming in a gap after a Stop", function()
        local t = make()
        t:play("01:00:05:00", 10)
        t:silence(3)
        t:play("01:30:00:00", 10)
        assert.same({}, t:ended())
        assert.is_nil(t.engine.currentSong)
    end)

    it("still Ends the Song after a Dropout across its end", function()
        local t = make()
        t:play("01:00:09:00", 10)
        t:silence(1.5)
        t:play(t:after(1.5), 5)
        assert.same({ { "1", "playedPastEnd" } }, t:ended())
        assert.same({ "1", "2", "3" }, t:sentActions())
    end)

    it("Ends a Song only once per Entering", function()
        local t = make()
        t:play("01:00:09:20", 10)
        t:silence(3)
        t:silence(3)
        assert.same({ { "1", "playedPastEnd" } }, t:ended())
    end)

    it("sends nothing while disarmed but still tracks Ending", function()
        local t = make(false)
        t:play("01:00:09:20", 10)
        t:silence(3)
        assert.same({}, t:sentActions())
        assert.same({ { "1", "playedPastEnd" } }, t:ended())
    end)

    it("fires Start Actions by hand even while disarmed, without moving the current Song", function()
        local t = make(false)
        t:fire("2")
        assert.same({ kind = "fired", song = "2", cause = "manual" }, t.events[1])
        assert.same({ "3" }, t:sentActions())
        assert.same({ "manualFire" }, of("send", t.events, "reason"))
        assert.is_nil(t.engine.currentSong)
    end)

    it("sends Stop Actions by hand even while disarmed", function()
        local t = make(false)
        t:fireStop("1")
        assert.same({ kind = "ended", song = "1", cause = "manual" }, t.events[1])
        assert.same({ "2" }, t:sentActions())
        assert.same({ "manualStop" }, of("send", t.events, "reason"))
    end)

    it("does nothing when firing an unknown Song by hand", function()
        local t = make()
        t:fire("999")
        t:fireStop("999")
        assert.same({}, t.events)
    end)

    it("reports Stop Actions whose Destination was deleted", function()
        local a = song("1", "A", "01:00:00:00", "01:00:10:00", { stopActions = { stopA } })
        local t = timeline({ songs = { a }, destinations = {}, stopTime = 2 }, "25", true)
        t:play("01:00:09:20", 10)
        assert.is_true(has(t.events, function(e) return e.kind == "missingDestination" and e.song == "1" and e.action == "2" end))
    end)
end)

-- MARK: FailoverTests

local Dual = {}
Dual.__index = Dual
setmetatable(Dual, { __index = Timeline })

-- A Primary and a Backup in step, one reading per frame each, the clock
-- ticking between frames.
local function dual(set)
    return setmetatable({ engine = engine.new(set, true), rate = "25", events = {}, now = 1000 }, Dual)
end

-- Plays from `start` (or on). The Backup runs `offset` frames ahead.
function Dual:play2(start, seconds, primary, backup, offset, backupFirst)
    local index = start and timecode.index(start, self.rate)
        or (self.position and timecode.index(self.position, self.rate) + 1) or 0
    for _ = 1, math.floor(seconds * 25) do
        local codes = { primary = timecode.fromIndex(index, self.rate), backup = timecode.fromIndex(index + (offset or 0), self.rate) }
        local on = { primary = primary, backup = backup }
        for _, role in ipairs(backupFirst and { "backup", "primary" } or { "primary", "backup" }) do
            if on[role] then
                self:add(self.engine:handle({ timecode = codes[role], frameRate = self.rate, timestamp = self.now }, role))
            end
        end
        self.position = codes.primary
        index = index + 1
        self.now = self.now + 0.002
        self:add(self.engine:tick(self.now))
        self.now = self.now + 1 / 25 - 0.002
    end
end

function Dual:liveChanges() return of("liveSourceChanged", self.events, "role") end
function Dual:alerts()
    local out = {}
    for _, e in ipairs(of("alertChanged", self.events)) do out[#out + 1] = e.alert or false end
    return out
end

describe("Primary and Backup failover", function()
    local startA = { id = "1", destination = resolume.id, type = "osc", osc = { address = "/a", arguments = {} } }
    local songA = song("1", "A", "01:00:00:00", "01:10:00:00", { startActions = { startA } })
    local function make() return dual({ songs = { songA }, destinations = { resolume }, stopTime = 2 }) end

    it("switches to a healthy Backup without Stop, Dropout or refiring", function()
        local s = make()
        s:play2("01:00:01:00", 2, true, true)
        assert.same({ "1" }, s:fired())
        s:play2(nil, 3, false, true)
        assert.same({ "backup" }, s:liveChanges())
        assert.same({ "1" }, s:fired())
        assert.equal(1, count(s.events, "send"))
        assert.equal(0, count(s.events, "stopped"))
        assert.equal(0, count(s.events, "dropout"))
        assert.equal(0, count(s.events, "ended"))
        assert.is_true(has(s.events, function(e) return e.kind == "sourceHealthChanged" and e.role == "primary" and not e.healthy end))
        assert.same({ "primaryLostRunningOnBackup" }, s:alerts())
        assert.equal("1", s.engine.currentSong)
        assert.equal(s.position, s.engine.playhead)
    end)

    it("stays on the Backup when the Primary returns mid-Song", function()
        local s = make()
        s:play2("01:00:01:00", 2, true, true)
        s:play2(nil, 1, false, true)
        s:play2(nil, 3, true, true)
        assert.same({ "backup" }, s:liveChanges())
        assert.equal("backup", s.engine.liveSource)
        assert.same({ "1" }, s:fired())
        assert.same({ "primaryLostRunningOnBackup", false }, s:alerts())
    end)

    it("returns to the Primary at the next Stop", function()
        local s = make()
        s:play2("01:00:01:00", 2, true, true)
        s:play2(nil, 1, false, true)
        s:play2(nil, 1, true, true)
        s:silence(3)
        assert.equal(1, count(s.events, "stopped"))
        assert.same({ "backup", "primary" }, s:liveChanges())
        assert.equal("primary", s.engine.liveSource)
        assert.is_nil(s.engine.alert)
        s:clear()
        s:play2("01:00:30:00", 1, true, false, 0)
        s:play2(nil, 1, true, true, 250)
        assert.same({}, s:liveChanges())
        assert.equal(s.position, s.engine.playhead)
        assert.same({ "1" }, s:fired())
    end)

    it("follows the Primary when both resume after a Stop, even if the Backup is first", function()
        local s = make()
        s:play2("01:00:01:00", 1, true, true)
        s:silence(3)
        s:clear()
        s:play2("01:00:05:00", 1, true, true, 0, true)
        assert.same({}, s:liveChanges())
        assert.equal("primary", s.engine.liveSource)
    end)

    it("treats both lost briefly as a Dropout, with the all-lost alert", function()
        local s = make()
        s:play2("01:00:01:00", 2, true, true)
        s:silence(1)
        s:play2(s:after(1), 1, true, true)
        assert.same({}, s:liveChanges())
        assert.equal(0, count(s.events, "stopped"))
        assert.is_true(has(s.events, kindIs("dropout")))
        assert.same({ "1" }, s:fired())
        assert.same({ "allTimecodeLost", false }, s:alerts())
    end)

    it("treats both lost longer than the Stop time as a Stop", function()
        local s = make()
        s:play2("01:00:01:00", 2, true, true)
        s:silence(3)
        assert.equal(1, count(s.events, "stopped"))
        assert.equal(0, count(s.events, "ended"))
        assert.same({ "allTimecodeLost", false }, s:alerts())
        s:play2(nil, 1, true, true)
        assert.same({ "1", "1" }, s:fired())
    end)

    it("lets the Backup alone take over after both were lost, with a Dropout", function()
        local s = make()
        s:play2("01:00:01:00", 2, true, true)
        s:silence(1)
        s:play2(s:after(1), 1, false, true)
        assert.same({ "backup" }, s:liveChanges())
        assert.equal(0, count(s.events, "stopped"))
        assert.is_true(has(s.events, kindIs("dropout")))
        assert.same({ "1" }, s:fired())
        assert.same({ "allTimecodeLost", "primaryLostRunningOnBackup" }, s:alerts())
    end)

    it("without a Backup, losing the Primary is a normal Dropout and Stop", function()
        local s = make()
        s:play2("01:00:01:00", 2, true, false)
        s:silence(3)
        assert.same({}, s:liveChanges())
        assert.equal(1, count(s.events, "stopped"))
        assert.same({ "allTimecodeLost", false }, s:alerts())
    end)
end)

-- MARK: NoteTriggerTests

describe("Start Notes and Stop Notes", function()
    local startA, stopA, startB, pullUp = osc("1", "/a/start"), osc("2", "/a/stop"), osc("3", "/b/start"), osc("4", "/pullup")
    local noteA, stopNoteA = { channel = 0, note = 60 }, { channel = 0, note = 61 }
    local noteB, pullUpNote = { channel = 1, note = 60 }, { channel = 0, note = 72 }
    -- A: span and both notes. B: span only. P: only a Start Note. Q: only a Stop Note.
    local songA = song("1", "A", "01:00:00:00", "01:00:10:00",
        { startNote = noteA, stopNote = stopNoteA, startActions = { startA }, stopActions = { stopA } })
    local songB = song("2", "B", "01:00:20:00", "01:00:30:00", { startActions = { startB } })
    local songP = song("3", "P", nil, nil, { startNote = noteB, startActions = { startB } })
    local songQ = song("4", "Q", nil, nil, { stopNote = pullUpNote, stopActions = { pullUp } })
    local function make(armed)
        return timeline({ songs = { songA, songB, songP, songQ }, destinations = { resolume } }, "25", armed ~= false)
    end

    it("Enters a Song on its Start Note with no timecode", function()
        local t = make()
        t:note(noteA)
        assert.same({ { kind = "fired", song = "1", cause = "note" } }, of("fired", t.events))
        assert.same({ "1" }, t:sentActions())
        assert.equal("1", t.engine.currentSong)
    end)

    it("fires nothing on the current Song's Start Note", function()
        local t = make()
        t:note(noteA)
        t:clear()
        t:note(noteA)
        assert.same({}, t.events)
    end)

    it("fires nothing when timecode enters a Song its Start Note already fired", function()
        local t = make()
        t:note(noteA)
        t:clear()
        t:play("01:00:00:00", 50)
        assert.same({}, t:fired())
        assert.same({}, t:sentActions())
        assert.equal("1", t.engine.currentSong)
    end)

    it("Ends the Song and sends its Stop Actions on a Stop Note after a timecode Stop", function()
        local t = make()
        t:play("01:00:01:00", 25)
        t:silence(3)
        t:clear()
        t:note(stopNoteA)
        assert.same({ { "1", "note" } }, t:ended())
        assert.same({ "2" }, t:sentActions())
        assert.is_nil(t.engine.currentSong)
    end)

    it("sends the current Song's Stop Actions once on its Stop Note", function()
        local t = make()
        t:play("01:00:01:00", 25)
        t:clear()
        t:note(stopNoteA)
        t:note(stopNoteA)
        t:play(nil, 25)
        assert.same({ { "1", "note" } }, t:ended())
        assert.same({ "2" }, t:sentActions())
        assert.is_nil(t.engine.currentSong)
    end)

    it("sends nothing on a timecode Stop after the Stop Note", function()
        local t = make()
        t:play("01:00:01:00", 25)
        t:note(stopNoteA)
        t:clear()
        t:silence(3)
        assert.same({}, t:ended())
        assert.same({}, t:sentActions())
    end)

    it("sends nothing on a Stop Note for a Song that isn't current", function()
        local t = make()
        t:note(stopNoteA)
        t:play("01:00:21:00", 25)
        t:clear()
        t:note(stopNoteA)
        assert.same({}, t.events)
    end)

    it("sends a Stop-Note-only Song's Stop Actions every time, never making it current", function()
        local t = make()
        t:note(pullUpNote)
        t:play("01:00:01:00", 25)
        t:note(pullUpNote)
        assert.same({ { "4", "note" }, { "4", "note" } }, t:ended())
        assert.same({ "4", "1", "4" }, t:sentActions())
        for _, changed in ipairs(t:songChanges()) do assert.not_equal("4", changed) end
        assert.equal("1", t.engine.currentSong)
    end)

    it("keeps a Start-Note-only Song current through a timecode Stop", function()
        local t = make()
        t:play("00:59:00:00", 25)
        t:note(noteB)
        t:play(nil, 50)
        assert.equal("3", t.engine.currentSong)
        t:silence(3)
        assert.same({}, t:ended())
        assert.equal("3", t.engine.currentSong)
    end)

    it("keeps a Start-Note-only Song current until another Song Enters", function()
        local t = make()
        t:note(noteB)
        t:play("00:59:59:00", 20)
        assert.equal("3", t.engine.currentSong)
        t:play(nil, 10)
        assert.equal("1", t.engine.currentSong)
        assert.same({ "3", "1" }, t:fired())
    end)

    it("ignores Note On with velocity 0", function()
        local t = make()
        t:note(noteA, 0)
        t:note(pullUpNote, 0)
        assert.same({}, t.events)
    end)

    it("ignores a note on another channel", function()
        local t = make()
        t:note({ channel = 2, note = 60 })
        assert.same({}, t.events)
    end)

    it("sends nothing while disarmed but tracks the current Song", function()
        local t = make(false)
        t:note(noteA)
        t:note(pullUpNote)
        assert.equal("1", t.engine.currentSong)
        t:note(stopNoteA)
        assert.is_nil(t.engine.currentSong)
        assert.same({}, t:sentActions())
        t:setArmed(true)
        t:note(noteA)
        assert.same({ "1" }, t:sentActions())
    end)
end)

describe("timecode", function()
    it("counts frames as the Mac app does, drop-frame included", function()
        assert.equal(90000, timecode.index("01:00:00:00", "25"))
        assert.equal(1800, timecode.index("00:01:00:02", "29.97 DF"))
        assert.equal("00:01:00:02", timecode.fromIndex(1800, "29.97 DF"))
        assert.equal("00:10:00:00", timecode.fromIndex(timecode.index("00:10:00:00", "29.97 DF"), "29.97 DF"))
        assert.equal("23:59:59:24", timecode.fromIndex(-1, "25"))
    end)
end)
