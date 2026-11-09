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

local state = { pending = nil, notice = "" }

local function follow()
    state.lastTime, state.lastMove = nil, nil
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

function actions.settings()
    local slots, rates = {}, {}
    for n = 1, #Root().TimecodeSlots:Children() do slots["Slot " .. n] = n end
    for i, rate in ipairs(RATES) do rates[rate] = i end
    local preset = 4
    for i, rate in ipairs(RATES) do if rate == state.rate then preset = i end end
    local reply = MessageBox({
        title = "TrigIT: timecode",
        message = "The slot the show's timecode arrives on, and its frame rate. Changing them disarms the panel.",
        commands = { { value = 1, name = "OK" }, { value = 0, name = "Cancel" } },
        selectors = {
            { name = "Timecode slot", type = 0, values = slots, selectedValue = state.slot },
            { name = "Frame rate", type = 1, values = rates, selectedValue = preset },
        },
    })
    if reply.result ~= 1 then return end
    state.slot, state.rate = reply.selectors["Timecode slot"], RATES[reply.selectors["Frame rate"]]
    remember("Slot", state.slot)
    remember("Rate", state.rate)
    follow()
end

local function onMac()
    if state.mode ~= "Bridge" then return false end
    if state.show then state.show:note("In bridge mode the Mac app fires: use its Show screen", true) end
    return true
end

function actions.mode()
    local reply = MessageBox({
        title = "TrigIT: mode",
        message = "Standalone: this console sends the Set's Actions while Armed.\n"
            .. "Bridge: this console sends the timecode slot to the TrigIT Mac app as Art-Net Timecode, and the Mac app fires. "
            .. "Choose Art-Net Timecode as its Timecode Source.\n\n"
            .. "For bridge mode, enter the Mac's IP address, or a broadcast address such as 192.168.1.255.",
        commands = { { value = 1, name = "OK" }, { value = 0, name = "Cancel" } },
        inputs = { { name = "Mac IP address", value = state.bridgeTo or "", whiteFilter = "0123456789." } },
        selectors = { { name = "Mode", type = 1, values = { Standalone = 1, Bridge = 2 }, selectedValue = state.mode == "Bridge" and 2 or 1 } },
    })
    if reply.result ~= 1 then return end
    local mode, ip = reply.selectors.Mode == 2 and "Bridge" or "Standalone", reply.inputs["Mac IP address"]
    if mode == "Bridge" and not ip:match("^%d+%.%d+%.%d+%.%d+$") then
        say("address needed", "Bridge mode needs the Mac's IP address, such as 192.168.1.20.")
        return
    end
    state.mode, state.bridgeTo = mode, ip
    remember("Mode", mode)
    remember("BridgeTo", ip)
    if state.show then state.show:setArmed(false) end
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

function actions.fire()
    if onMac() then return end
    local song = chooseSong("Song to fire")
    if song and state.show then state.show:fire(song.id, Time()) end
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

local function build(overlay)
    local ui = {}
    local base = overlay:Append("BaseInput")
    base.Name, base.W, base.H = PANEL, 1300, 720
    base.AutoClose, base.CloseOnEscape = "No", "Yes"
    rows(base, { 60, "*" })
    local title = base:Append("TitleBar")
    title.Columns, title.Rows, title.Anchors = 2, 1, "0,0"
    title[2][2].SizePolicy, title[2][2].Size = "Fixed", "60"
    local name = title:Append("TitleButton")
    name.Text, name.Anchors = "TrigIT", "0,0"
    title:Append("CloseButton").Anchors = "1,0"

    local frame = base:Append("DialogFrame")
    frame.Anchors = { left = 0, right = 0, top = 1, bottom = 1 }
    rows(frame, { 110, 50, "*", 80 })

    local top = frame:Append("UILayoutGrid")
    top.Anchors, top.Columns, top.Rows = "0,0", 3, 1
    ui.playhead = text(top, "0,0", "console32", "Center")
    ui.song = text(top, "1,0", "Regular32", "Center")
    ui.playhead.TextalignmentV, ui.song.TextalignmentV = "Center", "Center"
    ui.arm = button(top, "2,0", "", "Arm")
    ui.arm.Font = "Regular28"

    ui.status = text(frame, "0,1", "Regular20", "Center")
    ui.status.TextalignmentV = "Center"

    local lists = frame:Append("UILayoutGrid")
    lists.Anchors, lists.Columns, lists.Rows = "0,2", 2, 1
    lists[2][1].SizePolicy, lists[2][1].Size = "Fixed", "540"
    ui.songs = text(lists, "0,0")
    ui.log = text(lists, "1,0")

    local buttons = frame:Append("UILayoutGrid")
    buttons.Anchors, buttons.Columns, buttons.Rows = "0,3", 7, 1
    for i, entry in ipairs({ { "Load Set", "Load" }, { "Timecode", "Settings" }, { "Mode", "Mode" }, { "Fire Song", "Fire" },
        { "Stop Song", "Stop" }, { "Import Show", "Import" }, { "Quit", "Quit" } }) do
        button(buttons, (i - 1) .. ",0", entry[1], entry[2])
    end
    ui.base = base
    return ui
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
    local current = engine and engine.currentSong
    local armed = engine and engine.isArmed

    put(ui.playhead, "Text", engine and engine.playhead or "--:--:--:--")
    local currentName
    for _, song in ipairs(state.set and state.set.songs or {}) do
        if song.id == current then currentName = song.name end
    end
    put(ui.song, "Text", currentName or "No Song")
    put(ui.arm, "Text", state.mode == "Bridge" and "BRIDGE" or armed and "ARMED" or "Disarmed")
    put(ui.arm, "BackColor", armed and RED or "Button.Background")

    local running = state.lastMove and now - state.lastMove < 0.5
    local first = state.mode == "Bridge" and ("Bridge to %s, %d frames sent"):format(state.bridgeTo, state.frames or 0)
        or state.file and state.file.name or "No Set loaded: Load Set"
    local status = ("%s   |   slot %d at %s fps, %s"):format(first, state.slot, state.rate,
        running and "timecode running" or "no timecode")
    local alert = engine and ALERTS[engine.alert or ""]
    local warning = alert or (state.mode == "Bridge" and state.bridgeProblem) or (armed and state.twice)
        or (state.notice ~= "" and state.notice)
    put(ui.status, "Text", warning or status)
    put(ui.status, "TextColor", warning and RED or "Global.Text")

    local songs = { " SONGS" }
    for _, song in ipairs(state.set and state.set.songs or {}) do
        local span = song.start and (song.start .. " - " .. song["end"]) or "notes only"
        songs[#songs + 1] = ("%s %s   %s"):format(song.id == current and ">" or " ", song.name, span)
    end
    put(ui.songs, "Text", table.concat(songs, "\n"))

    local log = { " LAST ACTIONS" }
    for _, entry in ipairs(show and show.log or {}) do
        log[#log + 1] = ("%s %-11s  %s"):format(entry.failed and "!" or " ", entry.time, entry.text)
    end
    put(ui.log, "Text", table.concat(log, "\n"))
end

-- The panel only shows TrigIT: closing it leaves the loop below running
-- (#94), and running the plugin again opens a new panel on the same state.
local function closePanel()
    local panel = GetDisplayByIndex(1).ScreenOverlay:FindRecursive(PANEL)
    if panel then panel:Parent():Remove(panel:Index()) end
end

local function openPanel()
    local overlay = GetDisplayByIndex(1).ScreenOverlay
    if not overlay:FindRecursive(PANEL) then state.ui = build(overlay) end
end

-- One TrigIT at a time: each start writes a new run token to the show's
-- global variables, and a loop whose token is gone ends. That covers a
-- re-imported plugin (a second copy of this file) and a newly loaded show.
local RUN = "Run"

local function main()
    if state.token and setting(RUN) == state.token then return openPanel() end

    -- A stopped TrigIT's panel is reused; one left by another copy of the
    -- plugin (re-imported) is closed.
    if not (state.ui and IsObjectValid(state.ui.base)) then closePanel() end
    local tc = previous()
    state.slot = tonumber(setting("Slot")) or (tc and tonumber(tostring(tc.TCSlot))) or 1
    state.rate = setting("Rate") or (tc and tostring(tc:Get("Note")):match("Frame rate: (.+)$")) or "30"
    state.mode, state.bridgeTo = setting("Mode") or "Standalone", setting("BridgeTo")
    local path, name = setting("SetPath"), setting("SetName")
    if path and name then load({ path = path, name = name }, true) end

    local token = ("%.6f-%d"):format(Time(), math.random(1, 1e9))
    state.token, state.quit = token, false
    remember(RUN, token)
    for _, action in ipairs({ "Load", "Settings", "Mode", "Fire", "Stop", "Import", "Quit" }) do
        signalTable["TrigIT" .. action] = function() state.pending = action:lower() end
    end
    signalTable.TrigITArm = function()
        if state.show and state.mode ~= "Bridge" then state.show:setArmed(not state.show.engine.isArmed) end
    end
    openPanel()
    Printf("TrigIT is running. Closing its panel leaves it running; run the plugin again to reopen it, Quit to stop it.")

    while state.token == token and not state.quit do
        local now = Time()
        local action = state.pending
        state.pending = nil
        if action then
            local ok, problem = pcall(actions[action])
            if not ok then ErrPrintf("TrigIT: " .. tostring(problem)) end
        end
        local show = state.show
        local slot = Root().TimecodeSlots[state.slot]
        local time = slot and slot.Time
        -- The slot's first value may be left from long ago: follow it once it moves.
        if time and time ~= state.lastTime then
            if state.lastTime then
                if show then show:follow(time / SLOT_UNITS, now) end
                if state.mode == "Bridge" then bridge(time / SLOT_UNITS) end
                state.lastMove = now
            end
            state.lastTime = time
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
