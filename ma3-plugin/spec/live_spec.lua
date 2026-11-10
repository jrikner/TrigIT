-- SPDX-License-Identifier: GPL-3.0-or-later
-- The Show Engine on the console, through live.lua's inputs (slot seconds,
-- the clock, the Armed switch) and outputs (commands to run, the log).

local live = require("live")
local ma3 = require("ma3")
local timecode = require("timecode")

local resolume = { id = "100", name = "Resolume", host = "127.0.0.1", port = 7000, usesOSC = true }
local synth = { id = "200", name = "Synth", usesOSC = false, usesMIDI = true }
local lights = { id = "300", name = "Lights", usesOSC = false, usesDMX = true }

local function set()
    return {
        destinations = { resolume, synth, lights },
        songs = { {
            id = "1", name = "Intro", start = "01:00:00:00", ["end"] = "01:00:10:00",
            startActions = {
                { id = "a", destination = "100", type = "osc", osc = { address = "/go", arguments = { { int = 1 } } } },
                { id = "b", destination = "200", type = "midiNote", midiNote = { channel = 0, note = 60, velocity = 100 } },
                { id = "c", destination = "300", type = "dmxPulse", dmxPulse = { universe = 1, channel = 1, value = 255 } },
            },
            stopActions = {},
        } },
    }
end

-- Plays 25 fps frames from `from` for `frames` frames, a reading each frame,
-- several loop passes per frame as the plugin does. Returns the clock after.
local function play(show, from, frames, now)
    local start = ma3.seconds(from, "25")
    for i = 0, frames * 3 - 1 do
        show:follow(start + i / 75, now + i / 75)
        show:tick(now + i / 75)
    end
    return now + frames / 25
end

local function texts(show)
    local out = {}
    for _, entry in ipairs(show.log) do out[#out + 1] = entry.text end
    return out
end

describe("the Show Engine on the console", function()
    it("sends a Song's Actions when armed and the Playhead enters it", function()
        local show = live.new(set(), "25", function(d) return d.name == "Resolume" and 7 or nil end, true)
        play(show, "00:59:59:20", 7, 1000)
        assert.same({ 'SendOSC 7 "/go,i,1"', 'SendMIDI "Note" 1/60 100' }, show:take())
        assert.same({ 'Intro: DMX pulse to Lights not sent: DMX pulse Actions aren\'t supported by the MA3 plugin yet; left out',
            "Intro: note 1/60 to Synth", "Intro: OSC /go to Resolume", "Intro entered" }, texts(show))
        assert.is_true(show.log[1].failed)
    end)

    it("ends the MIDI note after the note length", function()
        local show = live.new(set(), "25", function() return 7 end, true)
        local now = play(show, "00:59:59:20", 7, 1000)
        show:take()
        show:tick(now + 0.2)
        assert.same({ 'SendMIDI "Note" 1/60 0' }, show:take())
    end)

    it("sends nothing while disarmed", function()
        local show = live.new(set(), "25", function() return 7 end, false)
        play(show, "00:59:59:20", 10, 1000)
        assert.same({}, show:take())
        assert.same({ "Intro entered (disarmed: nothing sent)" }, texts(show))
    end)

    it("reports an OSC Destination with no line instead of sending", function()
        local show = live.new(set(), "25", function() return nil end, true)
        play(show, "00:59:59:20", 7, 1000)
        assert.same({ 'SendMIDI "Note" 1/60 100' }, show:take())
        assert.same('Intro: OSC /go to Resolume not sent: no OSC line for "Resolume": import the Set, or name a line "TrigIT Resolume"',
            texts(show)[3])
    end)

    it("fires by hand even while disarmed", function()
        local show = live.new(set(), "25", function() return 7 end, false)
        show:fire("1", 1000)
        assert.same({ 'SendOSC 7 "/go,i,1"', 'SendMIDI "Note" 1/60 100' }, show:take())
        assert.same("Intro fired by hand", texts(show)[4])
    end)

    it("logs the Stop when the slot stops moving, and keeps only the newest entries", function()
        local show = live.new(set(), "25", function() return 7 end, true)
        local now = play(show, "00:59:59:20", 10, 1000)
        for i = 1, 300 do show:tick(now + i / 100) end
        assert.same("Timecode stopped", texts(show)[1])
        for i = 1, 10 do show:fire("1", now + 4 + i) end
        assert.same(live.LOG_LENGTH, #show.log)
    end)
end)

describe("slot seconds as timecode", function()
    it("reads back every frame the Timecode Show writes, at each rate", function()
        for _, rate in ipairs({ "24", "25", "29.97 DF", "30" }) do
            for _, tc in ipairs({ "00:00:00:00", "01:00:00:00", "01:00:59:23", "01:01:00:02", "10:09:59:17", "23:59:59:23" }) do
                assert.same(tc, timecode.fromSeconds(ma3.seconds(tc, rate), rate), rate .. " " .. tc)
            end
        end
    end)
    it("takes an edited Set mid-Song without firing the Song again", function()
        local show = live.new(set(), "25", function() return 7 end, true)
        local now = play(show, "00:59:59:20", 7, 1000)
        show:take()
        local edited = set()
        edited.songs[1].name = "Intro (edited)"
        edited.songs[1]["end"] = "01:00:20:00"
        show:updateSet(edited)
        play(show, "01:00:00:05", 10, now)
        -- Only the first fire's note-off, due 0.1 s after it: no Start Actions again.
        assert.same({ 'SendMIDI "Note" 1/60 0' }, show:take())
        assert.same("Intro (edited)", show.names["1"])
    end)
end)
