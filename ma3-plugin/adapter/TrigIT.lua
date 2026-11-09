-- SPDX-License-Identifier: GPL-3.0-or-later
-- The grandMA3 side of the plugin: pick a Set file, choose where things go,
-- and write a Timecode Show that fires the Set's Actions. Everything that
-- touches MA lives here; the rules are in trigit_plan.lua and ma3.lua.
--
-- What it writes, all marked with MARK in their Note so a re-import finds
-- and replaces them:
--   Sequence <n>  one cue per moment; each cue's Command sends that moment's
--                 Actions (SendOSC / SendMIDI).
--   Timecode <n>  one track playing that sequence, with a Goto event per cue
--                 at its time, following the chosen timecode slot.
--   OSC lines     "TrigIT <Destination>" in In & Out, made when asked.

local trigitPlan = require("trigit_plan")
local ma3 = require("ma3")

local MARK = "Made by the TrigIT plugin. Importing a Set again replaces it."
local RATES = { "24", "25", "29.97 DF", "30" }
local READOUT = { ["24"] = "24 fps", ["25"] = "25 fps", ["29.97 DF"] = "30 fps", ["30"] = "30 fps" }
local GOTO = 16 -- the Goto token of a timecode event

local function settle() coroutine.yield(0.05) end -- lets MA create child objects
local function plainName(text) return (text:gsub('"', "'")) end -- safe inside a command's quotes

local function plural(n, word) return ("%d %s%s"):format(n, word, n == 1 and "" or "s") end

local function say(title, text)
    MessageBox({ title = "TrigIT: " .. title, message = text, commands = { { value = 1, name = "OK" } } })
end

-- Ours if its Note starts with MARK. The Timecode's Note also keeps the frame rate.
local function owned(object)
    return object ~= nil and tostring(object:Get("Note") or ""):sub(1, #MARK) == MARK
end

-- MARK: Choosing the file

-- Set files (.trigit or .csv) in the library's trigit folder, the library
-- itself, and the top or trigit folder of each USB drive.
local function setFiles()
    local library = GetPath(Enums.PathType.Library)
    local folders = { { library .. "/trigit", "Library/trigit" }, { library, "Library" } }
    for _, drive in ipairs(Root().Temp.DriveCollect:Children()) do
        local kind = tostring(drive.DriveType)
        if kind ~= "Internal" and kind ~= "OldVersion" then
            folders[#folders + 1] = { drive.Path, drive.name }
            folders[#folders + 1] = { drive.Path .. "/trigit", drive.name .. "/trigit" }
        end
    end
    local files = {}
    for _, folder in ipairs(folders) do
        local ok, entries = pcall(DirList, folder[1], "*")
        for _, entry in ipairs(ok and entries or {}) do
            local name = entry.name or ""
            local lower = name:lower()
            if lower:match("%.trigit$") or lower:match("%.csv$") then
                files[#files + 1] = { label = name .. "  (" .. folder[2] .. ")", path = folder[1] .. "/" .. name, name = name }
            end
        end
    end
    return files, library .. "/trigit"
end

local function chooseFile()
    local files, folder = setFiles()
    if #files == 0 then
        say("no Set files", "No .trigit or .csv files were found.\n\nPut the Set in\n" .. folder
            .. "\nor on a USB stick (at the top or in a folder named trigit), then run the plugin again.")
        return nil
    end
    local labels = {}
    for i, file in ipairs(files) do labels[i] = file.label end
    local _, label = PopupInput({ title = "TrigIT Set", caller = GetFocusDisplay(), items = labels })
    for _, file in ipairs(files) do
        if file.label == label then return file end
    end
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("a")
    file:close()
    return text
end

-- MARK: Where things go

local function firstFree(pool, from)
    local n = from
    while pool[n] do n = n + 1 end
    return n
end

-- The Timecode and Sequence an earlier import made, if any.
local function previous()
    for _, tc in ipairs(DataPool().Timecodes:Children()) do
        if owned(tc) then
            local target = tc[1] and tc[1][2] and tc[1][2].Target
            return tc, (target and owned(target)) and target or nil
        end
    end
end

local function chooseOptions(setName, eventCount)
    local tc, seq = previous()
    local defaults = {
        timecode = tc and tc.no or firstFree(DataPool().Timecodes, 1),
        sequence = seq and seq.no or firstFree(DataPool().Sequences, 101),
        slot = tc and tonumber(tostring(tc.TCSlot)) or 1,
        rate = tc and tostring(tc:Get("Note")):match("Frame rate: (.+)$") or "30",
    }
    local slots = {}
    for n = 1, 16 do slots["Slot " .. n] = n end
    local rates = {}
    for i, rate in ipairs(RATES) do rates[rate] = i end
    local preset
    for i, rate in ipairs(RATES) do if rate == defaults.rate then preset = i end end

    while true do
        local reply = MessageBox({
            title = "TrigIT: import " .. setName,
            message = ("%s. Choose the frame rate of the show's timecode, "
                .. "the slot it arrives on, and where the Timecode Show and its Sequence go.%s"):format(
                plural(eventCount, "timecode event"), tc and ("\n\nTimecode %d%s from the last import will be replaced, if you keep the numbers.")
                    :format(tc.no, seq and (" and Sequence " .. seq.no) or "") or ""),
            commands = { { value = 1, name = "Next" }, { value = 0, name = "Cancel" } },
            inputs = {
                { name = "Timecode", value = tostring(defaults.timecode), whiteFilter = "0123456789", vkPlugin = "TextInputNumOnly" },
                { name = "Sequence", value = tostring(defaults.sequence), whiteFilter = "0123456789", vkPlugin = "TextInputNumOnly" },
            },
            selectors = {
                { name = "Frame rate", type = 1, values = rates, selectedValue = preset or 4 },
                { name = "Timecode slot", type = 0, values = slots, selectedValue = defaults.slot },
            },
        })
        if reply.result ~= 1 then return nil end
        local options = {
            timecode = tonumber(reply.inputs.Timecode), sequence = tonumber(reply.inputs.Sequence),
            rate = RATES[reply.selectors["Frame rate"]], slot = reply.selectors["Timecode slot"],
        }
        local problem
        local existingTC = options.timecode and DataPool().Timecodes[options.timecode]
        local existingSeq = options.sequence and DataPool().Sequences[options.sequence]
        if not options.timecode or options.timecode < 1 then
            problem = "Enter a Timecode number."
        elseif not options.sequence or options.sequence < 1 then
            problem = "Enter a Sequence number."
        elseif existingTC and not owned(existingTC) then
            problem = ('Timecode %d "%s" is already used, and not by TrigIT. Choose a free number.'):format(options.timecode, existingTC.name)
        elseif existingSeq and not owned(existingSeq) then
            problem = ('Sequence %d "%s" is already used, and not by TrigIT. Choose a free number.'):format(options.sequence, existingSeq.name)
        end
        if not problem then return options end
        say("choose again", problem) -- then ask again, with the free numbers suggested
    end
end

-- MARK: Destinations

local function oscLines() return Root().ShowData.OSCBase end

local function lineLabel(line)
    return ("%d: %s  (%s:%s)"):format(line.no, line.name, tostring(line.DestinationIP), tostring(line.Port))
end

-- Asks which In & Out OSC line each OSC Destination uses. Changes nothing
-- yet: returns { [name] = line number, or { ip, port } for a new line } and
-- notes for the summary, or nil if cancelled.
local function mapDestinations(plan)
    local usedOSC, usedMIDI = {}, {}
    for _, event in ipairs(plan.events) do
        if event.destination.osc_line_for then usedOSC[event.destination.osc_line_for] = true end
        if event.destination.midi_for then usedMIDI[event.destination.midi_for] = true end
    end
    local lines, notes = {}, {}
    for _, destination in ipairs(plan.destinations) do
        if usedOSC[destination.name] then
            local values, guess = { ["New OSC line"] = 0 }, 0
            for _, line in ipairs(oscLines():Children()) do
                values[lineLabel(line)] = line.no
                local sameAddress = tostring(line.DestinationIP) == (destination.host or "") and tonumber(line.Port) == destination.port
                if line.name == "TrigIT " .. destination.name or (sameAddress and guess == 0) then guess = line.no end
            end
            local address = destination.host and destination.host ~= ""
                and ("%s:%d"):format(destination.host, destination.port) or "no address in the Set"
            local reply = MessageBox({
                title = "TrigIT: OSC to " .. destination.name,
                message = ('Which In & Out OSC line sends to "%s" (%s)?\n\nA new line uses the IP address and port below.')
                    :format(destination.name, address),
                commands = { { value = 1, name = "Use" }, { value = 2, name = "Leave out" }, { value = 0, name = "Cancel" } },
                inputs = {
                    { name = "IP address", value = destination.host or "", whiteFilter = "0123456789." },
                    { name = "Port", value = tostring(destination.port or 8000), whiteFilter = "0123456789", vkPlugin = "TextInputNumOnly" },
                },
                selectors = { { name = "OSC line", type = 0, values = values, selectedValue = guess } },
            })
            if reply.result == 0 then return nil end
            if reply.result == 2 then
                notes[#notes + 1] = ('OSC to "%s" is left out.'):format(destination.name)
            else
                local number = reply.selectors["OSC line"]
                if number == 0 then
                    local ip, port = reply.inputs["IP address"], tonumber(reply.inputs.Port)
                    if not ip:match("^%d+%.%d+%.%d+%.%d+$") or not port or port < 1 or port > 65535 then
                        say("address needed", ('"%s" needs an IP address and a port 1-65535 for its new OSC line. Import again to retry.'):format(destination.name))
                        return nil
                    end
                    lines[destination.name] = { ip = ip, port = port }
                    notes[#notes + 1] = ('A new OSC line "TrigIT %s" will send to %s:%d.'):format(destination.name, ip, port)
                else
                    lines[destination.name] = number
                    if not oscLines()[number].SendCommand then
                        notes[#notes + 1] = ("Send Command will be switched on for OSC line %d: SendOSC needs it."):format(number)
                    end
                end
            end
        end
    end
    if next(lines) then
        if not oscLines().EnableOutput then notes[#notes + 1] = "OSC Enable Output will be switched on." end
        if tostring(oscLines().Interface) == "0.0" then
            notes[#notes + 1] = "OSC has no interface yet: choose one in Menu > In & Out > OSC > Interface, or nothing is sent."
        end
    end
    for _, destination in ipairs(plan.destinations) do
        if usedMIDI[destination.name] then
            notes[#notes + 1] = ('MIDI to "%s" goes out of this station\'s MIDI output.'):format(destination.name)
        end
    end
    return lines, notes
end

-- Makes the new OSC lines and switches on what SendOSC needs. Returns
-- { [name] = line number }.
local function setUpLines(choices)
    local numbers = {}
    for name, choice in pairs(choices) do
        local line
        if type(choice) == "table" then
            line = oscLines():Append()
            settle()
            line.Name = "TrigIT " .. name
            line.DestinationIP, line.Port, line.Mode = choice.ip, choice.port, false
            -- Send off, so MA's own playback feedback doesn't go to the device.
            line.Send = false
        else
            line = oscLines()[choice]
        end
        line.SendCommand = true
        numbers[name] = line.no
    end
    if next(numbers) then oscLines().EnableOutput = true end
    return numbers
end

-- MARK: Writing the show

local function write(options, cues, setName, progress)
    local name = plainName("TrigIT " .. setName)
    if DataPool().Timecodes[options.timecode] then Cmd(("Delete Timecode %d /NoConfirm"):format(options.timecode)) end
    if DataPool().Sequences[options.sequence] then Cmd(("Delete Sequence %d /NoConfirm"):format(options.sequence)) end
    settle()

    -- The sequence: Store makes it with Cue 1; the rest are appended.
    Cmd(('Store Sequence %d "%s"'):format(options.sequence, name))
    settle()
    local seq = DataPool().Sequences[options.sequence]
    seq:Set("Note", MARK)
    local cueHandles = {}
    for i, cue in ipairs(cues) do
        local handle
        if i == 1 then
            for _, child in ipairs(seq:Children()) do if child.no == 1000 then handle = child end end
        else
            handle = seq:Append()
            settle()
            handle:Set("No", tostring(i))
        end
        handle[1].Command = cue.command
        Cmd(('Label Sequence %d Cue %d "%s"'):format(options.sequence, i, plainName(cue.name)))
        cueHandles[i] = handle
        IncProgress(progress, 1)
    end

    -- The Timecode Show: one track playing the sequence, a Goto per cue.
    Cmd(('Store Timecode %d "%s"'):format(options.timecode, name))
    settle()
    local tc = DataPool().Timecodes[options.timecode]
    tc:Set("Note", MARK .. "\nFrame rate: " .. options.rate)
    tc.TCSlot = options.slot
    -- Follow the slot by itself: start when timecode arrives, stop when it stops.
    tc.AutoStart, tc.AutoStop = true, true
    tc.FrameReadout = READOUT[options.rate]
    local group = tc:Append()
    settle()
    local track = group[2]
    track.Target = seq
    settle()
    local events = track[1]:Append("CmdSubTrack")
    settle()
    for i, cue in ipairs(cues) do
        local event = events:Append()
        settle()
        event.Time = cue.seconds
        event.Token = GOTO
        event.CueDestination = cueHandles[i]
        IncProgress(progress, 1)
    end
    return tc, seq
end

-- MARK: Main

local function summary(plan, cues, options, notes, setName)
    local lines = {
        ("Timecode %d and Sequence %d will hold %s from %s, at %s fps on timecode slot %d.")
            :format(options.timecode, options.sequence, plural(#cues, "cue"), setName, options.rate, options.slot),
    }
    for _, note in ipairs(notes) do lines[#lines + 1] = note end
    if #plan.warnings > 0 then
        lines[#lines + 1] = "\n" .. plural(#plan.warnings, "warning") .. ":"
        for i, warning in ipairs(plan.warnings) do
            if i > 12 then
                lines[#lines + 1] = ("... and %d more, listed in the System Monitor."):format(#plan.warnings - 12)
                break
            end
            lines[#lines + 1] = warning
        end
    end
    return table.concat(lines, "\n")
end

local function main()
    local file = chooseFile()
    if not file then return end
    local text = readFile(file.path)
    if not text then
        say("can't read", "Could not read " .. file.path)
        return
    end
    local setName = file.name:gsub("%.[^.]+$", "")

    -- The frame rate decides when Stop Actions fire, so plan once to count
    -- events, then again at the chosen rate.
    local isCSV = file.name:lower():match("%.csv$")
    local function makePlan(rate)
        if isCSV then return trigitPlan.fromCSV(text, { frameRate = rate }) end
        return trigitPlan.fromTrigit(text, { frameRate = rate })
    end
    local first, reason = makePlan("30")
    if not first then
        say("can't import", file.name .. "\n\n" .. reason)
        return
    end
    if #first.events == 0 then
        say("nothing to import", file.name .. " has no Actions the MA3 can send at a timecode."
            .. (#first.warnings > 0 and ("\n\n" .. table.concat(first.warnings, "\n")) or ""))
        return
    end

    local options = chooseOptions(setName, #first.events)
    if not options then return end
    local plan = makePlan(options.rate)
    local choices, notes = mapDestinations(plan)
    if not choices then return end
    local placeholders = {}
    for name in pairs(choices) do placeholders[name] = 0 end
    local cues = ma3.cues(plan, placeholders)
    if #cues == 0 then
        say("nothing to import", "Every Action was left out, so there is nothing to write.")
        return
    end

    for _, warning in ipairs(plan.warnings) do Printf("TrigIT: " .. warning) end
    local reply = MessageBox({
        title = "TrigIT: ready to import " .. setName,
        message = summary(plan, cues, options, notes, setName),
        commands = { { value = 1, name = "Import" }, { value = 0, name = "Cancel" } },
    })
    if reply.result ~= 1 then return end

    local progress = StartProgress("TrigIT: importing " .. setName)
    SetProgressRange(progress, 0, 2 * #cues)
    local ok, problem = pcall(function()
        write(options, ma3.cues(plan, setUpLines(choices)), setName, progress)
    end)
    StopProgress(progress)
    if not ok then
        ErrPrintf("TrigIT: " .. tostring(problem))
        say("import failed", "Writing the Timecode Show failed:\n" .. tostring(problem)
            .. "\n\nUse Oops to undo anything half written.")
        return
    end
    say("imported", ("%s is in Timecode %d and Sequence %d.\n\nTimecode %d starts by itself when timecode arrives on "
        .. "slot %d, and each cue sends its Actions at its time."):format(setName, options.timecode, options.sequence,
        options.timecode, options.slot))
end

return main
