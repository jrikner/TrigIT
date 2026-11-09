-- SPDX-License-Identifier: GPL-3.0-or-later
-- TrigIT's Show Engine in Lua: a line-for-line port of
-- Sources/TrigITEngine/ShowEngine.swift, with the same rules (GLOSSARY.md).
-- It follows timecode readings and decides when Songs fire and End. Pure: no
-- MA calls, no clock; time comes in through reading timestamps and tick().
--
-- The Set is the "set" of a decoded .trigit file: songs (id, name, start, end,
-- startNote, stopNote, startActions, stopActions; no start means no span),
-- destinations (with id) and stopTime. Timecodes are "hh:mm:ss:ff" strings.
--
-- Every call returns a list of events, in order, each a table with `kind`:
--   playheadMoved {timecode}            frameRateChanged {frameRate}
--   jumped {from, to}                   currentSongChanged {song} (nil: none)
--   fired {song, cause}                 cause: "entering" | "note" | "manual"
--   ended {song, cause}                 cause: "playedPastEnd" | "note" | "manual"
--   stopped                             dropout {seconds}
--   send {song, action, destination, reason}
--                                       reason: "entering" | "ending" | "manualFire" | "manualStop"
--   missingDestination {song, action}   armedChanged {armed}
--   sourceHealthChanged {role, healthy} liveSourceChanged {role}  role: "primary" | "backup"
--   alertChanged {alert}                alert: "primaryLostRunningOnBackup" | "allTimecodeLost" | nil

local timecode = require("timecode")

local engine = {}

-- How far, in frames, the Playhead may land from where natural playback
-- would have put it before the move counts as a Jump.
engine.JUMP_TOLERANCE_FRAMES = 5
-- A gap longer than this (but shorter than the Stop time) is a Dropout.
engine.DROPOUT_THRESHOLD = 0.2
-- A Timecode Source with no reading for longer than this is lost.
engine.SOURCE_LOSS_TIME = 0.25
engine.DEFAULT_STOP_TIME = 2
local STOP_TIME_MIN, STOP_TIME_MAX = 0.5, 30
local ROLES = { "primary", "backup" }

local Engine = {}
Engine.__index = Engine

local function append(list, more)
    for _, item in ipairs(more) do list[#list + 1] = item end
    return list
end

-- A Set ready for the engine: Songs keep their order, Destinations by id, the
-- Stop time within its range.
local function prepare(set)
    local destinations = {}
    for _, destination in ipairs(set.destinations or {}) do destinations[destination.id] = destination end
    local stopTime = set.stopTime or engine.DEFAULT_STOP_TIME
    return {
        songs = set.songs or {},
        destinations = destinations,
        stopTime = math.min(math.max(stopTime, STOP_TIME_MIN), STOP_TIME_MAX),
    }
end

-- `set` as described above; `armed` false unless given.
function engine.new(set, armed)
    return setmetatable({
        set = prepare(set or {}),
        isArmed = armed == true,
        isStopped = false,
        liveSource = "primary",
        playhead = nil, frameRate = nil, alert = nil,
        currentSong = nil, -- the Song most recently Entered, by timecode or note
        timecodeSong = nil, -- the Song whose span contains the Playhead
        stoppedAt = nil, -- where timecode was at a Stop, until the next reading
        lastReading = nil, -- the last reading followed, from the live source
        lastReadings = {}, -- the last reading from each source
        healthy = {},
        resumedAt = nil, -- when timecode last started arriving after silence or a Stop
    }, Engine)
end

function Engine:song(id)
    for _, song in ipairs(self.set.songs) do
        if song.id == id then return song end
    end
end

-- The Song whose span contains `position`; the first in list order if a
-- hand-made Set overlaps.
function Engine:songAt(position)
    for _, song in ipairs(self.set.songs) do
        if song.start and song.start <= position and position <= song["end"] then return song end
    end
end

function Engine:setArmed(armed)
    if armed == self.isArmed then return {} end
    self.isArmed = armed
    return { { kind = "armedChanged", armed = armed } }
end

-- Replaces the Set. Nothing fires here; the next reading applies it.
function Engine:updateSet(set)
    self.set = prepare(set)
end

-- The sends for one of a Song's Action lists, in list order. Automatic sends
-- are suppressed while disarmed.
function Engine:sends(songID, list, reason, evenIfDisarmed)
    local song = self:song(songID)
    if not (self.isArmed or evenIfDisarmed) or not song then return {} end
    local events = {}
    for _, action in ipairs(song[list] or {}) do
        local destination = self.set.destinations[action.destination]
        if destination then
            events[#events + 1] = { kind = "send", song = songID, action = action, destination = destination, reason = reason }
        else
            events[#events + 1] = { kind = "missingDestination", song = songID, action = action.id }
        end
    end
    return events
end

function Engine:enter(songID, cause)
    local events = {}
    if songID ~= self.currentSong then events[1] = { kind = "currentSongChanged", song = songID } end
    self.currentSong = songID
    events[#events + 1] = { kind = "fired", song = songID, cause = cause }
    return append(events, self:sends(songID, "startActions", "entering"))
end

function Engine:finish(songID, cause)
    return append({ { kind = "ended", song = songID, cause = cause } }, self:sends(songID, "stopActions", "ending"))
end

-- A Jump is any landing far from where natural playback from the previous
-- reading would be by now.
function Engine:isJump(previous, reading)
    local rate = reading.frameRate
    local elapsed = math.max(0, reading.timestamp - previous.timestamp)
    local expected = timecode.index(previous.timecode, rate) + elapsed * timecode.RATES[rate].real
    return math.abs(timecode.index(reading.timecode, rate) - expected) > engine.JUMP_TOLERANCE_FRAMES
end

function Engine:follow(reading)
    local events = {}
    if reading.frameRate ~= self.frameRate then
        self.frameRate = reading.frameRate
        events[#events + 1] = { kind = "frameRateChanged", frameRate = reading.frameRate }
    end

    local jumped = false
    local restarted = self.stoppedAt ~= nil
    -- Resuming after a Stop somewhere other than where it stopped is a
    -- relocation: like a Jump, it Ends nothing.
    local relocated = restarted and math.abs(timecode.index(self.stoppedAt, reading.frameRate)
        - timecode.index(reading.timecode, reading.frameRate)) > engine.JUMP_TOLERANCE_FRAMES
    self.stoppedAt = nil
    local previous = self.lastReading
    if previous then
        local gap = reading.timestamp - previous.timestamp
        if gap > engine.DROPOUT_THRESHOLD then events[#events + 1] = { kind = "dropout", seconds = gap } end
        if self:isJump(previous, reading) then
            jumped = true
            events[#events + 1] = { kind = "jumped", from = previous.timecode, to = reading.timecode }
        end
    end
    self.isStopped = false

    if reading.timecode ~= self.playhead then
        self.playhead = reading.timecode
        events[#events + 1] = { kind = "playheadMoved", timecode = reading.timecode }
    end
    self.lastReading = reading

    local song = self:songAt(reading.timecode)
    local songID = song and song.id
    if songID == self.timecodeSong and not (restarted and songID ~= nil) then return events end
    local left = self.timecodeSong
    self.timecodeSong = songID
    -- Only leaving the current Song matters; one a note displaced is gone already.
    local leftCurrent = left ~= nil and left == self.currentSong

    -- Playing on past its end time Ends a Song, before the next Song fires.
    -- A Jump out of a Song, or playing backwards out of it, does not.
    local leftSong = leftCurrent and self:song(left)
    if leftSong and not jumped and not relocated and reading.timecode > leftSong["end"] then
        append(events, self:finish(left, "playedPastEnd"))
    end

    -- Entering: arriving inside a Song from outside it, by playing or a Jump.
    if songID ~= nil then
        if songID == self.currentSong and not restarted then return events end
        append(events, self:enter(songID, "entering"))
    elseif leftCurrent then
        self.currentSong = nil
        events[#events + 1] = { kind = "currentSongChanged", song = nil }
    end
    return events
end

function Engine:isHealthy(role, time)
    local reading = self.lastReadings[role]
    return reading ~= nil and time - reading.timestamp <= engine.SOURCE_LOSS_TIME
end

function Engine:isLost(role, time)
    if not self.resumedAt or time - self.resumedAt <= engine.SOURCE_LOSS_TIME then return false end
    return not self:isHealthy(role, time)
end

-- Reports sources going healthy or lost, and the alert that follows.
function Engine:updateHealth(time)
    local events = {}
    for _, role in ipairs(ROLES) do
        local healthy = self:isHealthy(role, time)
        if healthy ~= (self.healthy[role] == true) then
            self.healthy[role] = healthy or nil
            events[#events + 1] = { kind = "sourceHealthChanged", role = role, healthy = healthy }
        end
    end
    local alert
    if not next(self.healthy) then
        -- Silence after a Stop, or before any timecode, is normal.
        alert = not (self.isStopped or self.resumedAt == nil) and "allTimecodeLost" or nil
    elseif self.liveSource == "backup" and not self.healthy.primary then
        alert = "primaryLostRunningOnBackup"
    end
    if alert ~= self.alert then
        self.alert = alert
        events[#events + 1] = { kind = "alertChanged", alert = alert }
    end
    return events
end

-- Feeds one reading { timecode, frameRate, timestamp } from the "primary"
-- (default) or "backup" source. Only the live source moves the Playhead; if
-- it is lost while this one is healthy, this one takes over seamlessly.
function Engine:handle(reading, role)
    role = role or "primary"
    local events = {}
    local previous = self.lastReadings[role]
    self.lastReadings[role] = reading
    if self.resumedAt == nil then self.resumedAt = reading.timestamp end
    if role ~= self.liveSource then
        if not self:isLost(self.liveSource, reading.timestamp) then
            return append(events, self:updateHealth(reading.timestamp))
        end
        self.liveSource = role
        events[#events + 1] = { kind = "liveSourceChanged", role = role }
        -- Follow on from this source's own last reading if it was running.
        if previous and reading.timestamp - previous.timestamp <= engine.SOURCE_LOSS_TIME then
            self.lastReading = previous
        end
    end
    append(events, self:follow(reading))
    return append(events, self:updateHealth(reading.timestamp))
end

-- A Note On (channel 0-15). Stop Notes first: a Song with only a Stop Note
-- sends its Stop Actions every time; otherwise it Ends the Song if current.
-- Then Start Notes Enter their Songs unless already current. Velocity 0 is a
-- Note Off and is ignored.
function Engine:handleNoteOn(channel, note, velocity)
    if (velocity or 0) <= 0 then return {} end
    local function matches(trigger) return trigger and trigger.channel == channel and trigger.note == note end
    local events = {}
    for _, song in ipairs(self.set.songs) do
        if matches(song.stopNote) then
            if not song.start and not song.startNote then
                append(events, self:finish(song.id, "note"))
            elseif song.id == self.currentSong then
                append(events, self:finish(song.id, "note"))
                self.currentSong = nil
                events[#events + 1] = { kind = "currentSongChanged", song = nil }
            end
        end
    end
    for _, song in ipairs(self.set.songs) do
        if matches(song.startNote) and song.id ~= self.currentSong then append(events, self:enter(song.id, "note")) end
    end
    return events
end

-- Lets time pass with no reading. Silence longer than the Set's Stop time is
-- a Stop: no Stop Actions, the current Song stays current but is re-armed.
function Engine:tick(time)
    local last = self.lastReading
    if self.isStopped or not last or time - last.timestamp <= self.set.stopTime then
        return self:updateHealth(time)
    end
    self.isStopped = true
    self.lastReading, self.resumedAt, self.stoppedAt = nil, nil, last.timecode
    local events = { { kind = "stopped" } }
    if self.liveSource ~= "primary" then
        self.liveSource = "primary"
        events[#events + 1] = { kind = "liveSourceChanged", role = "primary" }
    end
    return append(events, self:updateHealth(time))
end

-- Fires a Song's Start Actions by hand, even while disarmed. The current Song
-- is not changed.
function Engine:fire(songID)
    if not self:song(songID) then return {} end
    return append({ { kind = "fired", song = songID, cause = "manual" } },
        self:sends(songID, "startActions", "manualFire", true))
end

-- Sends a Song's Stop Actions by hand, even while disarmed.
function Engine:fireStop(songID)
    if not self:song(songID) then return {} end
    return append({ { kind = "ended", song = songID, cause = "manual" } },
        self:sends(songID, "stopActions", "manualStop", true))
end

return engine
