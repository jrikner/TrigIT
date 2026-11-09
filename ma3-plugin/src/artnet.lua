-- SPDX-License-Identifier: GPL-3.0-or-later
-- Art-Net 4 ArtTimeCode packets, as Sources/TrigITProtocols/ArtNetTimecode.swift
-- writes them, for bridge mode: the TrigIT Mac app follows them as an Art-Net
-- Timecode Source.

local artnet = {}

artnet.PORT = 6454
local TYPE = { ["24"] = 0, ["25"] = 1, ["29.97 DF"] = 2, ["30"] = 3 }

-- The 19-byte packet for `position` ("hh:mm:ss:ff") at `rate`, on stream 0.
function artnet.timecode(position, rate)
    local h, m, s, f = position:match("^(%d+):(%d+):(%d+):(%d+)$")
    return "Art-Net\0" .. string.char(0x00, 0x97, 0x00, 14, 0x00, 0x00,
        tonumber(f), tonumber(s), tonumber(m), tonumber(h), TYPE[rate])
end

return artnet
