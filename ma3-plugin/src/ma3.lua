-- SPDX-License-Identifier: GPL-3.0-or-later
-- The pure part of the grandMA3 adapter: turns a plan into the cues the
-- adapter writes (one per moment, with their commands), so it can be tested
-- without a console. No MA API calls.

local ma3 = {}

local FRAMES = { ["24"] = 24, ["25"] = 25, ["29.97 DF"] = 30, ["30"] = 30 }

-- Seconds from 00:00:00:00 at `rate`, as the Timecode Show's timeline counts.
-- Drop-frame counts real time: frame numbers 0 and 1 are skipped at every
-- minute except each tenth, and frames run at 30000/1001 a second.
function ma3.seconds(timecode, rate)
    local h, m, s, f = timecode:match("^(%d+):(%d+):(%d+):(%d+)$")
    h, m, s, f = tonumber(h), tonumber(m), tonumber(s), tonumber(f)
    if rate == "29.97 DF" then
        local minutes = h * 60 + m
        local frames = (minutes * 60 + s) * 30 + f - 2 * (minutes - minutes // 10)
        return frames * 1001 / 30000
    end
    return h * 3600 + m * 60 + s + f / FRAMES[rate]
end

-- The cues for a plan, in time order: { seconds, name, command }. Events at
-- the same moment share a cue, their commands joined with "; " in plan order.
-- A release (a MIDI Note Off) becomes its own moment `after` seconds later.
-- `lines` maps a Destination's name to its In & Out OSC line number; events
-- for an OSC Destination without one are left out.
function ma3.cues(plan, lines)
    local cues, byMoment = {}, {}
    local function add(seconds, name, command)
        local key = ("%.4f"):format(seconds)
        local cue = byMoment[key]
        if not cue then
            cue = { seconds = seconds, name = name, commands = {} }
            byMoment[key] = cue
            cues[#cues + 1] = cue
        end
        cue.commands[#cue.commands + 1] = command
    end

    for _, event in ipairs(plan.events) do
        local command, line = event.command, event.destination.osc_line_for and lines[event.destination.osc_line_for]
        if line then command = command:gsub("%$line", tostring(line), 1) end
        if line or not event.destination.osc_line_for then
            local seconds = ma3.seconds(event.time, plan.frameRate)
            add(seconds, event.song .. " " .. event.phase, command)
            if event.release then add(seconds + event.release.after, event.song .. " note off", event.release.command) end
        end
    end

    table.sort(cues, function(a, b) return a.seconds < b.seconds end)
    for _, cue in ipairs(cues) do
        cue.command, cue.commands = table.concat(cue.commands, "; "), nil
    end
    return cues
end

return ma3
