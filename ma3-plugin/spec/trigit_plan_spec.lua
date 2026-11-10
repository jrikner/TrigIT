-- SPDX-License-Identifier: GPL-3.0-or-later
local plan = require("trigit_plan")

local function fixture(name)
    local file = assert(io.open("spec/fixtures/" .. name, "rb"))
    local text = file:read("a")
    file:close()
    return text
end

-- The Mac app's example Set (ShowSet.example) as a plan.
local examplePlan = {
    frameRate = "30",
    destinations = { { name = "Resolume", kind = "osc", host = "127.0.0.1", port = 7000 } },
    events = {
        {
            time = "01:00:00:00", song = "Intro", phase = "start", destination = { osc_line_for = "Resolume" },
            command = 'SendOSC $line "/composition/columns/1/connect,i,1"',
        },
    },
    warnings = {},
}

describe(".trigit files", function()
    it("turns the Mac app's example Set into its plan", function()
        assert.same(examplePlan, plan.fromTrigit(fixture("example.trigit")))
    end)

    it("plans every kind of Action, and says why Songs are left out", function()
        local intro = 'Intro "live" ✨'
        assert.same({
            frameRate = "25",
            destinations = {
                { name = "Resolume", kind = "osc", host = "10.0.0.20", port = 7000 },
                { name = "MA3", kind = "osc+midi+dmx", host = "2.255.255.255", port = 8000, midiPort = "MA3 MIDI" },
            },
            events = {
                {
                    time = "01:00:00:00", song = intro, phase = "start", destination = { osc_line_for = "Resolume" },
                    command = 'SendOSC $line "/composition/columns/1/connect,ifs,1,0.5,two words"',
                },
                -- Stop Actions go out when the Playhead plays on past the end.
                {
                    time = "01:04:00:01", song = intro, phase = "stop", destination = { midi_for = "MA3" },
                    command = 'SendMIDI "Note" 10/36 100',
                    release = { after = 0.1, command = 'SendMIDI "Note" 10/36 0', name = "note off" },
                },
                -- Art-Net universe 2 is MA3 universe 3; released after the pulse's 0.25 s.
                {
                    time = "01:04:00:01", song = intro, phase = "stop", destination = { dmx_for = "MA3" },
                    command = "DMXUniverse 3.101 At Decimal8 200",
                    release = { after = 0.25, command = "Off DMXUniverse 3.101", name = "DMX release" },
                },
            },
            warnings = {
                'Song "' .. intro .. '": MIDI Show Control Actions can\'t be sent from grandMA3 (SendMIDI has no SysEx); left out',
                'Song "Start Note only": skipped: it has a Start Note and no timecode span, so it can\'t become timecode events',
                'Song "Stop Note only": skipped: it has a Stop Note and no timecode span, so it can\'t become timecode events',
                'Song "Overlaps Intro": overlaps "' .. intro .. '"',
            },
        }, plan.fromTrigit(fixture("full.trigit"), { frameRate = "25" }))
    end)

    it("reads files from before the transport switches as they behaved", function()
        local result = plan.fromTrigit([[{"format": "TrigIT Set", "version": 1, "set": {
            "destinations": [{"id": "1", "name": "Old", "host": "h", "port": 1, "midiOutput": {"uniqueID": 5, "name": "Port"}}],
            "songs": [{"name": "A", "start": "00:00:01:00", "end": "00:00:02:00", "startActions": [
                {"destination": "1", "type": "midiNote", "midiNote": {"channel": 0, "note": 60, "velocity": 127}},
                {"destination": "1", "type": "dmxPulse", "dmxPulse": {"universe": 1, "channel": 1, "value": 255, "duration": 0.5}},
                {"destination": "9", "type": "osc", "osc": {"address": "/x", "arguments": []}}]}]}}]])
        assert.same({ { name = "Old", kind = "osc+midi", host = "h", port = 1, midiPort = "Port" } }, result.destinations)
        assert.same({ 'SendMIDI "Note" 1/60 127' }, { result.events[1].command })
        assert.same({
            'Song "A": Destination "Old" has DMX switched off; Action left out',
            'Song "A": an Action sends to a Destination that isn\'t in the Set; left out',
        }, result.warnings)
    end)

    it("puts DMX pulses on the MA3 universe the Destination's protocol maps to", function()
        local function pulse(output, universe)
            local result = plan.fromTrigit(([[{"format": "TrigIT Set", "version": 1, "set": {
                "destinations": [{"id": "1", "name": "Node", "usesDMX": true, "dmxOutput": "%s"}],
                "songs": [{"name": "A", "start": "00:00:01:00", "end": "00:00:02:00", "startActions": [
                    {"destination": "1", "type": "dmxPulse",
                     "dmxPulse": {"universe": %d, "channel": 512, "value": 0, "duration": 2}}]}]}}]]):format(output, universe))
            local event = result.events[1]
            return event and { event.command, event.release.command, event.release.after } or result.warnings[1]
        end
        assert.same({ "DMXUniverse 1.512 At Decimal8 0", "Off DMXUniverse 1.512", 2 }, pulse("artNet", 0))
        assert.same({ "DMXUniverse 1024.512 At Decimal8 0", "Off DMXUniverse 1024.512", 2 }, pulse("artNet", 1023))
        assert.same({ "DMXUniverse 1.512 At Decimal8 0", "Off DMXUniverse 1.512", 2 }, pulse("sACNMulticast", 1))
        assert.same({ "DMXUniverse 1024.512 At Decimal8 0", "Off DMXUniverse 1024.512", 2 }, pulse("sACNUnicast", 1024))
        assert.equal('Song "A": Art-Net universe 1024 would be MA3 universe 1025; the console has 1-1024', pulse("artNet", 1024))
        assert.equal('Song "A": sACN universe 1025 would be MA3 universe 1025; the console has 1-1024', pulse("sACNMulticast", 1025))
    end)

    it("refuses what isn't a TrigIT Set, as the app does", function()
        local function reason(text) return select(2, plan.fromTrigit(text)) end
        assert.equal("The file is not a TrigIT Set (it isn't JSON).", reason("not json"))
        assert.equal("The file is JSON, but not a TrigIT Set.", reason('{"format": "Other", "version": 1}'))
        assert.equal("The Set was saved by a newer TrigIT (file version 2); update TrigIT to open it.",
            reason('{"format": "TrigIT Set", "version": 2, "set": {}}'))
        assert.equal('The Set file is damaged: it has no "set".', reason('{"format": "TrigIT Set", "version": 1}'))
        assert.equal('The Set file is damaged: "1:00" is not a timecode (hh:mm:ss:ff).',
            reason('{"format": "TrigIT Set", "version": 1, "set": {"songs": [{"name": "A", "start": "1:00", "end": "1:00"}]}}'))
    end)
end)

describe("CSV", function()
    it("reads the app's three columns with a header, quoted names and any separator", function()
        for _, separator in ipairs({ ",", ";", "\t" }) do
            local csv = table.concat({
                "name,start,end",
                '"Intro, part ""one""",01:00:00:00,01:04:00:00',
                "",
                "  Outro  , 02:00:00:00 , 02:01:30:00 ",
            }, "\r\n"):gsub(",", separator)
            local result = plan.fromCSV(csv)
            assert.same({}, result.warnings)
            assert.same({}, result.events)
            -- Songs without Actions plan nothing; check they were read through an overlap.
            local overlapping = plan.fromCSV(csv .. "\nX" .. separator .. "02:01:30:00" .. separator .. "02:02:00:00")
            assert.same({ 'line 5: overlaps "Outro"' }, overlapping.warnings)
        end
    end)

    it("reports refused rows with line numbers and the app's reasons", function()
        local result = plan.fromCSV(table.concat({
            "A,01:00:00:00,01:01:00:00,Res,osc,/a",
            "only two,01:00:00:00",
            ",01:00:00:00,01:01:00:00",
            "B,1:00,01:01:00:00",
            "C,01:00:00:00,01:61:00:00",
            "D,02:00:00:00,01:00:00:00",
            "E,01:00:30:00,01:02:00:00,Res,osc,/e",
            "F,01:01:00:01,01:02:00:00,Res,osc,/f",
            "G,01:00:00:00,01:00:00:30",
        }, "\n"))
        assert.same({
            "line 2: needs name, start and end; found 2 columns",
            "line 3: the name is empty",
            'line 4: start "1:00" is not a timecode (hh:mm:ss:ff)',
            'line 5: end "01:61:00:00" is not a timecode (hh:mm:ss:ff)',
            "line 6: end is before start",
            'line 7: overlaps "A"',
            'line 9: end "01:00:00:30" is not a timecode (hh:mm:ss:ff)',
        }, result.warnings)
        local songs = {}
        for _, event in ipairs(result.events) do songs[#songs + 1] = event.song end
        assert.same({ "A", "F" }, songs)
    end)

    it("doesn't treat a first row with a timecode as a header", function()
        assert.same({ 'line 1: end "end" is not a timecode (hh:mm:ss:ff)' },
            plan.fromCSV("A,01:00:00:00,end").warnings)
    end)

    it("adds Actions from rows with no name to the Song above, Start or Stop", function()
        local result = plan.fromCSV(table.concat({
            "name;start;end;destination;kind;address;args;when",
            "Intro;01:00:00:00;01:00:59:29;Resolume;osc;/composition/columns/1/connect;1",
            -- Quotes inside a CSV field are doubled.
            ';;;Resolume;OSC;/layer/clear;"0.5 ""two words"" text ""42""";start',
            ";;;MA3;midi-note;10/36;100;stop",
            ";;;MA3;dmx;2.101;;stop",
            ";;;MA3;midi-note;61",
        }, "\n"), { frameRate = "30" })
        assert.same({}, result.warnings)
        assert.same({
            { name = "Resolume", kind = "osc" },
            { name = "MA3", kind = "midi+dmx" },
        }, result.destinations)
        assert.same({
            {
                time = "01:00:00:00", song = "Intro", phase = "start", destination = { osc_line_for = "Resolume" },
                command = 'SendOSC $line "/composition/columns/1/connect,i,1"',
            },
            {
                time = "01:00:00:00", song = "Intro", phase = "start", destination = { osc_line_for = "Resolume" },
                command = 'SendOSC $line "/layer/clear,fsss,0.5,two words,text,42"',
            },
            {
                time = "01:00:00:00", song = "Intro", phase = "start", destination = { midi_for = "MA3" },
                command = 'SendMIDI "Note" 1/61 127',
                release = { after = 0.1, command = 'SendMIDI "Note" 1/61 0', name = "note off" },
            },
            {
                time = "01:01:00:00", song = "Intro", phase = "stop", destination = { midi_for = "MA3" },
                command = 'SendMIDI "Note" 10/36 100',
                release = { after = 0.1, command = 'SendMIDI "Note" 10/36 0', name = "note off" },
            },
            -- A CSV Destination's DMX is Art-Net, as in the Mac app: universe 2 is MA3 universe 3.
            {
                time = "01:01:00:00", song = "Intro", phase = "stop", destination = { dmx_for = "MA3" },
                command = "DMXUniverse 3.101 At Decimal8 255",
                release = { after = 0.5, command = "Off DMXUniverse 3.101", name = "DMX release" },
            },
        }, result.events)
    end)

    it("reports Action rows it can't use, keeping the Song", function()
        local result = plan.fromCSV(table.concat({
            ",,,Res,osc,/orphan",
            "A,01:00:00:00,01:01:00:00,Res,osc,/a",
            ",,,,osc,/a",
            ",,,Res,video,/a",
            ",,,Res,osc,no-slash",
            ',,,Res,osc,/a,"""open"',
            ",,,MA3,midi-note,17/1",
            ",,,MA3,midi-note,60,0",
            ",,,MA3,dmx,1",
            ",,,MA3,dmx,1.513",
            ",,,MA3,dmx,1.1,256",
            ",,,Res,osc,/a,,later",
            ',,,Res,osc,/a,"""a,b"""',
            "B,01:00:30:00,01:02:00:00",
            ",,,Res,osc,/b",
        }, "\n"))
        assert.same({
            "line 1: no Song above to add the Action to",
            "line 3: the Action has no destination",
            'line 4: kind "video" is not osc, midi-note or dmx',
            'line 5: "no-slash" is not an OSC address',
            'line 6: arguments ""open" have an unterminated quote',
            'line 7: note "17/1" is not a note (60, or channel/note as 10/36)',
            'line 8: velocity "0" is not 1-127',
            'line 9: "1" is not universe.channel (channel 1-512)',
            'line 10: "1.513" is not universe.channel (channel 1-512)',
            'line 11: value "256" is not 0-255',
            'line 12: when "later" is not start or stop',
            'line 13: the OSC string "a,b" contains a comma or quote, which SendOSC can\'t send',
            'line 14: overlaps "A"',
        }, result.warnings)
        assert.equal(1, #result.events)
    end)

    it("plans the example Set written as CSV the same as its .trigit file", function()
        local result = plan.fromCSV(table.concat({
            "name,start,end,destination,kind,address,args",
            "Intro,01:00:00:00,01:04:00:00,Resolume,osc,/composition/columns/1/connect,1",
            "DJ Pull-up,02:00:00:00,02:01:30:00",
        }, "\n"))
        assert.same(examplePlan.events, result.events)
        assert.same({}, result.warnings)
    end)
end)

describe("frame rates", function()
    local function stopTime(endTime, rate)
        local result = plan.fromCSV("A,00:00:00:00," .. endTime .. ",D,osc,/a,,stop", { frameRate = rate })
        return result.events[1].time
    end

    it("puts Stop Actions on the frame after the end, at the Set's frame rate", function()
        assert.equal("00:00:01:00", stopTime("00:00:00:24", "25"))
        assert.equal("00:00:00:25", stopTime("00:00:00:24", "30"))
        assert.equal("01:00:00:00", stopTime("00:59:59:23", "24"))
        assert.equal("00:00:00:00", stopTime("23:59:59:29", "30"))
        -- Drop-frame skips frames 0 and 1 except every tenth minute.
        assert.equal("00:01:00:02", stopTime("00:00:59:29", "29.97 DF"))
        assert.equal("00:10:00:00", stopTime("00:09:59:29", "29.97 DF"))
    end)

    it("warns about frames past the frame rate and refuses unknown rates", function()
        assert.same({ "line 1: 00:00:01:27 has frame 27, past the last frame at 25 fps" },
            plan.fromCSV("A,00:00:00:00,00:00:01:27", { frameRate = "25" }).warnings)
        assert.has_error(function() plan.fromCSV("", { frameRate = "50" }) end,
            'frame rate "50" is not 24, 25, 29.97 DF or 30')
    end)
end)
