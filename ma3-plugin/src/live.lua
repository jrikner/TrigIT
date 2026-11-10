-- SPDX-License-Identifier: GPL-3.0-or-later
-- The Show Engine on the console: feeds it a timecode slot's time, turns the
-- Actions it sends into MA commands, and keeps the short log the panel shows.
-- Pure: the adapter reads the slot, runs the commands and passes the clock.

local engine = require("engine")
local timecode = require("timecode")
local plan = require("trigit_plan")
local commands = require("commands")

local live = {}
live.LOG_LENGTH = 8

local Live = {}
Live.__index = Live

-- `set` as engine.new takes it; `rate` one of timecode.RATES; `lineFor(destination)`
-- the In & Out OSC line number for a Set Destination, or nil if it has none.
function live.new(set, rate, lineFor, armed)
    local names = {}
    for _, song in ipairs(set.songs or {}) do names[song.id] = song.name end
    return setmetatable({
        engine = engine.new(set, armed), rate = rate, lineFor = lineFor, names = names,
        log = {}, outbox = {}, later = {}, fired = {}, positions = {},
    }, Live)
end

local function describe(action)
    local body = action[action.type] or {}
    if action.type == "osc" then return "OSC " .. tostring(body.address) end
    if action.type == "midiNote" then return ("note %s/%s"):format(tostring((body.channel or 0) + 1), tostring(body.note)) end
    if action.type == "msc" then return "MSC" end
    return ("DMX pulse %s.%s"):format(tostring(body.universe), tostring(body.channel))
end

function Live:note(text, failed)
    table.insert(self.log, 1, { time = self.engine.playhead or "", text = text, failed = failed })
    self.log[live.LOG_LENGTH + 1] = nil
end

function Live:send(event, now)
    local song, destination = self.names[event.song] or "?", event.destination
    local command, release = plan.liveCommand(event.action, destination)
    if command and event.action.type == "osc" then
        local line = self.lineFor(destination)
        if line then
            command = command:gsub(commands.OSC_LINE:gsub("%p", "%%%0"), tostring(line))
        else
            command, release = nil, ('no OSC line for "%s": import the Set, or name a line "TrigIT %s"')
                :format(destination.name, destination.name)
        end
    end
    local what = ("%s: %s to %s"):format(song, describe(event.action), destination.name)
    if not command then return self:note(what .. " not sent: " .. release, true) end
    self.outbox[#self.outbox + 1] = command
    if type(release) == "table" then self.later[#self.later + 1] = { at = now + release.after, command = release.command } end
    self:note(what)
end

function Live:apply(events, now)
    for _, event in ipairs(events) do
        local kind, name = event.kind, self.names[event.song]
        if kind == "send" then
            self:send(event, now)
        elseif kind == "missingDestination" then
            self:note((name or "?") .. ": an Action's Destination isn't in the Set; not sent", true)
        elseif kind == "fired" then
            self.fired[event.song] = true
            self:note(name .. (event.cause == "manual" and " fired by hand" or " entered")
                .. ((self.engine.isArmed or event.cause == "manual") and "" or " (disarmed: nothing sent)"))
        elseif kind == "ended" then
            self:note(name .. (event.cause == "manual" and " stopped by hand" or " ended"))
        elseif kind == "jumped" then
            self:note("Jump to " .. event.to)
        elseif kind == "stopped" then
            self:note("Timecode stopped")
        elseif kind == "dropout" then
            self:note(("Dropout of %.1f s"):format(event.seconds), true)
        end
    end
end

-- A reading of a slot: `seconds` of timecode at clock time `now`, from the
-- "primary" (default) or "backup" slot. Only a new frame is a reading, so a
-- slot that has stopped moving goes quiet: tick() finds the Stop, and the
-- engine switches to the other slot if that one is still running.
function Live:follow(seconds, now, role)
    role = role or "primary"
    local position = timecode.fromSeconds(seconds, self.rate)
    if position == self.positions[role] then return end
    self.positions[role] = position
    self:apply(self.engine:handle({ timecode = position, frameRate = self.rate, timestamp = now }, role), now)
end

function Live:tick(now)
    self:apply(self.engine:tick(now), now)
    for i = #self.later, 1, -1 do
        if self.later[i].at <= now then
            self.outbox[#self.outbox + 1] = table.remove(self.later, i).command
        end
    end
end

-- An edited Set (#96): the engine takes it without firing anything.
function Live:updateSet(set)
    for _, song in ipairs(set.songs or {}) do self.names[song.id] = song.name end
    self.engine:updateSet(set)
end

function Live:setArmed(armed) self:apply(self.engine:setArmed(armed), 0) end
function Live:fire(id, now) self:apply(self.engine:fire(id), now) end
function Live:fireStop(id, now) self:apply(self.engine:fireStop(id), now) end

-- The commands to run now, in order; each is returned once.
function Live:take()
    local out = self.outbox
    self.outbox = {}
    return out
end

-- Bridge mode: which slot's frames go to the Mac. An engine with no Set
-- decides, so the Backup takes over and hands back as on the Mac app: once the
-- Primary is lost, and back only after both stop.
local Source = {}
Source.__index = Source

function live.source(rate) return setmetatable({ engine = engine.new(), rate = rate }, Source) end

-- True if this reading, as for Live:follow, is from the slot to send.
function Source:feed(seconds, now, role)
    self.engine:handle({ timecode = timecode.fromSeconds(seconds, self.rate), frameRate = self.rate, timestamp = now }, role)
    return role == self.engine.liveSource
end

function Source:tick(now) self.engine:tick(now) end

return live
