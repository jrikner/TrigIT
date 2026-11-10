-- SPDX-License-Identifier: GPL-3.0-or-later
-- Making and editing a Set on the console, saved as a .trigit file.

local edit = require("setedit")
local plan = require("trigit_plan")
local json = require("json")

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("a")
    file:close()
    return text
end

-- The Set the console-written fixture holds: fixed IDs, so the file is stable.
local function consoleSet()
    local ids = 0
    local newID = edit.newID
    edit.newID = function() ids = ids + 1; return tostring(1000 + ids) end
    local set = edit.newSet("Made on the console")
    assert(edit.putDestination(set, "Resolume", "192.168.1.20", "7000"))
    local intro = assert(edit.putSong(set, nil, "Intro", "01:00:00:00", "01:04:00:00"))
    assert(edit.addAction(set, intro.id, "resolume", "osc", "/composition/columns/1/connect", '1 0.5 "go now"', "start"))
    assert(edit.addAction(set, intro.id, "Resolume", "midi-note", "10/36", "100", "stop"))
    assert(edit.putSong(set, nil, "Outro", "1:5:0:0", "01:06:00:00"))
    edit.newID = newID
    return set
end

describe("the console's Set editor", function()
    it("refuses what the Mac app refuses, in its words", function()
        local set = edit.newSet("")
        assert.same("Untitled Set", set.name)
        assert.same({ nil, "the name is empty" }, { edit.putSong(set, nil, " ", "01:00:00:00", "01:01:00:00") })
        assert.same({ nil, 'start "1:00" is not a timecode (hh:mm:ss:ff)' }, { edit.putSong(set, nil, "A", "1:00", "01:01:00:00") })
        assert.same({ nil, "end is before start" }, { edit.putSong(set, nil, "A", "01:01:00:00", "01:00:00:00") })
        local a = assert(edit.putSong(set, nil, "A", "01:00:00:00", "01:01:00:00"))
        assert.same({ nil, 'overlaps "A"' }, { edit.putSong(set, nil, "B", "01:01:00:00", "01:02:00:00") })
        assert.truthy(edit.putSong(set, a.id, "A", "01:00:00:00", "01:01:30:00"), "a Song never overlaps itself")
        assert.same({ nil, 'there is no Destination "X"' }, { edit.addAction(set, a.id, "X", "osc", "/a", "", "start") })
        assert.truthy(edit.putDestination(set, "X", "10.0.0.1", 8000))
        assert.same({ nil, '"a" is not an OSC address' }, { edit.addAction(set, a.id, "X", "osc", "a", "", "start") })
        assert.same({ nil, '"300.1.1.1" is not an IP address, such as 192.168.1.20' }, { edit.putDestination(set, "Y", "300.1.1.1", 1) })
        assert.same({ nil, "the port must be 1-65535" }, { edit.putDestination(set, "Y", "10.0.0.2", "0") })
    end)

    it("edits, reorders and deletes Songs and Actions", function()
        local set = consoleSet()
        local intro, outro = set.songs[1], set.songs[2]
        assert.same("01:05:00:00", outro.start, "timecodes are written in full")
        edit.moveSong(set, outro.id, -1)
        assert.same({ "Outro", "Intro" }, { set.songs[1].name, set.songs[2].name })
        assert.same("Start: OSC /composition/columns/1/connect 1 0.5 \"go now\" to Resolume", edit.describe(set, intro.startActions[1], "start"))
        assert.same("Stop: note 10/36 velocity 100 to Resolume", edit.describe(set, intro.stopActions[1], "stop"))
        edit.removeAction(set, intro.id, intro.stopActions[1].id)
        assert.same({}, intro.stopActions)
        edit.deleteSong(set, outro.id)
        assert.same({ "Intro" }, { set.songs[1].name, set.songs[2] })
    end)

    it("saves a file the plugin reads back as the same Set", function()
        local set = consoleSet()
        assert.same(set, plan.readSet(edit.encode(set)))
    end)

    it("keeps every field of a Mac-written file it doesn't edit", function()
        local text = read("spec/fixtures/full.trigit")
        local set = plan.readSet(text)
        local saved = plan.readSet(edit.encode(set))
        assert.same(json.decode(text).set, saved)
    end)

    -- Tests/TrigITStorageTests/MA3FixtureTests.swift opens this file in the Mac app's own code.
    it("matches the console-written fixture the Swift tests open", function()
        local text = edit.encode(consoleSet())
        if os.getenv("TRIGIT_WRITE_FIXTURES") then
            local file = assert(io.open("spec/fixtures/console-written.trigit", "wb"))
            file:write(text)
            file:close()
        end
        assert.same(read("spec/fixtures/console-written.trigit"), text)
    end)
    it("fills Actions from the Mac app's presets", function()
        local set = edit.newSet("Presets")
        assert(edit.putDestination(set, "Resolume", "127.0.0.1", 7000))
        local song = assert(edit.putSong(set, nil, "A", "01:00:00:00", "01:01:00:00"))
        local function add(label, values)
            for _, preset in ipairs(edit.PRESETS) do
                if preset.label == label then
                    local address, arguments = assert(edit.preset(preset, values))
                    return edit.describe(set, assert(edit.addAction(set, song.id, "Resolume", "osc", address, arguments, "start")), "start")
                end
            end
        end
        assert.same("Start: OSC /composition/layers/2/clips/5/connect 1 to Resolume", add("Resolume: launch clip", { "2", " 5" }))
        assert.same("Start: OSC /composition/disconnectall 1 to Resolume", add("Resolume: clear composition", {}))
        assert.same('Start: OSC /cmd "Go+ Exec 1.201" to Resolume', add("grandMA3: Go+ executor (OSC)", { "1", "201" }))
        assert.same('Start: OSC /cmd "Label Seq 1 "Big"" to Resolume', add("grandMA3: command (OSC)", { 'Label Seq 1 "Big" ' }))
        assert.same({ nil, 'Layer "x" is not a number from 1' }, { edit.preset(edit.PRESETS[2], { "x", "1" }) })
        assert.same({ nil, "the command is empty" }, { edit.preset(edit.PRESETS[9], { " " }) })
    end)
end)
