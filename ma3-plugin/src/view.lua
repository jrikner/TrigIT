-- SPDX-License-Identifier: GPL-3.0-or-later
-- What the panel shows (#97), worked out from the Set and the running show
-- (live.lua), in the Mac app's words. Pure Lua, no MA calls.

local timecode = require("timecode")

local view = {}

local function seconds(text, rate) return timecode.index(text, rate) / timecode.RATES[rate].real end

-- 83 -> "1:23", 3723 -> "1:02:03"
function view.clock(s)
    s = math.max(0, math.floor(s + 0.5))
    if s >= 3600 then return ("%d:%02d:%02d"):format(s // 3600, s // 60 % 60, s % 60) end
    return ("%d:%02d"):format(s // 60, s % 60)
end

-- `set` as trigit_plan.readSet gives it, `show` a live.new object or nil,
-- `rate` one of timecode.RATES.
function view.model(set, show, rate)
    local engine = show and show.engine
    local model = { playhead = engine and engine.playhead, armed = engine and engine.isArmed or false, songs = {}, log = {} }
    local now = model.playhead and seconds(model.playhead, rate)
    local current, nextStart = engine and engine.currentSong, nil
    for _, song in ipairs(set and set.songs or {}) do
        local start = song.start and seconds(song.start, rate)
        model.songs[#model.songs + 1] = {
            id = song.id, name = song.name,
            span = song.start and (song.start .. " - " .. song["end"]) or "notes only",
            current = song.id == current, fired = show ~= nil and show.fired[song.id] == true,
        }
        if song.id == current then
            model.song = song.name
            if now and start then
                model.progress = ("%s of %s"):format(view.clock(now - start), view.clock(seconds(song["end"], rate) - start))
            end
        end
        if now and start and start > now and (not nextStart or start < nextStart) then
            nextStart = start
            model.next = ("%s starts in %s"):format(song.name, view.clock(start - now))
        end
    end
    for _, entry in ipairs(show and show.log or {}) do
        model.log[#model.log + 1] = { time = entry.time, text = entry.text, failed = entry.failed == true }
    end
    return model
end

return view
