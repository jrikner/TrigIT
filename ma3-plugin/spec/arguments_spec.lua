-- SPDX-License-Identifier: GPL-3.0-or-later
local arguments = require("arguments")

describe("plugin arguments", function()
    it("opens the panel with no argument", function()
        assert.same({ verb = "open" }, arguments.parse(nil))
        assert.same({ verb = "open" }, arguments.parse("  "))
    end)

    it("reads the plain commands, in any case", function()
        for _, verb in ipairs({ "open", "start", "arm", "disarm", "toggle", "stop", "quit" }) do
            assert.same({ verb = verb }, arguments.parse(" " .. verb:upper() .. " "))
        end
    end)

    it("keeps a Song name as written, with or without quotes", function()
        assert.same({ verb = "fire", song = "DJ Pull-up" }, arguments.parse("Fire DJ Pull-up"))
        assert.same({ verb = "fire", song = "Intro" }, arguments.parse('fire "Intro"'))
    end)

    it("reads a screen number", function()
        assert.same({ verb = "screen", screen = 2 }, arguments.parse("Screen 2"))
        local result, why = arguments.parse("screen two")
        assert.is_nil(result)
        assert.matches("needs a screen number", why)
        assert.is_nil(arguments.parse("screen 0"))
    end)

    it("says what it accepts", function()
        local result, why = arguments.parse("fire")
        assert.is_nil(result)
        assert.matches("needs a Song name", why)
        result, why = arguments.parse("arm now")
        assert.is_nil(result)
        assert.matches("not a TrigIT command", why)
        assert.matches("fire <Song>", why)
    end)
end)
