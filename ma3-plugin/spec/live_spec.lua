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
                { id = "d", destination = "200", type = "msc", msc = { command = "go", cue = "5" } },
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
        assert.same({ 'SendOSC 7 "/go,i,1"', 'SendMIDI "Note" 1/60 100', "DMXUniverse 2.1 At Decimal8 255" }, show:take())
        assert.same({ "Intro: MSC to Synth not sent: MIDI Show Control Actions can't be sent from grandMA3 (SendMIDI has no SysEx); left out",
            "Intro: DMX pulse 1.1 to Lights", "Intro: note 1/60 to Synth", "Intro: OSC /go to Resolume", "Intro entered" },
            texts(show))
        assert.is_true(show.log[1].failed)
    end)

    it("ends the MIDI note after the note length, and the DMX pulse after its duration", function()
        local show = live.new(set(), "25", function() return 7 end, true)
        local now = play(show, "00:59:59:20", 7, 1000)
        show:take()
        show:tick(now + 0.2)
        assert.same({ 'SendMIDI "Note" 1/60 0' }, show:take())
        show:tick(now + 0.4)
        assert.same({}, show:take())
        show:tick(now + 0.5)
        assert.same({ "Off DMXUniverse 2.1" }, show:take())
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
        assert.same({ 'SendMIDI "Note" 1/60 100', "DMXUniverse 2.1 At Decimal8 255" }, show:take())
        assert.same('Intro: OSC /go to Resolume not sent: no OSC line for "Resolume": import the Set, or name a line "TrigIT Resolume"',
            texts(show)[4])
    end)

    it("fires by hand even while disarmed", function()
        local show = live.new(set(), "25", function() return 7 end, false)
        show:fire("1", 1000)
        assert.same({ 'SendOSC 7 "/go,i,1"', 'SendMIDI "Note" 1/60 100', "DMXUniverse 2.1 At Decimal8 255" }, show:take())
        assert.same("Intro fired by hand", texts(show)[5])
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

-- Both slots carry the same timecode from `from`; the primary stops after
-- `primaryFrames` frames, the backup runs `frames` frames.
local function playBoth(show, from, frames, primaryFrames, now)
    local start = ma3.seconds(from, "25")
    for i = 0, frames * 3 - 1 do
        if i < primaryFrames * 3 then show:follow(start + i / 75, now + i / 75) end
        show:follow(start + i / 75, now + i / 75, "backup")
        show:tick(now + i / 75)
    end
    return now + frames / 25
end

-- How many times the Song's OSC Start Action was sent.
local function fires(show)
    local n = 0
    for _, command in ipairs(show:take()) do if command:find("/go", 1, true) then n = n + 1 end end
    return n
end

describe("a Backup slot", function()
    it("takes over when the primary stops, and the Song fires once", function()
        local show = live.new(set(), "25", function() return 7 end, true)
        playBoth(show, "00:59:59:10", 30, 5, 1000)
        assert.equal(1, fires(show))
        assert.equal("backup", show.engine.liveSource)
        assert.equal("primaryLostRunningOnBackup", show.engine.alert)
    end)

    it("doesn't fire the Song again when the primary stops mid-Song", function()
        local show = live.new(set(), "25", function() return 7 end, true)
        local now = playBoth(show, "00:59:59:20", 7, 7, 1000)
        assert.equal(1, fires(show))
        playBoth(show, "01:00:00:02", 30, 0, now)
        assert.equal(0, fires(show))
        assert.equal("backup", show.engine.liveSource)
        assert.equal("primaryLostRunningOnBackup", show.engine.alert)
    end)

    it("is only watched while the primary runs", function()
        local show = live.new(set(), "25", function() return 7 end, true)
        playBoth(show, "00:59:59:20", 10, 10, 1000)
        assert.equal(1, fires(show))
        assert.equal("primary", show.engine.liveSource)
        assert.is_nil(show.engine.alert)
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
