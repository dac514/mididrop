--[[
  Drop window program facts. Run with `just test tests/drop_window_test.lua`.
]]

local t = require "tests.helper"
local dw = require "src.drop_window"

t.eq(dw.download("WINDOWS").file, "midi-drop-windows-x86_64.zip", "windows file")
t.eq(dw.download("MACINTOSH").file, "midi-drop-macos-universal.zip", "mac file")
t.eq(dw.download("LINUX").file, "midi-drop-linux-x86_64.tar.gz", "linux file")
t.eq(dw.download("SOMETHING").file, "midi-drop-linux-x86_64.tar.gz", "unknown platform")
for _, platform in ipairs { "WINDOWS", "MACINTOSH", "LINUX" } do
  local d = dw.download(platform)
  t.check(d.unpack ~= "" and d.first_open ~= "", "steps for " .. platform)
end
t.check(dw.RELEASES_URL:find "^https://github.com/dac514/mididrop/releases" ~= nil, "url")

t.eq(
  dw.app_bundle "/Applications/MIDI Drop.app/Contents/MacOS/midi-drop",
  "/Applications/MIDI Drop.app",
  "bundle from program"
)
t.eq(dw.app_bundle "/Applications/MIDI Drop.app", "/Applications/MIDI Drop.app", "bundle itself")
t.eq(
  dw.app_bundle "/Applications/MIDI Drop.app/",
  "/Applications/MIDI Drop.app",
  "bundle trailing slash"
)
t.eq(dw.app_bundle "/home/me/bin/midi-drop", nil, "not a bundle")

local mac_exe = "/Users/me/Applications/MIDI Drop.app/Contents/MacOS/midi-drop"
t.eq(
  dw.remembered_path(mac_exe, "MACINTOSH"),
  "/Users/me/Applications/MIDI Drop.app",
  "mac remembers the bundle"
)
t.eq(
  dw.remembered_path(
    "/private/var/folders/xy/T/AppTranslocation/1234/d/MIDI Drop.app/Contents/MacOS/midi-drop",
    "MACINTOSH"
  ),
  nil,
  "mac skips a translocated copy"
)
t.eq(
  dw.remembered_path([[C:\Tools\MIDI Drop\midi-drop.exe]], "WINDOWS"),
  [[C:\Tools\MIDI Drop\midi-drop.exe]],
  "windows path"
)
t.eq(
  dw.remembered_path("/home/me/.local/bin/midi-drop", "LINUX"),
  "/home/me/.local/bin/midi-drop",
  "linux path"
)
t.eq(
  dw.remembered_path(
    [[C:\Users\Me\AppData\Local\Temp\Temp1_midi-drop-windows-x86_64.zip\midi-drop.exe]],
    "WINDOWS"
  ),
  nil,
  "windows skips a program run from inside a zip"
)
t.eq(
  dw.remembered_path([[C:\Users\Me\APPDATA\LOCAL\TEMP\7zO1234\midi-drop.exe]], "WINDOWS"),
  nil,
  "windows skips any Temp copy, any case"
)
t.eq(
  dw.remembered_path([[C:\Users\Me\Downloads\midi-drop\midi-drop.exe]], "WINDOWS"),
  [[C:\Users\Me\Downloads\midi-drop\midi-drop.exe]],
  "windows keeps an unpacked program in Downloads"
)
t.eq(
  dw.remembered_path("/home/me/.local/bin/midi-drop (deleted)", "LINUX"),
  "/home/me/.local/bin/midi-drop",
  "linux strips (deleted) from a replaced program"
)
t.eq(dw.remembered_path("", "LINUX"), nil, "empty")
t.eq(dw.remembered_path(nil, "WINDOWS"), nil, "missing (older drop window)")

t.done()
