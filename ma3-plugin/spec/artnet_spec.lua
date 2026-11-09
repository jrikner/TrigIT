-- SPDX-License-Identifier: GPL-3.0-or-later
local artnet = require("artnet")

describe("ArtTimeCode", function()
    it("matches the Art-Net 4 reference packet the Swift tests use", function()
        -- Tests/TrigITProtocolsTests/ArtNetTimecodeTests.swift: 01:37:52:16 at 25 fps.
        local reference = string.char(0x41, 0x72, 0x74, 0x2D, 0x4E, 0x65, 0x74, 0x00, 0x00, 0x97, 0x00, 0x0E,
            0x00, 0x00, 0x10, 0x34, 0x25, 0x01, 0x01)
        assert.equal(reference, artnet.timecode("01:37:52:16", "25"))
    end)

    it("writes each rate's type", function()
        for rate, type in pairs({ ["24"] = 0, ["25"] = 1, ["29.97 DF"] = 2, ["30"] = 3 }) do
            assert.equal(type, artnet.timecode("00:00:00:00", rate):byte(19))
        end
    end)
end)
