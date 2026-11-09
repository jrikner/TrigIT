-- SPDX-License-Identifier: GPL-3.0-or-later
-- Timecode as "hh:mm:ss:ff" strings, two digits a field, so they compare as
-- strings in time order. Frame counting as Sources/TrigITProtocols/TimecodeFields.swift.

local timecode = {}

-- Frames counted per timecode second, and per second of real time.
timecode.RATES = {
    ["24"] = { nominal = 24, real = 24 },
    ["25"] = { nominal = 25, real = 25 },
    ["29.97 DF"] = { nominal = 30, real = 30000 / 1001, dropFrame = true },
    ["30"] = { nominal = 30, real = 30 },
}

local function fields(text)
    local h, m, s, f = text:match("^(%d+):(%d+):(%d+):(%d+)$")
    return tonumber(h), tonumber(m), tonumber(s), tonumber(f)
end

-- Frames since 00:00:00:00. Drop-frame skips frame numbers 0 and 1 at the
-- start of every minute except each tenth.
function timecode.index(text, rate)
    local h, m, s, f = fields(text)
    local info = timecode.RATES[rate]
    local nominal = ((h * 60 + m) * 60 + s) * info.nominal + f
    if not info.dropFrame then return nominal end
    local minutes = h * 60 + m
    return nominal - 2 * (minutes - minutes // 10)
end

-- The timecode `index` frames after 00:00:00:00, wrapping at 24 hours.
function timecode.fromIndex(index, rate)
    local info = timecode.RATES[rate]
    local fps = info.nominal
    local day = info.dropFrame and 24 * 6 * 17982 or 24 * 3600 * fps
    local n = index % day
    if info.dropFrame then
        local blocks, remainder = n // 17982, n % 17982
        n = n + 18 * blocks + (remainder < 2 and 0 or 2 * ((remainder - 2) // 1798))
    end
    return ("%02d:%02d:%02d:%02d"):format(n // (3600 * fps), (n // (60 * fps)) % 60, (n // fps) % 60, n % fps)
end

return timecode
