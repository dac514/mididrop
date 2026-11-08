--[[
  Dropper wire format. Run with `just test tests/wire_test.lua`.
]]

local t = require "tests.helper"
local wire = require "src.wire"

local frame = wire.encode { kind = "drop", name = "a.mid", data = "MThd\0\n\255" }
t.eq(frame:match "^(%d+)\n", tostring(#frame - #frame:match "^%d+\n"), "length prefix")
t.check(frame:find("kind 4\ndrop", 1, true) ~= nil, "kind encoded first")

local records, err = wire.decode(frame)
t.eq(err, nil, "no error")
t.eq(records and records.kind, "drop", "kind")
t.eq(records and records.name, "a.mid", "name")
t.eq(records and records.data, "MThd\0\n\255", "binary data with newline survives")

-- Incomplete frames wait for more bytes.
for cut = 0, #frame - 1 do
  local r, e = wire.decode(frame:sub(1, cut))
  if r ~= nil or e ~= nil then
    t.check(false, "partial frame at " .. cut .. " should wait")
    break
  end
end
t.check(true, "partial frames wait")

-- Status sorts first in replies.
t.eq(wire.encode { status = "ok", a = "1" }, "16\nstatus 2\noka 1\n1", "status first")
t.eq(wire.encode { kind = "shutdown" }, "15\nkind 8\nshutdown", "shutdown signal")
t.eq(wire.encode {}, "0\n", "empty frame")
local empty = wire.decode "0\n"
t.check(empty ~= nil and next(empty) == nil, "empty frame decodes")

-- Errors.
local _, e1 = wire.decode "nonsense-without-a-newline-at-all"
t.eq(e1, "bad frame header", "missing header")
local _, e2 = wire.decode "x\n"
t.eq(e2, "bad frame header", "non-numeric header")
local _, e3 = wire.decode "5\nab cd"
t.eq(e3, "bad record header", "bad record")
local _, e4 = wire.decode "8\nab 99\nxx"
t.eq(e4, "record overruns frame", "record longer than frame")
local _, e5 = wire.decode(("%d\n"):format(wire.MAX_FRAME + 1))
t.eq(e5, "frame too large", "oversized frame")

t.done()
