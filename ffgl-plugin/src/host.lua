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

-- Loads the text of a .trigit file. A Set already running is replaced without
-- losing the Playhead or the current Song. Returns whether it loaded.
function host.load(text)
    local ok, document = pcall(json.decode, text)
    if not ok or type(document) ~= "table" or document.format ~= "TrigIT Set" or type(document.set) ~= "table" then
        state.message = "Not a TrigIT Set file"
        return false
    end
    local set = document.set
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
    state.message = ("Loaded %s: %d Songs"):format(tostring(set.name), #(set.songs or {}))
    if skipped > 0 then state.message = state.message .. (", %d Actions are not OSC and will not be sent"):format(skipped) end
    return true
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
