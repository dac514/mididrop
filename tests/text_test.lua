--[[
  Monitor and status text. Run with `just test tests/text_test.lua`.
]]

local t = require "tests.helper"
local text = require "src.text"

t.eq(text.basename "/tmp/x/clip.mid", "clip.mid", "basename posix")
t.eq(text.basename [[C:\Users\me\AppData\Local\Temp\clip.mid]], "clip.mid", "basename windows")
t.eq(text.basename "clip.mid", "clip.mid", "basename bare")

t.eq(text.ellipsize("short.mid", 20), "short.mid", "ellipsize keeps short names")
t.eq(text.ellipsize("abcdefghijklmnopqrstuvwxyz.mid", 20), "abcdefghijkl...z.mid", "ellipsize long")
t.eq(#text.ellipsize(("x"):rep(100), 48), 48, "ellipsize length")

t.eq(text.mode "pattern", "Pattern editor", "mode pattern")
t.eq(text.mode "phrase", "Phrase editor", "mode phrase")
t.eq(text.mode(nil), "-", "mode none")

t.eq(text.track(2, "Bass"), "02  Bass", "track")
t.eq(text.track(nil, nil), "-", "no track")
t.eq(text.instrument(1, "Piano"), "00  Piano", "instrument is 0-based")
t.eq(text.instrument(17, ""), "10  (untitled)", "instrument hex, untitled")

t.eq(
  text.position { mode = "pattern", seq = 2, pattern = 5, line = 17 },
  "Seq 01  ·  Pattern 04  ·  Line 016",
  "pattern position is 0-based like Renoise"
)
t.eq(
  text.position { mode = "phrase", phrase = 3, line = 1 },
  "Phrase 03  ·  Line 000",
  "phrase position"
)
t.eq(text.position(nil), "-", "no position")

t.eq(text.tempo(126, 8, false), "8 LPB  ·  126 BPM", "tempo")
t.eq(text.tempo(128.5, 4, true), "4 LPB (phrase)  ·  128.5 BPM", "phrase lpb")
t.eq(text.tempo(nil, nil), "-", "no tempo")

local quiet = { lpb_automated = false, bpm_automated = false, lpb_commands = 0, bpm_commands = 0 }
t.eq(text.automation(quiet), nil, "no automation")
t.check(
  text
    .automation({ lpb_automated = true, bpm_automated = false, lpb_commands = 0, bpm_commands = 0 })
    :find "LPB",
  "lpb automation"
)
t.check(
  text
    .automation({ lpb_automated = false, bpm_automated = false, lpb_commands = 2, bpm_commands = 0 })
    :find "LPB",
  "lpb commands"
)
t.check(
  text
    .automation({ lpb_automated = false, bpm_automated = true, lpb_commands = 0, bpm_commands = 0 })
    :find "BPM",
  "bpm automation"
)

---@return Placement
local function placement(over)
  local p = {
    cells = {},
    lines_used = 32,
    columns_used = 4,
    notes_placed = 48,
    dropped = 0,
    cut = 0,
    out_of_range = 0,
    uses_delay = false,
    uses_volume = false,
  }
  for k, v in pairs(over or {}) do
    p[k] = v
  end
  return p
end

t.eq(text.summary(placement()), "48 notes  ·  4 columns  ·  32 lines", "summary plural")
t.eq(
  text.summary(placement { notes_placed = 1, columns_used = 1, lines_used = 1 }),
  "1 note  ·  1 column  ·  1 line",
  "summary singular"
)

local report = {
  file = "drums.mid",
  placement = placement(),
  where = "Seq 00  ·  Pattern 00  ·  Line 000",
  truncated = 0,
  skipped = 0,
  aliased = false,
  lpb_changes = false,
}
t.eq(#text.warnings(report), 0, "clean drop has no warnings")
t.eq(
  text.status(report),
  "MIDI Drop: drums.mid  →  Seq 00  ·  Pattern 00  ·  Line 000  (48 notes  ·  4 columns  ·  32 lines)",
  "status line"
)

report.placement = placement { dropped = 2, cut = 1, out_of_range = 1 }
report.truncated = 3
report.skipped = 1
report.aliased = true
report.lpb_changes = true
local w = text.warnings(report)
t.eq(#w, 7, "all warnings")
t.eq(w[1], "2 notes dropped: more simultaneous notes than columns", "dropped first")
t.eq(w[2], "3 events did not fit and were cut", "truncated")
t.check(text.status(report):find "2 notes dropped", "status carries first warning")

t.done()
