-- SPDX-License-Identifier: GPL-3.0-or-later
-- Every grandMA3 command the plugin writes is formatted here and nowhere else.
-- Checked on grandMA3 onPC 2.5.1 against the bytes that arrive (see README.md);
-- not yet on a console (spike #43).

local commands = {}

-- The adapter replaces this with the In & Out OSC line the Destination maps to.
commands.OSC_LINE = "$line"

-- How long a MIDI note is held, as the Mac app does (MIDIOutput.noteLength).
commands.NOTE_LENGTH = 0.1

local function number(value)
    return math.type(value) == "integer" and tostring(value) or ("%.9g"):format(value)
end

-- SendOSC <line> "/address,<type tags>,<arg>,<arg>". With no arguments it is
-- "/address," (MA3 refuses a bare address), which sends the same bytes as the
-- Mac app. Returns nil and a reason for strings SendOSC can't carry: a comma
-- splits the argument and a quote ends the command's string.
function commands.osc(message)
    local tags, args = {}, {}
    for _, argument in ipairs(message.arguments) do
        if argument.int then
            tags[#tags + 1], args[#args + 1] = "i", number(argument.int)
        elseif argument.float then
            tags[#tags + 1], args[#args + 1] = "f", number(argument.float)
        else
            if argument.string:find('[,"]') then
                return nil, ('the OSC string %q contains a comma or quote, which SendOSC can\'t send'):format(argument.string)
            end
            tags[#tags + 1], args[#args + 1] = "s", argument.string
        end
    end
    local body = message.address .. "," .. table.concat(tags)
    if #args > 0 then body = body .. "," .. table.concat(args, ",") end
    return ('SendOSC %s "%s"'):format(commands.OSC_LINE, body)
end

-- SendMIDI "Note" <channel 1-16>/<note> <velocity>, then velocity 0 (Note Off)
-- after NOTE_LENGTH. MA3 sends it on the console's MIDI output.
function commands.midiNote(note)
    local function send(velocity) return ('SendMIDI "Note" %d/%d %d'):format(note.channel + 1, note.note, velocity) end
    return send(note.velocity), { after = commands.NOTE_LENGTH, command = send(0) }
end

return commands
