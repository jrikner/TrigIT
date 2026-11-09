-- SPDX-License-Identifier: GPL-3.0-or-later
-- The text after `Plugin <n>` (#98), as in `Plugin TrigIT "fire Intro"`.
-- parse(text) returns { verb = ..., song = ... }, or nil and what it accepts.
-- Pure Lua, no MA calls.

local M = {}

M.USAGE = 'TrigIT accepts: "open", "start", "arm", "disarm", "toggle", "fire <Song>", "stop", "quit"'

local PLAIN = { open = true, start = true, arm = true, disarm = true, toggle = true, stop = true, quit = true }

function M.parse(text)
    text = (text or ""):match("^%s*(.-)%s*$")
    if text == "" then return { verb = "open" } end
    local verb, rest = text:match("^(%S+)%s*(.*)$")
    verb = verb:lower()
    if verb == "fire" then
        local song = rest:match('^"(.*)"$') or rest
        if song == "" then return nil, 'fire needs a Song name, as in "fire Intro"' end
        return { verb = "fire", song = song }
    end
    if PLAIN[verb] and rest == "" then return { verb = verb } end
    return nil, ('"%s" is not a TrigIT command. %s'):format(text, M.USAGE)
end

return M
