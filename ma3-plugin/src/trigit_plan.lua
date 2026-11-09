-- SPDX-License-Identifier: GPL-3.0-or-later
-- Turns a TrigIT Set (extended CSV or a .trigit file) into a plan for a
-- grandMA3 Timecode Show. Pure Lua 5.4: no MA API calls. The rules follow
-- TrigIT's GLOSSARY.md and the Mac app (SetEditing.swift, ShowEngine.swift).

local json = require("json")
local commands = require("commands")

local plan = {}

-- Frames per timecode second for each rate TrigIT knows (FrameRate.swift).
local FRAMES = { ["24"] = 24, ["25"] = 25, ["29.97 DF"] = 30, ["30"] = 30 }
local TRANSPORT = { osc = "osc", midiNote = "midi", msc = "midi", dmxPulse = "dmx" }
local TRANSPORT_NAME = { osc = "OSC", midi = "MIDI", dmx = "DMX" }
-- MA3 has no checked way to send these yet: MSC from a command, or a DMX
-- pulse to a channel without taking it from the console's own output.
local UNSUPPORTED = { msc = "MIDI Show Control", dmxPulse = "DMX pulse" }

local function trim(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end

-- "hh:mm:ss:ff" (";" or "." also allowed before any field, as in the app),
-- normalised to two digits a field so timecodes compare as strings. Frames up
-- to 29, as the app accepts when it knows no frame rate.
local function parseTimecode(text)
    local fields = {}
    for field in (trim(text) .. ":"):gmatch("([^:;.]*)[:;.]") do fields[#fields + 1] = field end
    if #fields ~= 4 then return nil end
    for i, field in ipairs(fields) do
        if not field:match("^%d%d?$") then return nil end
        fields[i] = tonumber(field)
    end
    local h, m, s, f = table.unpack(fields)
    if h > 23 or m > 59 or s > 59 or f > 29 then return nil end
    return ("%02d:%02d:%02d:%02d"):format(h, m, s, f)
end

-- The frame after `timecode`: where the Playhead has played on past a Song's
-- end, which is when the app sends its Stop Actions.
local function nextFrame(timecode, rate)
    local h, m, s, f = timecode:match("(%d+):(%d+):(%d+):(%d+)")
    h, m, s, f = tonumber(h), tonumber(m), tonumber(s), tonumber(f) + 1
    if f >= FRAMES[rate] then f, s = 0, s + 1 end
    if s > 59 then s, m = 0, m + 1 end
    if m > 59 then m, h = 0, (h + 1) % 24 end
    -- Drop-frame skips frames 0 and 1 at each minute except every tenth.
    if rate == "29.97 DF" and s == 0 and f < 2 and m % 10 ~= 0 then f = 2 end
    return ("%02d:%02d:%02d:%02d"):format(h, m, s, f)
end

-- Builds the plan from Songs, each { name, where, hasSpan, start, ["end"],
-- startNote, stopNote, startActions, stopActions }, whose Actions carry their
-- resolved Destination (or nil if missing). Same rules for both inputs.
local function build(songs, destinations, frameRate, warnings)
    local events, accepted = {}, {}
    local function warn(where, reason) warnings[#warnings + 1] = where .. ": " .. reason end

    for _, song in ipairs(songs) do
        local conflict
        if song.hasSpan and song.start <= song["end"] then
            for _, other in ipairs(accepted) do
                if song.start <= other["end"] and other.start <= song["end"] then conflict = other break end
            end
        end
        if not song.hasSpan then
            local notes = song.startNote and song.stopNote and "a Start Note and a Stop Note"
                or song.startNote and "a Start Note" or song.stopNote and "a Stop Note" or "no trigger"
            warn(song.where, ("skipped: it has %s and no timecode span, so it can't become timecode events"):format(notes))
        elseif song.start > song["end"] then
            warn(song.where, "skipped: end is before start")
        elseif conflict then
            warn(song.where, ('overlaps "%s"'):format(conflict.name))
        else
            accepted[#accepted + 1] = song
            for _, time in ipairs({ song.start, song["end"] }) do
                local frames = tonumber(time:sub(-2))
                if frames >= FRAMES[frameRate] then
                    warn(song.where, ("%s has frame %d, past the last frame at %s fps"):format(time, frames, frameRate))
                end
            end
            for _, phase in ipairs({ "start", "stop" }) do
                local time = phase == "start" and song.start or nextFrame(song["end"], frameRate)
                for _, action in ipairs(song[phase .. "Actions"]) do
                    local destination, transport = action.destination, TRANSPORT[action.type]
                    local command, release
                    if not destination then
                        command, release = nil, "an Action sends to a Destination that isn't in the Set; left out"
                    elseif not destination.uses[transport] then
                        command, release = nil, ('Destination "%s" has %s switched off; Action left out')
                            :format(destination.name, TRANSPORT_NAME[transport])
                    elseif UNSUPPORTED[action.type] then
                        command, release = nil, UNSUPPORTED[action.type] .. " Actions aren't supported by the MA3 plugin yet; left out"
                    else
                        command, release = commands[action.type](action[action.type])
                    end
                    if command then
                        local key = transport == "osc" and "osc_line_for" or transport .. "_for"
                        events[#events + 1] = {
                            time = time, song = song.name, phase = phase,
                            destination = { [key] = destination.name },
                            command = command, release = release,
                        }
                    else
                        warn(action.where or song.where, release)
                    end
                end
            end
        end
    end

    -- Timecode order; Actions keep their list order within one time.
    for i, event in ipairs(events) do event.order = i end
    table.sort(events, function(a, b) return a.time < b.time or a.time == b.time and a.order < b.order end)
    for _, event in ipairs(events) do event.order = nil end

    local list = {}
    for _, destination in ipairs(destinations) do
        local kinds = {}
        for _, transport in ipairs({ "osc", "midi", "dmx" }) do
            if destination.uses[transport] then kinds[#kinds + 1] = transport end
        end
        list[#list + 1] = {
            name = destination.name, kind = table.concat(kinds, "+"),
            host = destination.host, port = destination.port, midiPort = destination.midiPort,
        }
    end
    return { frameRate = frameRate, destinations = list, events = events, warnings = warnings }
end

local function checkRate(options)
    local rate = options and options.frameRate or "30"
    if not FRAMES[rate] then error(('frame rate "%s" is not 24, 25, 29.97 DF or 30'):format(rate), 3) end
    return rate
end

-- MARK: .trigit

-- Reads a Set file written by SetFile.swift. Returns the plan, or nil and the
-- reason the file can't be read (worded as the Mac app words it).
function plan.fromTrigit(text, options)
    local frameRate = checkRate(options)
    local ok, file = pcall(json.decode, text)
    if not ok then return nil, "The file is not a TrigIT Set (it isn't JSON)." end
    if type(file) ~= "table" or file.format ~= "TrigIT Set" or math.type(file.version) ~= "integer" then
        return nil, "The file is JSON, but not a TrigIT Set."
    end
    if file.version > 1 then
        return nil, ("The Set was saved by a newer TrigIT (file version %d); update TrigIT to open it."):format(file.version)
    end
    if type(file.set) ~= "table" then return nil, 'The Set file is damaged: it has no "set".' end

    local built
    ok, built = pcall(function()
        local byID, destinations = {}, {}
        for _, d in ipairs(file.set.destinations or {}) do
            -- Older files: OSC on, MIDI and DMX on if their output is set (Coding.swift).
            local uses = { osc = d.usesOSC ~= false, midi = d.usesMIDI, dmx = d.usesDMX }
            if uses.midi == nil then uses.midi = d.midiOutput ~= nil end
            if uses.dmx == nil then uses.dmx = d.dmxOutput ~= nil end
            local destination = {
                name = d.name or "", uses = uses, host = d.host or "", port = d.port or 0,
                midiPort = d.midiOutput and d.midiOutput.name,
            }
            byID[d.id] = destination
            destinations[#destinations + 1] = destination
        end
        local songs = {}
        for _, s in ipairs(file.set.songs or {}) do
            local song = {
                name = s.name or "", where = ('Song "%s"'):format(s.name or ""), hasSpan = s.start ~= nil,
                startNote = s.startNote, stopNote = s.stopNote, startActions = {}, stopActions = {},
            }
            if song.hasSpan then
                song.start = parseTimecode(s.start) or error(('"%s" is not a timecode (hh:mm:ss:ff)'):format(s.start), 0)
                song["end"] = parseTimecode(s["end"] or "") or error(('"%s" is not a timecode (hh:mm:ss:ff)'):format(s["end"]), 0)
            end
            for _, phase in ipairs({ "startActions", "stopActions" }) do
                for _, a in ipairs(s[phase] or {}) do
                    local action = { type = a.type, destination = byID[a.destination] }
                    if not TRANSPORT[a.type] then error(('"%s" is not an Action type'):format(tostring(a.type)), 0) end
                    action[a.type] = a[a.type]
                    song[phase][#song[phase] + 1] = action
                end
            end
            songs[#songs + 1] = song
        end
        return build(songs, destinations, frameRate, {})
    end)
    if not ok then return nil, "The Set file is damaged: " .. tostring(built) .. "." end
    return built
end

-- MARK: CSV

-- The separator used most on the first non-empty line, outside quotes; a
-- comma on a tie.
local function detectSeparator(lines)
    for _, line in ipairs(lines) do
        if line:find("%S") then
            local counts, inQuotes = { [","] = 0, [";"] = 0, ["\t"] = 0 }, false
            for c in line:gmatch(".") do
                if c == '"' then inQuotes = not inQuotes end
                if not inQuotes and counts[c] then counts[c] = counts[c] + 1 end
            end
            local best = ","
            for _, separator in ipairs({ ";", "\t" }) do
                if counts[separator] > counts[best] then best = separator end
            end
            return best
        end
    end
    return ","
end

-- Trimmed fields; quoted fields may hold the separator, and "" is a quote.
local function splitCSV(line, separator)
    local fields, field, inQuotes, i = {}, {}, false, 1
    while i <= #line do
        local c = line:sub(i, i)
        if inQuotes then
            if c == '"' and line:sub(i + 1, i + 1) == '"' then
                field[#field + 1] = '"'
                i = i + 1
            elseif c == '"' then
                inQuotes = false
            else
                field[#field + 1] = c
            end
        elseif c == '"' then
            inQuotes = true
        elseif c == separator then
            fields[#fields + 1] = trim(table.concat(field))
            field = {}
        else
            field[#field + 1] = c
        end
        i = i + 1
    end
    fields[#fields + 1] = trim(table.concat(field))
    return fields
end

-- OSC arguments typed as text, as the app's editor reads them
-- (OSCArgument.parseList): whole numbers are ints, numbers with ".", "e" or
-- "E" are floats, anything else a string; quotes keep spaces or a number as
-- text, with \ escaping the next character. Nil for an unterminated quote.
local function parseArguments(text)
    local arguments, i = {}, 1
    while true do
        i = text:find("%S", i)
        if not i then return arguments end
        if text:sub(i, i) == '"' then
            local value, closed = {}, false
            i = i + 1
            while i <= #text do
                local c = text:sub(i, i)
                if c == "\\" and i < #text then
                    i = i + 1
                    value[#value + 1] = text:sub(i, i)
                elseif c == '"' then
                    closed = true
                    break
                else
                    value[#value + 1] = c
                end
                i = i + 1
            end
            if not closed then return nil end
            arguments[#arguments + 1] = { string = table.concat(value) }
            i = i + 1
        else
            local token = text:match("^%S+", i)
            i = i + #token
            local int, float = token:match("^[-+]?%d+$") and tonumber(token), tonumber(token)
            if int and int >= -2 ^ 31 and int < 2 ^ 31 then
                arguments[#arguments + 1] = { int = math.tointeger(int) }
            elseif token:find("[.eE]") and float and math.abs(float) <= 3.4028234663852886e38 then
                arguments[#arguments + 1] = { float = float + 0.0 }
            else
                arguments[#arguments + 1] = { string = token }
            end
        end
    end
end

local function integerIn(text, low, high)
    local value = text:match("^%d+$") and tonumber(text)
    return value and value >= low and value <= high and value or nil
end

-- The Action in columns 4-8, or nil (and a reason, if there is one wrong).
local function parseAction(columns)
    local destination, kind, target, value, phase = columns[4] or "", (columns[5] or ""):lower(),
        columns[6] or "", columns[7] or "", (columns[8] or ""):lower()
    if destination .. kind .. target .. value .. phase == "" then return nil end
    if destination == "" then return nil, "the Action has no destination" end
    if phase ~= "" and phase ~= "start" and phase ~= "stop" then
        return nil, ('when "%s" is not start or stop'):format(columns[8])
    end
    local action = { destination = destination, phase = phase == "stop" and "stop" or "start" }
    if kind == "osc" then
        -- OSC addresses start with "/" and are printable ASCII without spaces, '#' or ','.
        if not target:match("^/[\33-\126]*$") or target:find("[#,]") then
            return nil, ('"%s" is not an OSC address'):format(target)
        end
        local arguments = parseArguments(value)
        if not arguments then return nil, ('arguments "%s" have an unterminated quote'):format(value) end
        action.type, action.osc = "osc", { address = target, arguments = arguments }
    elseif kind == "midi-note" then
        local channelText, noteText = target:match("^(%d+)/(%d+)$")
        local channel = channelText and integerIn(channelText, 1, 16) or not channelText and 1
        local note = integerIn(noteText or target, 0, 127)
        if not channel or not note then return nil, ('note "%s" is not a note (60, or channel/note as 10/36)'):format(target) end
        local velocity = value == "" and 127 or integerIn(value, 1, 127)
        if not velocity then return nil, ('velocity "%s" is not 1-127'):format(value) end
        action.type, action.midiNote = "midiNote", { channel = channel - 1, note = note, velocity = velocity }
    elseif kind == "dmx" then
        local universeText, channelText = target:match("^(%d+)%.(%d+)$")
        local universe = universeText and integerIn(universeText, 0, 63999)
        local channel = channelText and integerIn(channelText, 1, 512)
        if not universe or not channel then
            return nil, ('"%s" is not universe.channel (channel 1-512)'):format(target)
        end
        local level = value == "" and 255 or integerIn(value, 0, 255)
        if not level then return nil, ('value "%s" is not 0-255'):format(value) end
        action.type, action.dmxPulse = "dmxPulse", { universe = universe, channel = channel, value = level, duration = 0.5 }
    else
        return nil, ('kind "%s" is not osc, midi-note or dmx'):format(columns[5] or "")
    end
    return action
end

-- Reads the extended CSV described in README.md. Returns the plan; rows the
-- app's importer would refuse are reported in its warnings, with line numbers.
function plan.fromCSV(text, options)
    local frameRate = checkRate(options)
    local lines = {}
    for line in (text:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local separator = detectSeparator(lines)

    local warnings, songs, destinations, byName = {}, {}, {}, {}
    local isFirstRow, current = true, nil -- current: the Song above, or false if it was refused
    local function addAction(song, columns, where)
        local action, reason = parseAction(columns)
        if not action then
            if reason then warnings[#warnings + 1] = where .. ": " .. reason end
            return
        end
        local destination = byName[action.destination]
        if not destination then
            destination = { name = action.destination, uses = {} }
            byName[action.destination] = destination
            destinations[#destinations + 1] = destination
        end
        destination.uses[TRANSPORT[action.type]] = true
        action.destination, action.where = destination, where
        local list = song[action.phase .. "Actions"]
        list[#list + 1] = action
    end

    for lineNumber, line in ipairs(lines) do
        local columns = splitCSV(line, separator)
        if table.concat(columns) ~= "" then
            local firstRow = isFirstRow
            isFirstRow = false
            local where = "line " .. lineNumber
            local function problem(reason) warnings[#warnings + 1] = where .. ": " .. reason end
            local name, startText, endText = columns[1], columns[2] or "", columns[3] or ""

            if #columns < 3 then
                problem(("needs name, start and end; found %d column%s"):format(#columns, #columns == 1 and "" or "s"))
                current = false
            elseif name == "" and startText == "" and endText == "" then
                -- Another Action for the Song above.
                if current then
                    addAction(current, columns, where)
                else
                    problem(current == nil and "no Song above to add the Action to" or "the Song above was skipped")
                end
            else
                local start, finish = parseTimecode(startText), parseTimecode(endText)
                -- A first row whose times are both not timecodes is a header.
                if not (firstRow and not start and not finish) then
                    current = false
                    if name == "" then
                        problem("the name is empty")
                    elseif not start then
                        problem(('start "%s" is not a timecode (hh:mm:ss:ff)'):format(startText))
                    elseif not finish then
                        problem(('end "%s" is not a timecode (hh:mm:ss:ff)'):format(endText))
                    elseif finish < start then
                        problem("end is before start")
                    else
                        current = {
                            name = name, where = where, hasSpan = true, start = start, ["end"] = finish,
                            startActions = {}, stopActions = {},
                        }
                        songs[#songs + 1] = current
                        addAction(current, columns, where)
                    end
                end
            end
        end
    end
    local result = build(songs, destinations, frameRate, warnings)
    -- In line order: overlaps are found after the rows are read.
    local function line(i) return tonumber(warnings[i]:match("^line (%d+)")) end
    local order = {}
    for i in ipairs(warnings) do order[i] = i end
    table.sort(order, function(a, b) return line(a) < line(b) or line(a) == line(b) and a < b end)
    for i, index in ipairs(order) do order[i] = warnings[index] end
    result.warnings = order
    return result
end

return plan
