--[[
  Bridge home ports. Run with `just test tests/home_port_test.lua`.
  The expected numbers come from `home_port()` in scripts/renoise.py: both
  sides must agree, or the CLI looks for the bridge on the wrong port.
]]

local t = require "tests.helper"
local home_port = require "dev.home_port"

t.eq(home_port.for_tool "com.dac514.MidiDrop", 18867, "MidiDrop")
t.eq(home_port.for_tool "com.dac514.AsciiDancer", 18912, "AsciiDancer")
t.eq(home_port.for_tool "com.example.MyTool", 18946, "template placeholder")

local p = home_port.for_tool "x"
t.check(p >= home_port.BASE and p < home_port.BASE + home_port.SPAN, "inside the range")

t.eq(
  home_port.tool_id "/home/me/Tools/com.dac514.MidiDrop.xrnx/",
  "com.dac514.MidiDrop",
  "posix path"
)
t.eq(
  home_port.tool_id [[C:\Users\me\Tools\com.dac514.MidiDrop.xrnx\]],
  "com.dac514.MidiDrop",
  "windows path"
)
t.eq(
  home_port.tool_id "/home/me/Tools/com.dac514.MidiDrop.xrnx",
  "com.dac514.MidiDrop",
  "no trailing slash"
)
t.eq(home_port.tool_id "/home/me/elsewhere/", nil, "not a bundle")

t.done()
