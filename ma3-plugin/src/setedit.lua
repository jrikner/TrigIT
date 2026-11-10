-- SPDX-License-Identifier: GPL-3.0-or-later
-- Making and editing a Set on the console (#96), with the Mac app's rules
-- (SetEditing.swift): a Song needs a name and a span whose end isn't before
-- its start, and no two Songs' spans share a frame. Works on the Set table
-- as trigit_plan.readSet returns it, so fields the console doesn't know
-- survive a save. Pure Lua, no MA calls.

local json = require("json")
local plan = require("trigit_plan")

local edit = {}

local function trim(text) return ((text or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- IDs are decimal strings of 64-bit numbers, as the Mac app writes them.
function edit.newID() return tostring(math.random(1, math.maxinteger)) end

function edit.newSet(name)
    return { id = edit.newID(), name = trim(name) ~= "" and trim(name) or "Untitled Set", songs = {}, destinations = {}, stopTime = 2 }
end

-- The whole .trigit file.
function edit.encode(set)
    return json.encode({ format = "TrigIT Set", version = 1, set = set }) .. "\n"
end

local function find(list, id)
    for i, item in ipairs(list or {}) do if item.id == id then return item, i end end
end

function edit.song(set, id) return (find(set.songs, id)) end

-- Adds a Song (id nil) or changes one's name, start and end. Returns the
-- Song, or nil and why not, in the Mac app's words.
function edit.putSong(set, id, name, start, finish)
    name = trim(name)
    if name == "" then return nil, "the name is empty" end
    local from = plan.parseTimecode(start or "")
    if not from then return nil, ('start "%s" is not a timecode (hh:mm:ss:ff)'):format(trim(start)) end
    local to = plan.parseTimecode(finish or "")
    if not to then return nil, ('end "%s" is not a timecode (hh:mm:ss:ff)'):format(trim(finish)) end
    if to < from then return nil, "end is before start" end
    for _, other in ipairs(set.songs) do
        if other.id ~= id and other.start and other["end"] and other.start <= to and from <= other["end"] then
            return nil, ('overlaps "%s"'):format(other.name or "")
        end
    end
    local song = id and edit.song(set, id)
    if id and not song then return nil, "that Song is gone" end
    if not song then
        song = { id = edit.newID(), startActions = {}, stopActions = {} }
        set.songs[#set.songs + 1] = song
    end
    song.name, song.start, song["end"] = name, from, to
    return song
end

function edit.deleteSong(set, id)
    local _, i = find(set.songs, id)
    if i then table.remove(set.songs, i) end
end

-- Moves a Song up (-1) or down (+1) in the list.
function edit.moveSong(set, id, by)
    local _, i = find(set.songs, id)
    local j = i and i + by
    if not j or j < 1 or j > #set.songs then return end
    set.songs[i], set.songs[j] = set.songs[j], set.songs[i]
end

function edit.destinationNamed(set, name)
    for _, d in ipairs(set.destinations) do
        if (d.name or ""):lower() == trim(name):lower() then return d end
    end
end

-- Adds or changes the OSC Destination called `name`. Returns it, or nil and why not.
function edit.putDestination(set, name, host, port)
    name, host = trim(name), trim(host)
    if name == "" then return nil, "the Destination needs a name" end
    local octets = { host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
    if #octets ~= 4 then return nil, ('"%s" is not an IP address, such as 192.168.1.20'):format(host) end
    for _, octet in ipairs(octets) do
        if tonumber(octet) > 255 then return nil, ('"%s" is not an IP address, such as 192.168.1.20'):format(host) end
    end
    port = math.tointeger(tonumber(trim(tostring(port or ""))))
    if not port or port < 1 or port > 65535 then return nil, "the port must be 1-65535" end
    local d = edit.destinationNamed(set, name)
    if not d then
        d = { id = edit.newID(), name = name }
        set.destinations[#set.destinations + 1] = d
    end
    d.host, d.port, d.usesOSC = host, port, true
    return d
end

-- Adds an Action to a Song, typed as in the CSV format: kind "osc",
-- "midi-note" or "dmx", target (OSC address, note, universe.channel), value
-- (OSC arguments, velocity, DMX value), when "start" or "stop". The
-- Destination must exist. Returns the Action, or nil and why not.
function edit.addAction(set, songID, destination, kind, target, value, when)
    local song = edit.song(set, songID)
    if not song then return nil, "that Song is gone" end
    local d = edit.destinationNamed(set, destination)
    if not d then return nil, ('there is no Destination "%s"'):format(trim(destination)) end
    local parsed, why = plan.parseAction({ "", "", "", d.name, trim(kind), trim(target), trim(value), trim(when) })
    if not parsed then return nil, why or "the Action is empty" end
    local action = { id = edit.newID(), destination = d.id, type = parsed.type }
    action[parsed.type] = parsed[parsed.type]
    if parsed.type == "midiNote" then d.usesMIDI = true end
    if parsed.type == "dmxPulse" then d.usesDMX = true end
    local list = parsed.phase == "stop" and "stopActions" or "startActions"
    song[list] = song[list] or {}
    table.insert(song[list], action)
    return action
end

function edit.removeAction(set, songID, actionID)
    local song = edit.song(set, songID)
    for _, list in ipairs({ "startActions", "stopActions" }) do
        local _, i = find(song and song[list], actionID)
        if i then return table.remove(song[list], i) end
    end
end

-- "Start: OSC /go 1 to Resolume", for lists.
function edit.describe(set, action, phase)
    local d = find(set.destinations, action.destination)
    local body, what = action[action.type] or {}, nil
    if action.type == "osc" then
        local args = {}
        for _, a in ipairs(body.arguments or {}) do
            args[#args + 1] = a.string and ('"%s"'):format(a.string) or tostring(a.int or a.float or "")
        end
        what = ("OSC %s%s"):format(body.address or "?", #args > 0 and " " .. table.concat(args, " ") or "")
    elseif action.type == "midiNote" then
        what = ("note %d/%d velocity %d"):format((body.channel or 0) + 1, body.note or 0, body.velocity or 127)
    elseif action.type == "dmxPulse" then
        what = ("DMX %d.%d at %d"):format(body.universe or 0, body.channel or 0, body.value or 255)
    else
        what = action.type or "?"
    end
    return ("%s: %s to %s"):format(phase == "stop" and "Stop" or "Start", what, d and d.name or "?")
end

-- The Mac app's Action presets (Presets.swift), in its words. Each fills an
-- ordinary OSC Action; nothing remembers the preset. Resolume triggers send
-- int 1; grandMA3 commands go to "/cmd" (Receive Command on the console's
-- OSC line). The MSC "GO cue" preset is left out: the console can't send MSC.
edit.PRESETS = {
    { label = "Resolume: launch column", fields = { "Column" }, address = "/composition/columns/%d/connect" },
    { label = "Resolume: launch clip", fields = { "Layer", "Column" }, address = "/composition/layers/%d/clips/%d/connect" },
    { label = "Resolume: clear layer", fields = { "Layer" }, address = "/composition/layers/%d/clear" },
    { label = "Resolume: clear composition", fields = {}, address = "/composition/disconnectall" },
    { label = "Resolume: next column", fields = {}, address = "/composition/connectnextcolumn" },
    { label = "Resolume: previous column", fields = {}, address = "/composition/connectprevcolumn" },
    { label = "Resolume: tempo resync", fields = {}, address = "/composition/tempocontroller/resync" },
    { label = "grandMA3: Go+ executor (OSC)", fields = { "Page", "Executor" }, command = "Go+ Exec %d.%d" },
    { label = "grandMA3: command (OSC)", fields = { "Command" }, command = "%s" },
}

-- A preset's OSC address and arguments (as addAction takes them) from what
-- was typed in its fields, or nil and why not.
function edit.preset(preset, values)
    local numbers = {}
    for i, field in ipairs(preset.fields) do
        local text = trim(values[i])
        if preset.command and field == "Command" then
            if text == "" then return nil, "the command is empty" end
            numbers[i] = text
        else
            local n = text:match("^%d+$") and tonumber(text)
            if not n or n < 1 then return nil, ('%s "%s" is not a number from 1'):format(field, text) end
            numbers[i] = n
        end
    end
    if preset.address then return preset.address:format(table.unpack(numbers)), "1" end
    local command = preset.command:format(table.unpack(numbers))
    return "/cmd", '"' .. command:gsub('[\\"]', "\\%0") .. '"'
end

return edit
