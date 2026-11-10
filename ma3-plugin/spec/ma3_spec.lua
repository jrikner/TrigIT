-- SPDX-License-Identifier: GPL-3.0-or-later
local ma3 = require("ma3")
local plan = require("trigit_plan")

describe("ma3.seconds", function()
    it("counts timecode as seconds at the frame rate", function()
        assert.equal(3600, ma3.seconds("01:00:00:00", "30"))
        assert.equal(3600.5, ma3.seconds("01:00:00:15", "30"))
        assert.equal(3600.5, ma3.seconds("01:00:00:12", "24"))
        assert.equal(61.6, ma3.seconds("00:01:01:15", "25"))
    end)

    it("counts drop-frame timecode in real time", function()
        -- 00:01:00:02 is frame 1800, the first after the dropped 00 and 01.
        assert.near(1800 * 1001 / 30000, ma3.seconds("00:01:00:02", "29.97 DF"), 1e-9)
        -- One hour of drop-frame timecode is 3600 real seconds, to within a few frames.
        assert.near(3600, ma3.seconds("01:00:00:00", "29.97 DF"), 0.004)
    end)
end)

describe("ma3.cues", function()
    it("makes one cue per moment, with the OSC line put in and Note Offs after", function()
        local result = plan.fromCSV(table.concat({
            "Intro,01:00:00:00,01:00:59:29,Resolume,osc,/composition/columns/1/connect,1",
            ",,,Resolume,osc,/layer/clear",
            ",,,MA3,midi-note,10/36,100,stop",
            "Outro,01:02:00:00,01:03:00:00,Resolume,osc,/composition/columns/2/connect,1",
        }, "\n"))
        assert.same({
            {
                seconds = 3600, name = "Intro start",
                command = 'SendOSC 3 "/composition/columns/1/connect,i,1"; SendOSC 3 "/layer/clear,"',
            },
            { seconds = 3660, name = "Intro stop", command = 'SendMIDI "Note" 10/36 100' },
            { seconds = 3660.1, name = "Intro note off", command = 'SendMIDI "Note" 10/36 0' },
            { seconds = 3720, name = "Outro start", command = 'SendOSC 3 "/composition/columns/2/connect,i,1"' },
        }, ma3.cues(result, { Resolume = 3 }))
    end)

    it("releases a DMX pulse in its own cue after the pulse's duration", function()
        local result = plan.fromCSV("A,00:00:01:00,00:00:02:00,Lights,dmx,0.7,128")
        assert.same({ { seconds = 1, name = "A start", command = "DMXUniverse 1.7 At Decimal8 128" },
                      { seconds = 1.5, name = "A DMX release", command = "Off DMXUniverse 1.7" } },
            ma3.cues(result, {}))
    end)

    it("leaves out OSC events for Destinations with no line", function()
        local result = plan.fromCSV("A,00:00:01:00,00:00:02:00,Resolume,osc,/a\n,,,MA3,midi-note,60")
        assert.same({ { seconds = 1, name = "A start", command = 'SendMIDI "Note" 1/60 127' },
                      { seconds = 1.1, name = "A note off", command = 'SendMIDI "Note" 1/60 0' } },
            ma3.cues(result, {}))
    end)
end)
