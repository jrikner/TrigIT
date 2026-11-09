-- SPDX-License-Identifier: GPL-3.0-or-later
local json = require("json")

describe("json.decode", function()
    it("reads objects, arrays, numbers, booleans and null", function()
        assert.same({ a = { 1, -2.5, 3e2 }, b = true, c = false, d = { x = {} } },
            json.decode(' { "a" : [1, -2.5, 3e2], "b": true, "c":false, "d": {"x": []}, "e": null } '))
        assert.equal(7000, json.decode("7000"))
        assert.equal("integer", math.type(json.decode("7000")))
    end)

    it("unescapes strings, including \\u and surrogate pairs", function()
        assert.equal('a"b\\c/d\n\t', json.decode('"a\\"b\\\\c\\/d\\n\\t"'))
        assert.equal("é✨😀", json.decode('"\\u00e9\\u2728\\ud83d\\ude00"'))
        assert.equal("Intro ✨", json.decode('"Intro ✨"'))
    end)

    it("refuses malformed JSON", function()
        for _, text in ipairs({ "", "{", '{"a" 1}', "[1,]", '"open', "tru", "[1] 2", "{'a': 1}" }) do
            assert.has_error(function() json.decode(text) end, nil, text)
        end
    end)
end)
