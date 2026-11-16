-- SPDX-License-Identifier: GPL-3.0-or-later
-- The Show Engine inside an FFGL plugin: feeds it Art-Net Timecode packets
-- and turns the Actions it sends into OSC datagrams. Pure: the C++ core owns
-- the sockets and the clock, and sets host.send(address, port, bytes).
-- The engine, timecode and json modules are ma3-plugin/src's, unchanged.

local json = require("json")
local engine = require("engine")
local timecode = require("timecode")

local host = {}
host.send = function() return false end

local RATES = { [0] = "24", "25", "29.97 DF", "30" }
local state = { armed = false, names = {}, message = "No Set loaded" }

-- The timecode ("hh:mm:ss:ff") and frame rate of an ArtTimeCode packet, as
-- Sources/TrigITProtocols/ArtNetTimecode.swift reads it; nil for anything else.
function host.artTimecode(bytes)
    if #bytes < 19 or bytes:sub(1, 10) ~= "Art-Net\0\0\x97" then return nil end
    local f, s, m, h, kind = bytes:byte(15, 19)
    local rate = RATES[kind]
    local info = rate and timecode.RATES[rate]
    if not info or h > 23 or m > 59 or s > 59 or f >= info.nominal then return nil end
    -- Drop-frame has no frames 0 and 1 at the start of a minute, except each tenth.
    if info.dropFrame and s == 0 and f < 2 and m % 10 ~= 0 then return nil end
    return ("%02d:%02d:%02d:%02d"):format(h, m, s, f), rate
end

local function padded(text)
    return text .. ("\0"):rep(4 - #text % 4)
end

-- The OSC 1.0 packet for a Set's OSC message, as OSCMessage.encoded() in
-- Sources/TrigITProtocols/OSC.swift; nil and a reason if it can't be encoded.
function host.osc(message)
    local address = message and message.address
    if type(address) ~= "string" or address:sub(1, 1) ~= "/" then return nil, "no OSC address" end
    local tags, values = ",", {}
    for _, argument in ipairs(message.arguments or {}) do
        if argument.int then
            tags, values[#values + 1] = tags .. "i", (">i4"):pack(math.floor(argument.int))
        elseif argument.float then
            tags, values[#values + 1] = tags .. "f", (">f"):pack(argument.float)
        elseif argument.string then
            tags, values[#values + 1] = tags .. "s", padded(argument.string)
        else
            return nil, "an OSC argument that is not int, float or string"
        end
    end
    return padded(address) .. padded(tags) .. table.concat(values)
end

local function send(event)
    local song, action, destination = state.names[event.song] or "?", event.action, event.destination
    local what = ("%s to %s"):format(song, tostring(destination.name))
    if action.type ~= "osc" then
        state.message = what .. " not sent: the FFGL plugin sends OSC only"
        return
    end
    local bytes, reason = host.osc(action.osc)
    if bytes and destination.usesOSC == false then bytes, reason = nil, "OSC is off for this Destination" end
    if bytes and not host.send(tostring(destination.host), destination.port, bytes) then
        bytes, reason = nil, "could not send to " .. tostring(destination.host)
    end
    state.message = bytes and (what .. ": " .. action.osc.address) or (what .. " not sent: " .. reason)
end

local function apply(events)
    for _, event in ipairs(events) do
        if event.kind == "send" then
            send(event)
        elseif event.kind == "missingDestination" then
            state.message = (state.names[event.song] or "?") .. ": an Action has no Destination"
        elseif event.kind == "currentSongChanged" then
            state.song = event.song
        elseif event.kind == "alertChanged" then
            state.alert = event.alert
        elseif event.kind == "stopped" then
            state.message = "Timecode stopped"
        end
    end
end

-- Makes `set` the running Set, keeping the Playhead and the current Song.
local function install(set, what)
    local skipped = 0
    state.names = {}
    for _, song in ipairs(set.songs or {}) do
        state.names[song.id] = song.name
        for _, list in ipairs({ song.startActions or {}, song.stopActions or {} }) do
            for _, action in ipairs(list) do
                if action.type ~= "osc" then skipped = skipped + 1 end
            end
        end
    end
    if state.engine then state.engine:updateSet(set) else state.engine = engine.new(set, state.armed) end
    state.message = ("Loaded %s: %d Songs"):format(what, #(set.songs or {}))
    if skipped > 0 then state.message = state.message .. (", %d Actions are not OSC and will not be sent"):format(skipped) end
end

-- The last timecode before `start`, as a string that sorts just below it.
local function before(start)
    local h, m, s, f = start:match("^(%d+):(%d+):(%d+):(%d+)$")
    local seconds, frames = (h * 60 + m) * 60 + s, tonumber(f)
    if frames > 0 then return start:sub(1, 9) .. ("%02d"):format(frames - 1) end
    seconds = math.max(seconds - 1, 0)
    return ("%02d:%02d:%02d:99"):format(seconds // 3600, seconds // 60 % 60, seconds % 60)
end

-- A Cue's OSC message: a column number launches that Resolume column; text
-- starting "/" is an OSC address, then its arguments, separated by spaces.
local function cueMessage(target)
    local column = math.tointeger(tonumber(target))
    if column and column > 0 then
        return { address = ("/composition/columns/%d/connect"):format(column), arguments = { { int = 1 } } }
    end
    local address, rest = target:match("^(/%S*)%s*(.*)$")
    if not address then return nil end
    local arguments = {}
    for word in rest:gmatch("%S+") do
        local number = tonumber(word)
        arguments[#arguments + 1] = math.type(number) == "integer" and { int = number }
            or number and { float = number } or { string = word }
    end
    return { address = address, arguments = arguments }
end

-- The Set the Cues typed into the plugin's parameters make: each Cue is a
-- Song from its time to the next Cue's, with one OSC Action to this computer.
-- nil if no Cue is filled in; a problem with one is returned as text.
local function cueSet()
    local byStart, starts, problem = {}, {}, nil
    for index, cue in ipairs(state.cues or {}) do
        local time, target = cue.time:gsub("%s", ""):gsub(";", ":"), cue.target:match("^%s*(.-)%s*$")
        if time ~= "" or target ~= "" then
            local h, m, s = time:match("^(%d%d):(%d%d):(%d%d):%d%d$")
            local message = cueMessage(target)
            if not h or tonumber(h) > 23 or tonumber(m) > 59 or tonumber(s) > 59 then
                problem = problem or ("Cue %d: the time must be hh:mm:ss:ff"):format(index)
            elseif not message then
                problem = problem or ("Cue %d: give a column number or an OSC address"):format(index)
            else
                if not byStart[time] then
                    byStart[time] = { id = "cue" .. index, name = "Cue " .. index, start = time, startActions = {}, stopActions = {} }
                    starts[#starts + 1] = time
                end
                local actions = byStart[time].startActions
                actions[#actions + 1] = { id = "cue" .. index .. "a", destination = "cues", type = "osc", osc = message }
            end
        end
    end
    if #starts == 0 then return nil, problem end
    table.sort(starts)
    local songs = {}
    for i, start in ipairs(starts) do
        songs[i] = byStart[start]
        songs[i]["end"] = starts[i + 1] and before(starts[i + 1]) or "23:59:59:99"
    end
    return {
        songs = songs,
        destinations = { { id = "cues", name = "Resolume", host = "127.0.0.1", port = state.cuePort, usesOSC = true } },
    }, problem
end

-- The Cues are the Set if any is filled in; otherwise the file is.
local function rebuild()
    local set, problem = cueSet()
    if set then
        install(set, "the Cues")
    elseif state.fileSet then
        install(state.fileSet, tostring(state.fileSet.name))
    else
        if state.engine then state.engine:updateSet({}) end
        state.message = "No Set loaded"
    end
    if problem then state.message = problem end
end

-- Loads the text of a .trigit file. Returns whether it is a Set.
function host.load(text)
    local ok, document = pcall(json.decode, text)
    if not ok or type(document) ~= "table" or document.format ~= "TrigIT Set" or type(document.set) ~= "table" then
        state.message = "Not a TrigIT Set file"
        return false
    end
    state.fileSet = document.set
    rebuild()
    return true
end

-- The Cue parameters: lists of times and targets, and Resolume's OSC port.
function host.setCues(times, targets, port)
    state.cues, state.cuePort = {}, math.tointeger(tonumber(port)) or 7000
    for index, time in ipairs(times) do state.cues[index] = { time = time, target = targets[index] or "" } end
    rebuild()
end

function host.setArmed(armed)
    state.armed = armed
    if state.engine then apply(state.engine:setArmed(armed)) end
end

-- One UDP payload from the Art-Net port, received at `now` (seconds, monotonic).
function host.packet(bytes, now)
    local position, rate = host.artTimecode(bytes)
    if position and state.engine then
        apply(state.engine:handle({ timecode = position, frameRate = rate, timestamp = now }))
    end
end

function host.tick(now)
    if state.engine then apply(state.engine:tick(now)) end
end

-- Playhead, current Song's name, armed, alert, last message.
function host.status()
    local running = state.engine
    return running and running.playhead or "", state.song and state.names[state.song] or "",
        state.armed, state.alert or "", state.message
end

return host
