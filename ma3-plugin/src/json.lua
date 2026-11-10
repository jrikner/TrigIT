-- SPDX-License-Identifier: GPL-3.0-or-later
-- A small JSON decoder: enough for .trigit Set files, in plain Lua 5.4.
-- null decodes as nil. Errors are raised with the byte position.

local json = {}

local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

function json.decode(text)
    local pos = 1
    local function fail(what) error(("%s at byte %d"):format(what, pos), 0) end
    local function skip() pos = text:find("[^ \t\r\n]", pos) or #text + 1 end
    local function peek() return text:sub(pos, pos) end

    local function str()
        pos = pos + 1
        local parts = {}
        while true do
            local at = text:find('["\\]', pos)
            if not at then fail("unterminated string") end
            parts[#parts + 1] = text:sub(pos, at - 1)
            if text:sub(at, at) == '"' then
                pos = at + 1
                return table.concat(parts)
            end
            local c = text:sub(at + 1, at + 1)
            if c == "u" then
                local hex = text:match("^%x%x%x%x", at + 2) or fail("bad \\u escape")
                local code = tonumber(hex, 16)
                pos = at + 6
                local low = code >= 0xD800 and code <= 0xDBFF and text:match("^\\u(%x%x%x%x)", pos)
                if low then
                    code = 0x10000 + (code - 0xD800) * 0x400 + (tonumber(low, 16) - 0xDC00)
                    pos = pos + 6
                end
                parts[#parts + 1] = utf8.char(code)
            else
                parts[#parts + 1] = escapes[c] or fail("bad escape")
                pos = at + 2
            end
        end
    end

    local value
    local function list(close, item)
        pos = pos + 1
        skip()
        if peek() == close then pos = pos + 1 return end
        while true do
            item()
            skip()
            local c = peek()
            pos = pos + 1
            if c == close then return end
            if c ~= "," then fail("expected ',' or '" .. close .. "'") end
        end
    end

    function value()
        skip()
        local c = peek()
        if c == "{" then
            local object = {}
            list("}", function()
                skip()
                if peek() ~= '"' then fail("expected a key") end
                local key = str()
                skip()
                if peek() ~= ":" then fail("expected ':'") end
                pos = pos + 1
                object[key] = value()
            end)
            return object
        elseif c == "[" then
            local array, n = {}, 0
            list("]", function() n = n + 1; array[n] = value() end)
            return array
        elseif c == '"' then
            return str()
        end
        for word, result in pairs({ ["true"] = true, ["false"] = false, null = json }) do
            if text:sub(pos, pos + #word - 1) == word then
                pos = pos + #word
                if result == json then return nil end
                return result
            end
        end
        local number = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        if not number or not tonumber(number) then fail("unexpected character") end
        pos = pos + #number
        return tonumber(number)
    end

    local result = value()
    skip()
    if pos <= #text then fail("trailing characters") end
    return result
end

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

-- Pretty JSON with sorted keys, as SetFile.swift writes it. A table with
-- keys 1..n is an array; an empty table is an empty array (in a Set file
-- every empty collection is one). Integers stay integers.
function json.encode(value, indent)
    indent = indent or ""
    local kind = type(value)
    if kind == "string" then
        return '"' .. value:gsub('[%c"\\]', function(c) return ESCAPES[c] or ("\\u%04x"):format(c:byte()) end) .. '"'
    elseif kind == "number" then
        if math.type(value) == "integer" then return tostring(value) end
        assert(value == value and value ~= math.huge and value ~= -math.huge, "JSON has no NaN or infinity")
        return value == math.floor(value) and ("%.1f"):format(value) or ("%.17g"):format(value)
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind ~= "table" then
        error("can't write a " .. kind .. " as JSON")
    end
    local inner = indent .. "  "
    if next(value) == nil then return "[]" end
    if #value > 0 then
        local items = {}
        for i, item in ipairs(value) do items[i] = inner .. json.encode(item, inner) end
        return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "]"
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = assert(type(key) == "string" and key, "JSON object keys must be strings") end
    table.sort(keys)
    local items = {}
    for i, key in ipairs(keys) do items[i] = inner .. json.encode(key) .. " : " .. json.encode(value[key], inner) end
    return "{\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "}"
end

return json
