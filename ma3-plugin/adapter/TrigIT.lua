-- SPDX-License-Identifier: GPL-3.0-or-later
-- The grandMA3 side of the plugin, everything that touches MA. Running it
-- opens the TrigIT panel, which follows a timecode slot in one of two modes
-- (docs/adr/0003-ma3-plugin-modes.md):
--   Standalone  the Show Engine (live.lua) sends the Set's Actions while Armed.
--   Bridge      the slot goes to the TrigIT Mac app as Art-Net Timecode, and
--               the Mac app fires.
-- It can also import the Set as a Timecode Show that fires the Actions without
-- the plugin running. The rules are in src/.

local pluginName, componentName, signalTable, myHandle = ...

-- What an import writes, all marked with MARK in their Note so a re-import
-- finds and replaces them:
--   Sequence <n>  one cue per moment; each cue's Command sends that moment's
--                 Actions (SendOSC / SendMIDI).
--   Timecode <n>  one track playing that sequence, with a Goto event per cue
--                 at its time, following the chosen timecode slot.
--   OSC lines     "TrigIT <Destination>" in In & Out, made when asked.

local trigitPlan = require("trigit_plan")
local ma3 = require("ma3")
local live = require("live")
local timecode = require("timecode")
local artnet = require("artnet")
local arguments = require("arguments")
local view = require("view")
local setedit = require("setedit")

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

local function chooseOptions(setName, eventCount, follow)
    local tc, seq = previous()
    local defaults = {
        timecode = tc and tc.no or firstFree(DataPool().Timecodes, 1),
        sequence = seq and seq.no or firstFree(DataPool().Sequences, 101),
        slot = follow.slot,
        rate = follow.rate,
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

-- Writes the Set in `file` ({ name, path }) as `text` into a Timecode Show.
local function import(file, text, follow)
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

    local options = chooseOptions(setName, #first.events, follow)
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

-- MARK: The panel

local SLOT_UNITS = 16777216 -- a timecode slot's Time counts 1/16777216 s
local PANEL = "TrigITPanel"
local RED = "Global.AlertText"

-- Kept in the show's global variables, so the panel opens as it was left.
local function setting(name) return (GetVar(GlobalVars(), "TrigIT" .. name)) end
local function remember(name, value) SetVar(GlobalVars(), "TrigIT" .. name, value) end

-- The In & Out OSC line for a Set Destination: the one named "TrigIT <name>"
-- (an import makes it), else the first that sends to its address.
local function lineFor(destination)
    local byAddress
    for _, line in ipairs(oscLines():Children()) do
        if line.name == "TrigIT " .. destination.name then return line.no end
        if not byAddress and tostring(line.DestinationIP) == destination.host and tonumber(line.Port) == destination.port then
            byAddress = line.no
        end
    end
    return byAddress
end

local state = { pending = nil, notice = "", lastTime = {} }

local function follow()
    state.lastTime, state.lastMove = {}, nil
    state.show = state.set and live.new(state.set, state.rate, lineFor, false)
end

-- An earlier import's Timecode Show fires the same Actions on its own.
local function checkTwice()
    local tc = previous()
    state.twice = tc and tc.AutoStart and tonumber(tostring(tc.TCSlot)) == state.slot
        and ("Timecode %d also fires these Actions on slot %d: disarm here, or switch off its AutoStart"):format(tc.no, state.slot)
end

local function load(file, quietly)
    local text = readFile(file.path)
    if not text then
        if not quietly then say("can't read", "Could not read " .. file.path) end
        return
    end
    local set
    if file.name:lower():match("%.csv$") then
        state.notice = "A CSV Set can be imported to a Timecode Show. To follow it here, open it in TrigIT on the Mac and save it as a .trigit file."
    else
        local reason
        set, reason = trigitPlan.readSet(text)
        if not set then
            if not quietly then say("can't load", file.name .. "\n\n" .. reason) end
            return
        end
        state.notice = ""
    end
    state.file, state.text, state.set = file, text, set
    remember("SetPath", file.path)
    remember("SetName", file.name)
    follow()
end

local function songNamed(label)
    for _, song in ipairs(state.set and state.set.songs or {}) do
        if song.name == label then return song end
    end
end

local function chooseSong(title)
    local names = {}
    for _, song in ipairs(state.set and state.set.songs or {}) do names[#names + 1] = song.name end
    if #names == 0 then return nil end
    local _, label = PopupInput({ title = title, caller = GetFocusDisplay(), items = names })
    return songNamed(label)
end

-- What the buttons do, run from the panel's loop so dialogs can wait.
local actions = {}

function actions.load()
    local file = chooseFile()
    if file then load(file) end
end

-- MARK: The Set editor (#96)

-- Every edit is saved at once, and the running show takes it without firing
-- anything (Engine:updateSet), Armed or not, as in the Mac app.
local function changed()
    local file = io.open(state.file.path, "wb")
    if not file then
        say("can't save", "Could not write " .. state.file.path .. ". The change is kept until TrigIT stops.")
    else
        file:write(setedit.encode(state.set))
        file:close()
    end
    if state.show then state.show:updateSet(state.set) else follow() end
end

-- Show Lock, as in the Mac app: the Set is read-only; arming and firing still work.
local function editable()
    if state.locked then
        say("Show Lock is on", "The Set is read-only during the show. Turn Show Lock off (Set > Show Lock) to edit.")
        return false
    end
    if not state.set then
        say("nothing to edit", "Load a .trigit Set, or make a New Set. A CSV Set can only be imported.")
        return false
    end
    return true
end

local function playhead() return state.show and state.show.engine.playhead end

-- A dialog that keeps what was typed when it reopens, as MessageBox can't
-- change itself: `fields` {name, value}, `commands` {value, name}.
local function ask(title, message, fields, commands, selectors)
    -- MessageBox lists inputs by name; leading spaces sort first, so they keep this order.
    local inputs = {}
    for i, field in ipairs(fields) do
        inputs[i] = { name = (" "):rep(#fields - i) .. field[1], value = field[2], whiteFilter = field[3] }
    end
    local reply = MessageBox({ title = "TrigIT: " .. title, message = message, commands = commands, inputs = inputs, selectors = selectors })
    for i, field in ipairs(fields) do field[2] = reply.inputs[inputs[i].name] or field[2] end
    return reply.result, reply.selectors
end

local function destinationDialog(name)
    local fields = { { "Name", name }, { "IP address", "", "0123456789." }, { "Port", "7000", "0123456789" } }
    while true do
        local result = ask("new Destination", 'Where OSC Actions to "' .. name .. '" go. MIDI Actions go out of the console\'s MIDI port.',
            fields, { { value = 1, name = "Add" }, { value = 0, name = "Cancel" } })
        if result ~= 1 then return nil end
        local destination, why = setedit.putDestination(state.set, fields[1][2], fields[2][2], fields[3][2])
        if destination then return destination end
        say("can't add the Destination", why)
    end
end

local KINDS = { "osc", "midi-note", "dmx" }

-- Makes sure the Destination typed exists, asking for its address if new.
local function destinationFor(name)
    if setedit.destinationNamed(state.set, name) or not name:find("%S") then return true end
    return destinationDialog(name) ~= nil
end

local function presetDialog(songID, preset)
    local first = state.set.destinations[1]
    local fields = { { "Destination", first and first.name or "" } }
    for _, field in ipairs(preset.fields) do fields[#fields + 1] = { field, "" } end
    local when = 1
    while true do
        local result, selectors = ask(preset.label,
            preset.command and "Needs Receive Command on that console's OSC line. If the line has a prefix, edit the address later."
                or "Sends int 1, as Resolume expects.",
            fields, { { value = 1, name = "Add" }, { value = 0, name = "Cancel" } },
            { { name = "When", type = 1, values = { Start = 1, Stop = 2 }, selectedValue = when } })
        if result ~= 1 then return end
        when = selectors.When or when
        local values = {}
        for i = 2, #fields do values[#values + 1] = fields[i][2] end
        local address, arguments = setedit.preset(preset, values)
        if not address then
            say("can't add the Action", arguments)
        elseif destinationFor(fields[1][2]) then
            local action, why = setedit.addAction(state.set, songID, fields[1][2], "osc", address, arguments,
                when == 2 and "stop" or "start")
            if action then return changed() end
            say("can't add the Action", why)
        else
            return
        end
    end
end

local function addActionDialog(songID)
    local items = {}
    for i, preset in ipairs(setedit.PRESETS) do items[i] = preset.label end
    items[#items + 1] = "OSC, MIDI note or DMX: type it..."
    local _, label = PopupInput({ title = "Add Action", caller = GetFocusDisplay(), items = items })
    for _, preset in ipairs(setedit.PRESETS) do
        if preset.label == label then return presetDialog(songID, preset) end
    end
    if label ~= items[#items] then return end
    local first = state.set.destinations[1]
    local fields = { { "Destination", first and first.name or "" }, { "Address, note or universe.channel", "" },
        { "Arguments, velocity or value", "" } }
    local kind, when = 1, 1
    while true do
        local result, selectors = ask("add Action",
            "OSC: an address such as /composition/columns/1/connect, and arguments such as 1 or \"text\".\n"
            .. "MIDI note: 60, or channel/note such as 10/36, and a velocity (127 if empty).\n"
            .. "DMX pulse: universe.channel such as 1.1, and a value (255 if empty). The Mac app sends it; the console can't yet.",
            fields, { { value = 1, name = "Add" }, { value = 0, name = "Cancel" } },
            { { name = "Kind", type = 1, values = { OSC = 1, ["MIDI note"] = 2, DMX = 3 }, selectedValue = kind },
              { name = "When", type = 1, values = { Start = 1, Stop = 2 }, selectedValue = when } })
        if result ~= 1 then return end
        kind, when = selectors.Kind or kind, selectors.When or when
        if not destinationFor(fields[1][2]) then return end
        local action, why = setedit.addAction(state.set, songID, fields[1][2], KINDS[kind], fields[2][2], fields[3][2],
            when == 2 and "stop" or "start")
        if action then return changed() end
        say("can't add the Action", why)
    end
end

local function actionsDialog(songID)
    while true do
        local song = setedit.song(state.set, songID)
        if not song then return end
        local items, byLabel = { "Add Action..." }, {}
        for _, phase in ipairs({ "start", "stop" }) do
            for _, action in ipairs(song[phase .. "Actions"] or {}) do
                local label = ("%d. %s"):format(#items, setedit.describe(state.set, action, phase))
                items[#items + 1], byLabel[label] = label, action
            end
        end
        local _, label = PopupInput({ title = song.name .. ": tap an Action to remove it", caller = GetFocusDisplay(), items = items })
        if label == "Add Action..." then
            addActionDialog(songID)
        elseif byLabel[label] then
            local reply = MessageBox({ title = "TrigIT: remove Action", message = label:gsub("^%d+%. ", "") .. "\n\nRemove it?",
                commands = { { value = 1, name = "Remove" }, { value = 0, name = "Cancel" } } })
            if reply.result == 1 then
                setedit.removeAction(state.set, songID, byLabel[label].id)
                changed()
            end
        else
            return
        end
    end
end

-- Adds a Song (id nil) or edits one. Start and End can be typed, or taken
-- from the Playhead while the show's timecode plays.
local function songDialog(id)
    local song = id and setedit.song(state.set, id)
    local fields = { { "Name", song and song.name or "" }, { "Start", song and song.start or playhead() or "", "0123456789:" },
        { "End", song and song["end"] or "", "0123456789:" } }
    while true do
        local commands = { { value = 1, name = "Save" }, { value = 2, name = "Start = Playhead" }, { value = 3, name = "End = Playhead" } }
        if id then
            commands[#commands + 1] = { value = 4, name = "Actions" }
            commands[#commands + 1] = { value = 5, name = "Delete" }
        end
        commands[#commands + 1] = { value = 0, name = "Cancel" }
        local result = ask(id and "edit Song" or "add Song",
            "Start and End as hh:mm:ss:ff. Start = Playhead and End = Playhead take the timecode on the slot now ("
            .. (playhead() or "none yet") .. "). No two Songs may share a frame.", fields, commands)
        if result == 0 then return end
        if result == 2 or result == 3 then
            if playhead() then fields[result][2] = playhead() else say("no timecode", "No timecode has arrived on the slot yet.") end
        elseif result == 1 or result == 4 then
            local saved, why = setedit.putSong(state.set, id, fields[1][2], fields[2][2], fields[3][2])
            if not saved then
                say("can't save the Song", why)
            else
                changed()
                id = saved.id
                if result == 1 then return end
                actionsDialog(id)
            end
        elseif result == 5 then
            local reply = MessageBox({ title = "TrigIT: delete Song", message = ('Delete "%s" and its Actions?'):format(fields[1][2]),
                commands = { { value = 1, name = "Delete" }, { value = 0, name = "Cancel" } } })
            if reply.result == 1 then
                setedit.deleteSong(state.set, id)
                return changed()
            end
        end
    end
end

local function newSet()
    local fields = { { "Name", "" } }
    if ask("New Set", "A new, empty Set, saved in the library's trigit folder. Then add Songs.", fields,
        { { value = 1, name = "Make" }, { value = 0, name = "Cancel" } }) ~= 1 then return end
    local set = setedit.newSet(fields[1][2])
    local folder = GetPath(Enums.PathType.Library) .. "/trigit"
    CreateDirectoryRecursive(folder)
    local base = set.name:gsub('[/\\:*?"<>|]', "-")
    local name, n = base .. ".trigit", 1
    while readFile(folder .. "/" .. name) do n = n + 1; name = ("%s %d.trigit"):format(base, n) end
    state.file, state.text, state.set, state.notice = { path = folder .. "/" .. name, name = name }, nil, set, ""
    remember("SetPath", state.file.path)
    remember("SetName", name)
    follow()
    changed()
end

function actions.set()
    local items = { "Load Set...", "New Set...", "Add Song...", state.locked and "Show Lock: turn off" or "Show Lock: turn on" }
    local _, label = PopupInput({ title = "TrigIT Set", caller = GetFocusDisplay(), items = items })
    if label == items[1] then return actions.load() end
    if label == items[2] then
        if state.locked then return editable() end
        return newSet()
    end
    if label == items[3] then return editable() and songDialog(nil) end
    if label == items[4] then
        state.locked = not state.locked
        remember("ShowLock", state.locked and "Yes" or "No")
    end
end

-- One dialog for how TrigIT follows timecode and who fires (#97).
function actions.settings()
    local slots, backups, rates = {}, { None = 0 }, {}
    for n = 1, #Root().TimecodeSlots:Children() do slots["Slot " .. n], backups["Slot " .. n] = n, n end
    for i, rate in ipairs(RATES) do rates[rate] = i end
    local preset = 4
    for i, rate in ipairs(RATES) do if rate == state.rate then preset = i end end
    local reply = MessageBox({
        title = "TrigIT: settings",
        message = "Timecode slot: where the show's timecode arrives.\n"
            .. "Backup slot: a second slot with the same timecode, or None. TrigIT follows it if the first stops.\n"
            .. "Frame rate: the incoming timecode's. MA reads it but doesn't pass it on to plugins, "
            .. "and TrigIT needs it to place each Song's end to the frame.\n\n"
            .. "Standalone: this console sends the Set's Actions while Armed.\n"
            .. "Bridge: this console sends the slot to the TrigIT Mac app as Art-Net Timecode, and the Mac app fires. "
            .. "Choose Art-Net Timecode as its Timecode Source, and enter that computer's IP address "
            .. "(or a broadcast address such as 192.168.1.255).\n\n"
            .. "Changing any of these disarms TrigIT.",
        commands = { { value = 1, name = "OK" }, { value = 0, name = "Cancel" } },
        inputs = { { name = "Bridge computer IP", value = state.bridgeTo or "", whiteFilter = "0123456789." } },
        selectors = {
            { name = "Timecode slot", type = 0, values = slots, selectedValue = state.slot },
            { name = "Backup slot", type = 0, values = backups, selectedValue = state.backup or 0 },
            { name = "Frame rate", type = 1, values = rates, selectedValue = preset },
            { name = "Mode", type = 1, values = { Standalone = 1, Bridge = 2 }, selectedValue = state.mode == "Bridge" and 2 or 1 },
        },
    })
    if reply.result ~= 1 then return end
    local mode, ip = reply.selectors.Mode == 2 and "Bridge" or "Standalone", reply.inputs["Bridge computer IP"]
    if mode == "Bridge" and not ip:match("^%d+%.%d+%.%d+%.%d+$") then
        say("address needed", "Bridge mode needs the bridge computer's IP address, such as 192.168.1.20.")
        return
    end
    local slot, rate = reply.selectors["Timecode slot"], RATES[reply.selectors["Frame rate"]]
    local backup = reply.selectors["Backup slot"]
    if backup == 0 or backup == slot then backup = nil end
    if slot == state.slot and backup == state.backup and rate == state.rate and mode == state.mode
        and ip == (state.bridgeTo or "") then return end
    state.slot, state.backup, state.rate, state.mode, state.bridgeTo = slot, backup, rate, mode, ip
    remember("Slot", slot)
    remember("BackupSlot", backup or 0)
    remember("Rate", rate)
    remember("Mode", mode)
    remember("BridgeTo", ip)
    follow() -- a new show, disarmed
end

local function onMac()
    if state.mode ~= "Bridge" then return false end
    if state.show then state.show:note("In bridge mode the Mac app fires: use its Show screen", true) end
    return true
end

-- Bridge mode: each new frame on the slot goes to the Mac once.
local function bridge(seconds)
    local position = timecode.fromSeconds(seconds, state.rate)
    if position == state.sent then return end
    state.sent = position
    if not state.udp then
        local ok, socket = pcall(_ENV.require, "socket")
        if not ok then
            state.bridgeProblem = "LuaSocket is not available on this station, so bridge mode can't send"
            return
        end
        state.udp = socket.udp()
        state.udp:setoption("broadcast", true)
    end
    local ok, problem = state.udp:sendto(artnet.timecode(position, state.rate), state.bridgeTo, artnet.PORT)
    state.bridgeProblem = not ok and ("Can't send to %s: %s"):format(state.bridgeTo, tostring(problem)) or nil
    if ok then state.frames = (state.frames or 0) + 1 end
end

-- A tapped Song row: send its Start or Stop Actions now, even disarmed.
function actions.song(row)
    local song = state.ui and state.ui.songRows[row] and state.ui.songRows[row].song
    if not song then return end
    local canFire = state.show and state.mode ~= "Bridge"
    local commands = {}
    if canFire then commands = { { value = 1, name = "Fire Start" }, { value = 2, name = "Fire Stop" } } end
    if not state.locked then commands[#commands + 1] = { value = 3, name = "Edit" } end
    commands[#commands + 1] = { value = 0, name = "Cancel" }
    local reply = MessageBox({
        title = "TrigIT: " .. song.name,
        message = canFire and "Send this Song's Start or Stop Actions now, even while disarmed?"
            or "In bridge mode the Mac app fires.",
        commands = commands,
    })
    if reply.result == 1 then state.show:fire(song.id, Time()) end
    if reply.result == 2 then state.show:fireStop(song.id, Time()) end
    if reply.result == 3 and editable() then songDialog(song.id) end
end

function actions.stop()
    if onMac() then return end
    local current = state.show and state.show.engine.currentSong
    local song = current and { id = current } or chooseSong("Song to stop")
    if song and state.show then state.show:fireStop(song.id, Time()) end
end

function actions.quit()
    local reply = MessageBox({
        title = "TrigIT: quit",
        message = "Stop TrigIT? It disarms, stops following timecode and sends nothing until you run the plugin again.\n\n"
            .. "To keep TrigIT running, close the panel with its ✖ instead.",
        commands = { { value = 1, name = "Quit TrigIT" }, { value = 0, name = "Cancel" } },
    })
    if reply.result == 1 then state.quit = true end
end

function actions.import()
    if not state.file then actions.load() end
    if not state.file then return end
    import(state.file, state.text, { slot = state.slot, rate = state.rate })
end

local function text(parent, anchors, font, align)
    local object = parent:Append("UIObject")
    object.Anchors, object.Font, object.HasHover = anchors, font or "console18", "No"
    object.TextalignmentH, object.TextalignmentV = align or "Left", "Top"
    object.Text = ""
    return object
end

local function button(parent, anchors, label, action)
    local object = parent:Append("Button")
    object.Anchors, object.Text, object.Font = anchors, label, "Medium20"
    object.PluginComponent = myHandle
    object.Clicked = "TrigIT" .. action
    return object
end

local function rows(grid, sizes)
    grid.Columns, grid.Rows = 1, #sizes
    for i, size in ipairs(sizes) do
        if size == "*" then
            grid[1][i].SizePolicy = "Stretch"
        else
            grid[1][i].SizePolicy, grid[1][i].Size = "Fixed", tostring(size)
        end
    end
end

local SONG_ROWS, LOG_ROWS = 10, 8 -- ponytail: fixed rows, built once; long Sets scroll to the current Song
local GREEN, ORANGE = "Global.SuccessText", "Global.WarningText"

-- Built once and only ever changed in place: removing panel parts right
-- after a tap crashed onPC 2.5.1 (#94).
local function build(overlay)
    local ui = { songRows = {}, logRows = {} }
    local base = overlay:Append("BaseInput")
    base.Name = PANEL
    base.AutoClose, base.CloseOnEscape = "No", "Yes"
    rows(base, { 60, "*" })
    local title = base:Append("TitleBar")
    title.Columns, title.Rows, title.Anchors = 2, 1, "0,0"
    title[2][2].SizePolicy, title[2][2].Size = "Fixed", "60"
    local name = title:Append("TitleButton")
    name.Text, name.Anchors = "TrigIT", "0,0"
    title:Append("CloseButton").Anchors = "1,0"

    -- Full: Playhead, current and next Song, Armed; an alert banner; Songs
    -- (tap to fire) and recent fires; the buttons.
    local frame = base:Append("DialogFrame")
    frame.Anchors = { left = 0, right = 0, top = 1, bottom = 1 }
    rows(frame, { 140, 46, "*", 80 })

    local top = frame:Append("UILayoutGrid")
    top.Anchors, top.Columns, top.Rows = "0,0", 3, 1
    top[2][1].SizePolicy, top[2][1].Size = "Fixed", "360"
    top[2][3].SizePolicy, top[2][3].Size = "Fixed", "300"
    ui.playhead = text(top, "0,0", "console32", "Center")
    ui.playhead.TextalignmentV = "Center"
    local now = top:Append("UILayoutGrid")
    now.Anchors = "1,0"
    rows(now, { 60, 40, 40 })
    ui.song = text(now, "0,0", "Regular32", "Center")
    ui.song.TextalignmentV = "Bottom"
    ui.progress = text(now, "0,1", "Regular20", "Center")
    ui.next = text(now, "0,2", "Regular20", "Center")
    ui.arm = button(top, "2,0", "", "Arm")
    ui.arm.Font = "Regular32"

    ui.status = text(frame, "0,1", "Regular20", "Center")
    ui.status.TextalignmentV = "Center"

    local lists = frame:Append("UILayoutGrid")
    lists.Anchors, lists.Columns, lists.Rows = "0,2", 2, 1
    lists[2][1].SizePolicy, lists[2][1].Size = "Fixed", "560"
    local songs = lists:Append("UILayoutGrid")
    songs.Anchors = "0,0"
    local sizes = { 36 }
    for _ = 1, SONG_ROWS do sizes[#sizes + 1] = 40 end
    sizes[#sizes + 1] = "*"
    rows(songs, sizes)
    ui.songsTitle = text(songs, "0,0", "Medium20", "Left")
    for i = 1, SONG_ROWS do
        local row = button(songs, "0," .. i, "", "Song" .. i)
        row.Font, row.TextalignmentH = "Regular20", "Left"
        ui.songRows[i] = { button = row }
    end
    local log = lists:Append("UILayoutGrid")
    log.Anchors = "1,0"
    sizes = { 36 }
    for _ = 1, LOG_ROWS do sizes[#sizes + 1] = 36 end
    sizes[#sizes + 1] = "*"
    rows(log, sizes)
    text(log, "0,0", "Medium20", "Left").Text = " Recent fires"
    for i = 1, LOG_ROWS do ui.logRows[i] = text(log, "0," .. i, "Regular18", "Left") end

    local buttons = frame:Append("UILayoutGrid")
    buttons.Anchors, buttons.Columns, buttons.Rows = "0,3", 6, 1
    for i, entry in ipairs({ { "Set", "Set" }, { "Settings", "Settings" }, { "Stop Song", "Stop" },
        { "Import Show", "Import" }, { "Compact", "Size" }, { "Quit", "Quit" } }) do
        button(buttons, (i - 1) .. ",0", entry[1], entry[2])
    end

    -- Compact (#95): small enough to keep open next to the console's own views.
    local small = base:Append("DialogFrame")
    small.Anchors = { left = 0, right = 0, top = 1, bottom = 1 }
    rows(small, { 90, 40 })
    local line = small:Append("UILayoutGrid")
    line.Anchors, line.Columns, line.Rows = "0,0", 4, 1
    line[2][4].SizePolicy, line[2][4].Size = "Fixed", "110"
    ui.compact = { playhead = text(line, "0,0", "console32", "Center"), song = text(line, "1,0", "Regular28", "Center") }
    ui.compact.playhead.TextalignmentV, ui.compact.song.TextalignmentV = "Center", "Center"
    ui.compact.arm = button(line, "2,0", "", "Arm")
    ui.compact.arm.Font = "Regular28"
    button(line, "3,0", "Full", "Size")
    ui.compact.status = text(small, "0,1", "Regular18", "Center")
    ui.compact.status.TextalignmentV = "Center"

    ui.base, ui.full, ui.small = base, frame, small
    return ui
end

-- The panel's two sizes, each where it was last dragged to (MA sets X and Y,
-- aligned Left and Top, when the title bar is dragged), else centred.
local SIZES = { Full = { 1300, 800 }, Compact = { 760, 190 } }

local function number(value) return tonumber(tostring(value)) end

local function place(ui)
    local size = state.compact and "Compact" or "Full"
    local base, w, h = ui.base, SIZES[size][1], SIZES[size][2]
    ui.full.Visible, ui.small.Visible = state.compact and "No" or "Yes", state.compact and "Yes" or "No"
    base.W, base.H = w, h
    local x, y = number(setting(size .. "X")), number(setting(size .. "Y"))
    local display = base:Parent():Parent()
    if x and y then
        base.AlignmentH, base.AlignmentV = "Left", "Top"
        base.X = math.max(0, math.min(x, (number(display.W) or w) - w))
        base.Y = math.max(0, math.min(y, (number(display.H) or h) - h))
    else
        base.AlignmentH, base.AlignmentV, base.X, base.Y = "Center", "Center", 0, 0
    end
    ui.size, ui.x, ui.y = size, number(base.X), number(base.Y)
end

function actions.size()
    state.compact = not state.compact
    remember("Compact", state.compact and "Yes" or "No")
    if state.ui and IsObjectValid(state.ui.base) then place(state.ui) end
end

-- Remembers a dragged panel's place, for its size.
local function keepPlace(ui)
    local x, y = number(ui.base.X), number(ui.base.Y)
    if (x ~= ui.x or y ~= ui.y) and tostring(ui.base.AlignmentH) == "Left" then
        remember(ui.size .. "X", x)
        remember(ui.size .. "Y", y)
        ui.x, ui.y = x, y
    end
end

local function put(object, property, value)
    if object[property] ~= value then object[property] = value end
end

local ALERTS = {
    allTimecodeLost = "Timecode lost",
    primaryLostRunningOnBackup = "Primary timecode lost, running on backup",
}

local function render(ui, now)
    local show = state.show
    local engine = show and show.engine
    local model = view.model(state.set, show, state.rate)
    local armed = model.armed

    put(ui.playhead, "Text", model.playhead or "--:--:--:--")
    put(ui.playhead, "TextColor", (model.playhead and not engine.isStopped) and "Global.Text" or "Global.LabelText")
    put(ui.song, "Text", model.song or "No Song")
    put(ui.progress, "Text", model.progress or "")
    put(ui.next, "Text", model.next or "")
    put(ui.arm, "Text", state.mode == "Bridge" and "BRIDGE" or armed and "ARMED" or "Disarmed")
    put(ui.arm, "BackColor", armed and RED or "Button.Background")
    for _, field in ipairs({ "playhead", "song", "arm" }) do put(ui.compact[field], "Text", ui[field].Text) end
    put(ui.compact.arm, "BackColor", armed and RED or "Button.Background")

    local running = state.lastMove and now - state.lastMove < 0.5
    local first = state.mode == "Bridge" and ("Bridge to %s, %d frames sent"):format(state.bridgeTo, state.frames or 0)
        or state.file and state.file.name .. (state.locked and "  (Show Lock)" or "") or "No Set: Set > Load Set or New Set"
    local status = ("%s   |   slot %d%s at %s fps, %s"):format(first, state.slot,
        state.backup and (" (backup %d)"):format(state.backup) or "", state.rate,
        running and (state.backup and engine and engine.liveSource == "backup" and "following Backup"
            or state.backup and "following Primary" or "timecode running") or "no timecode")
    local alert = engine and ALERTS[engine.alert or ""]
    local warning = alert or (state.mode == "Bridge" and state.bridgeProblem) or (armed and state.twice)
        or (state.notice ~= "" and state.notice)
    for _, line in ipairs({ ui.status, ui.compact.status }) do
        put(line, "Text", warning or status)
        put(line, "TextColor", warning and "Global.Text" or "Global.LabelText")
        put(line, "BackColor", warning and RED or "UIObject.Background")
    end

    -- Songs: a window of SONG_ROWS rows that keeps the current Song in view.
    local current = 1
    for i, row in ipairs(model.songs) do if row.current then current = i end end
    local offset = math.max(0, math.min(current - 3, #model.songs - SONG_ROWS))
    put(ui.songsTitle, "Text", (" Songs (%d)   tap one to fire it"):format(#model.songs))
    for i = 1, SONG_ROWS do
        local row, slot = model.songs[offset + i], ui.songRows[i]
        slot.song = row
        put(slot.button, "Text", row and ("%s  %s     %s%s"):format(row.current and ">" or " ", row.name, row.span,
            row.fired and not row.current and "   (fired)" or "") or "")
        put(slot.button, "TextColor", row and (row.current and GREEN or row.fired and "Global.LabelText") or "Global.Text")
        put(slot.button, "Visible", row and "Yes" or "No")
    end

    for i = 1, LOG_ROWS do
        local entry = model.log[i]
        put(ui.logRows[i], "Text", entry and (" %s   %s"):format(entry.time ~= "" and entry.time or "           ", entry.text) or "")
        put(ui.logRows[i], "TextColor", entry and entry.failed and RED or "Global.Text")
    end
end

-- The panel only shows TrigIT: closing it leaves the loop below running
-- (#94), and running the plugin again opens a new panel on the same state.
local function closePanel()
    for i = 1, 16 do
        local display = GetDisplayByIndex(i)
        if not display then return end
        local panel = display.ScreenOverlay:FindRecursive(PANEL)
        if panel then return panel:Parent():Remove(panel:Index()) end
    end
end

local function displays()
    local list, i = {}, 1
    while GetDisplayByIndex(i) do list[i], i = GetDisplayByIndex(i), i + 1 end
    return list
end

local function openPanel()
    for _, display in ipairs(displays()) do
        if display.ScreenOverlay:FindRecursive(PANEL) then return end
    end
    local display = GetDisplayByIndex(number(setting("Screen")) or 1) or GetDisplayByIndex(1)
    state.ui = build(display.ScreenOverlay)
    place(state.ui)
end

-- One TrigIT at a time: each start writes a new run token to the show's
-- global variables, and a loop whose token is gone ends. That covers a
-- re-imported plugin (a second copy of this file) and a newly loaded show.
local RUN = "Run"

-- Commands from a macro, an executor or the command line (#98), such as
-- Plugin TrigIT "arm". They act on the running TrigIT.
local function command(request)
    local verb = request.verb
    if verb == "open" then return openPanel() end
    if verb == "start" then return end -- running already: nothing to do
    if verb == "screen" then
        if not GetDisplayByIndex(request.screen) then
            return ErrPrintf(("TrigIT: there is no screen %d here; there are %d"):format(request.screen, #displays()))
        end
        remember("Screen", request.screen)
        local open = state.ui and IsObjectValid(state.ui.base)
        return Printf(("TrigIT: the panel opens on screen %d%s"):format(request.screen,
            open and " the next time you open it: close it first" or ""))
    end
    if verb == "quit" then
        state.quit = true
        return Printf("TrigIT: stopping")
    end
    if verb == "stop" or verb == "fire" then
        if onMac() then return ErrPrintf("TrigIT: in bridge mode the Mac app fires") end
        if not state.show then return ErrPrintf("TrigIT: no Set loaded") end
        if verb == "stop" then
            local current = state.show.engine.currentSong
            if not current then return Printf("TrigIT: no current Song to stop") end
            return state.show:fireStop(current, Time())
        end
        for _, song in ipairs(state.set.songs) do
            if song.name:lower() == request.song:lower() then return state.show:fire(song.id, Time()) end
        end
        return ErrPrintf(('TrigIT: no Song named "%s" in %s'):format(request.song, state.file.name))
    end
    if state.mode == "Bridge" then return ErrPrintf("TrigIT: in bridge mode, arm on the Mac") end
    if not state.show then return ErrPrintf("TrigIT: no Set loaded, so nothing to arm") end
    local armed = state.show.engine.isArmed
    local want = verb == "arm" or (verb == "toggle" and not armed)
    if want ~= armed then state.show:setArmed(want) end
    Printf("TrigIT: " .. (want and "Armed" or "Disarmed"))
end

-- MA3 has no hook for a show load, and a show load ends every plugin (#99).
-- So the first start in a show makes a macro that starts TrigIT, for the
-- operator to run after loading the show or to put on a key.
local START_MACRO = "Made by the TrigIT plugin: run it after loading this show to start TrigIT, disarmed."

local function startMacro()
    if setting("StartMacro") then return end -- made once per show; deleting it turns this off
    local pool = DataPool().Macros
    for _, macro in ipairs(pool:Children()) do
        if tostring(macro:Get("Note") or "") == START_MACRO then return remember("StartMacro", tostring(macro.no)) end
    end
    local n = 1
    while pool[n] do n = n + 1 end
    Cmd(('Store Macro %d "TrigIT start"'):format(n))
    local macro = pool[n]
    if not macro then return ErrPrintf("TrigIT: could not make the TrigIT start macro") end
    macro:Append().Command = ('Plugin "%s" "start"'):format(plainName(myHandle:Parent().name))
    macro.Note = START_MACRO
    remember("StartMacro", tostring(n))
    Printf(("TrigIT: made Macro %d \"TrigIT start\". Run it after loading this show to start TrigIT."):format(n))
end

local function main(_, text)
    local request, why = arguments.parse(text)
    if not request then return ErrPrintf("TrigIT: " .. why) end
    local running = state.token and setting(RUN) == state.token
    if running then return command(request) end
    if request.verb == "quit" then return Printf("TrigIT is not running") end

    -- A stopped TrigIT's panel is reused; one left by another copy of the
    -- plugin (re-imported) is closed.
    if not (state.ui and IsObjectValid(state.ui.base)) then closePanel() end
    local tc = previous()
    state.slot = tonumber(setting("Slot")) or (tc and tonumber(tostring(tc.TCSlot))) or 1
    state.rate = setting("Rate") or (tc and tostring(tc:Get("Note")):match("Frame rate: (.+)$")) or "30"
    state.mode, state.bridgeTo = setting("Mode") or "Standalone", setting("BridgeTo")
    local backup = tonumber(setting("BackupSlot"))
    state.backup = backup ~= 0 and backup ~= state.slot and backup or nil
    local path, name = setting("SetPath"), setting("SetName")
    if path and name then load({ path = path, name = name }, true) end

    local token = ("%.6f-%d"):format(Time(), math.random(1, 1e9))
    state.token, state.quit = token, false
    remember(RUN, token)
    state.compact = setting("Compact") == "Yes"
    state.locked = setting("ShowLock") == "Yes"
    for _, action in ipairs({ "Set", "Settings", "Stop", "Import", "Size", "Quit" }) do
        signalTable["TrigIT" .. action] = function() state.pending = action:lower() end
    end
    for i = 1, SONG_ROWS do signalTable["TrigITSong" .. i] = function() state.pending = "song" .. i end end
    signalTable.TrigITArm = function()
        if state.show and state.mode ~= "Bridge" then state.show:setArmed(not state.show.engine.isArmed) end
    end
    local ok, problem = pcall(startMacro)
    if not ok then ErrPrintf("TrigIT: " .. tostring(problem)) end
    Printf("TrigIT is running. Closing its panel leaves it running; run the plugin again to reopen it, Quit to stop it.")
    command(request) -- opens the panel when asked to, or with no argument

    while state.token == token and not state.quit do
        local now = Time()
        local action = state.pending
        state.pending = nil
        if action then
            local name, row = action:match("^(%a+)(%d*)$")
            local ok, problem = pcall(actions[name], tonumber(row))
            if not ok then ErrPrintf("TrigIT: " .. tostring(problem)) end
        end
        local show = state.show
        for role, number in pairs({ primary = state.slot, backup = state.backup }) do
            local slot = Root().TimecodeSlots[number]
            local time = slot and slot.Time
            local last = state.lastTime[role]
            -- The slot's first value may be left from long ago: follow it once it moves.
            if time and time ~= last then
                if last then
                    if show then show:follow(time / SLOT_UNITS, now, role) end
                    if role == "primary" and state.mode == "Bridge" then bridge(time / SLOT_UNITS) end
                    state.lastMove = now
                end
                state.lastTime[role] = time
            end
        end
        if show then
            show:tick(now)
            for _, command in ipairs(show:take()) do
                local result = Cmd(command)
                if result ~= "OK" then show:note(("%s: %s"):format(command, tostring(result)), true) end
            end
        end
        -- An import, or someone at the console, may change an imported Timecode.
        if now - (state.checked or 0) > 1 then
            checkTwice()
            state.checked = now
            if setting(RUN) ~= token then state.token = nil end -- another TrigIT started, or another show was loaded
            if state.ui and IsObjectValid(state.ui.base) then keepPlace(state.ui) end
        end
        if state.ui and IsObjectValid(state.ui.base) then render(state.ui, now) end
        coroutine.yield(0)
    end

    if state.token and state.token ~= token then return end -- a newer run in this same state took over
    if state.show then state.show:setArmed(false) end
    state.token, state.show = nil, nil
    -- The panel stays: removing it from here right after its Quit dialog
    -- crashed onPC 2.5.1. It says TrigIT stopped and closes with its ✖.
    local ui = state.ui
    if ui and IsObjectValid(ui.base) then
        put(ui.playhead, "Text", "--:--:--:--")
        put(ui.song, "Text", "Stopped")
        put(ui.arm, "Text", "Stopped")
        put(ui.arm, "BackColor", "Button.Background")
        put(ui.status, "Text", "TrigIT stopped: nothing is sent. Close this panel, or run the plugin to start again.")
        put(ui.status, "TextColor", "Global.Text")
    end
    Printf("TrigIT stopped: nothing is sent until you run the plugin again.")
end

return main
