-- SPDX-License-Identifier: GPL-3.0-or-later
-- What the panel shows, from a Set and a running show fed timecode.

local live = require("live")
local ma3 = require("ma3")
local view = require("view")

local function set()
    return {
        destinations = {},
        songs = {
            { id = "2", name = "Outro", start = "01:05:00:00", ["end"] = "01:06:00:00", startActions = {}, stopActions = {} },
            { id = "1", name = "Intro", start = "01:00:00:00", ["end"] = "01:04:00:00", startActions = {}, stopActions = {} },
            { id = "3", name = "Pull-up", startActions = {}, stopActions = {} },
        },
    }
end

local function play(show, from, frames, now)
    local start = ma3.seconds(from, "25")
    for i = 0, frames - 1 do
        show:follow(start + i / 25, now + i / 25)
        show:tick(now + i / 25)
    end
end

describe("the panel's view", function()
    it("shows nothing running before timecode", function()
        local model = view.model(set(), live.new(set(), "25", function() end, false), "25")
        assert.is_nil(model.playhead)
        assert.is_nil(model.song)
        assert.is_nil(model.next)
        assert.is_false(model.armed)
        assert.same({ "Outro", "Intro", "Pull-up" }, { model.songs[1].name, model.songs[2].name, model.songs[3].name })
        assert.same("notes only", model.songs[3].span)
    end)

    it("counts down to the nearest next Song, whatever the Set's order", function()
        local show = live.new(set(), "25", function() end, false)
        play(show, "00:59:58:00", 2, 1000)
        local model = view.model(set(), show, "25")
        assert.same("Intro starts in 0:02", model.next)
        assert.is_nil(model.song)
    end)

    it("shows the current Song, how far into it, and marks it fired", function()
        local show = live.new(set(), "25", function() end, true)
        play(show, "01:01:23:00", 3, 1000)
        local model = view.model(set(), show, "25")
        assert.same("Intro", model.song)
        assert.same("1:23 of 4:00", model.progress)
        assert.same("Outro starts in 3:37", model.next)
        assert.is_true(model.armed)
        assert.is_true(model.songs[2].current and model.songs[2].fired)
        assert.is_false(model.songs[1].current or model.songs[1].fired)
        assert.same("Intro entered", model.log[1].text)
        assert.is_false(model.log[1].failed)
    end)

    it("writes long times with hours", function()
        assert.same("1:02:03", view.clock(3723))
        assert.same("0:00", view.clock(-4))
    end)
end)
