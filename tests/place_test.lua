--[[
  Note placement. Run with `just test tests/place_test.lua`.
]]

local t = require "tests.helper"
local place = require "src.place"

---@param notes {[1]: integer, [2]: integer, [3]: integer, [4]: integer|nil}[] `{tick, dur, pitch, vel}`
---@param ppq integer|nil
---@param length integer|nil
local function song(notes, ppq, length)
  local list = {}
  for i, n in ipairs(notes) do
    list[i] = { tick = n[1], dur = n[2], pitch = n[3], vel = n[4] or 100, ch = 1 }
  end
  return { notes = list, ppq = ppq or 96, length_ticks = length or 0 }
end

---@param over table|nil
---@return PlaceOptions
local function opts(over)
  local o = { lpb = 4, timing = "delay", note_offs = true, velocity = true, max_columns = 12 }
  for k, v in pairs(over or {}) do
    o[k] = v
  end
  return o
end

---@param p Placement
---@param line integer
---@param column integer
---@return PlacedCell|nil
local function cell(p, line, column)
  for _, c in ipairs(p.cells) do
    if c.line == line and c.column == column then
      return c
    end
  end
  return nil
end

-- Single note on the grid, LPB 4, ppq 96: a 16th note is one line ---------------

do
  local p = place.notes(song { { 0, 24, 60, 100 } }, opts())
  t.eq(#p.cells, 2, "note + off")
  local n = cell(p, 0, 1) --[[@as PlacedCell]]
  t.eq(n.note, 60, "pitch maps straight to note value")
  t.eq(n.volume, 100, "velocity to volume")
  t.eq(n.delay, 0, "on the grid")
  local off = cell(p, 1, 1) --[[@as PlacedCell]]
  t.eq(off.note, place.OFF, "off after one line")
  t.eq(p.lines_used, 2, "lines used")
  t.eq(p.columns_used, 1, "one column")
  t.eq(p.uses_delay, false, "no delay used")
end

-- Velocity 127 leaves the volume empty; velocity off leaves all empty ------------

do
  local p = place.notes(song { { 0, 24, 60, 127 } }, opts())
  t.eq(cell(p, 0, 1).volume, nil, "127 is empty")
  t.eq(p.uses_volume, false, "no volume used")
  p = place.notes(song { { 0, 24, 60, 50 } }, opts { velocity = false })
  t.eq(cell(p, 0, 1).volume, nil, "velocity disabled")
end

-- Delay rounding at LPB 4, 8 and 12 ----------------------------------------------

do
  -- tick 30 at ppq 96: 30/96 beat.
  local p = place.notes(song { { 30, 10, 60 } }, opts { lpb = 4, note_offs = false })
  -- 30 * 4 * 256 / 96 = 320 -> line 1, delay 64
  t.eq(cell(p, 1, 1).delay, 64, "LPB 4 delay")
  p = place.notes(song { { 30, 10, 60 } }, opts { lpb = 8, note_offs = false })
  -- 30 * 8 * 256 / 96 = 640 -> line 2, delay 128
  t.eq(cell(p, 2, 1).delay, 128, "LPB 8 delay")
  p = place.notes(song { { 30, 10, 60 } }, opts { lpb = 12, note_offs = false })
  -- 30 * 12 * 256 / 96 = 960 -> line 3, delay 192
  t.eq(cell(p, 3, 1).delay, 192, "LPB 12 delay")
  t.eq(p.uses_delay, true, "delay used")
  -- ppq 480, tick 1: 1 * 4 * 256 / 480 = 2.13 -> delay 2
  p = place.notes(song({ { 1, 10, 60 } }, 480), opts { note_offs = false })
  t.eq(cell(p, 0, 1).delay, 2, "rounded to nearest 1/256")
end

-- Inverse of MidiConvert's export: time = (line + delay/256) * ppq / lpb ---------

do
  -- Exact when the export lands on a whole tick; otherwise within half a tick.
  local ppq, lpb = 480, 8
  local half_tick = 256 * lpb / ppq / 2
  for _, case in ipairs { { 5, 0 }, { 3, 128 }, { 9, 64 }, { 17, 37 } } do
    local line, delay = case[1], case[2]
    local tick = math.floor((line + delay / 256) * ppq / lpb + 0.5)
    local p = place.notes(song({ { tick, 1, 60 } }, ppq), opts { lpb = lpb, note_offs = false })
    local c = p.cells[1]
    t.eq(c.line, line, "round trip line " .. line)
    t.check(
      math.abs(c.delay - delay) <= half_tick,
      ("round trip delay %d: got %d"):format(delay, c.delay)
    )
  end
  local exact = place.notes(song({ { 1950, 1, 60 } }, ppq), opts { lpb = lpb, note_offs = false })
  -- 1950 ticks = 32.5 lines at 60 ticks per line
  t.eq(exact.cells[1].line, 32, "exact round trip line")
  t.eq(exact.cells[1].delay, 128, "exact round trip delay")
end

-- Snap to line -------------------------------------------------------------------

do
  local p = place.notes(song { { 30, 10, 60 } }, opts { timing = "line" })
  -- 30 * 4 / 96 = 1.25 -> line 1
  local c = cell(p, 1, 1) --[[@as PlacedCell]]
  t.eq(c and c.delay, 0, "snapped, no delay")
  t.eq(cell(p, 2, 1).note, place.OFF, "short note still gets a line before its off")
  t.eq(p.uses_delay, false, "snap uses no delay")
end

-- Chord takes three columns ------------------------------------------------------

do
  local p = place.notes(song { { 0, 96, 48 }, { 0, 96, 55 }, { 0, 96, 60 } }, opts())
  t.eq(p.columns_used, 3, "chord columns")
  t.eq(cell(p, 0, 1).note, 48, "lowest note first")
  t.eq(cell(p, 0, 3).note, 60, "highest note last")
  t.eq(cell(p, 4, 2).note, place.OFF, "offs after one beat")
end

-- Columns are reused once a note has ended ---------------------------------------

do
  local p = place.notes(song { { 0, 24, 60 }, { 48, 24, 62 } }, opts())
  t.eq(p.columns_used, 1, "sequential notes share a column")
  t.eq(cell(p, 1, 1).note, place.OFF, "off between them")
  t.eq(cell(p, 2, 1).note, 62, "second note")
end

-- Legato: the next note cuts the previous, no off needed -------------------------

do
  local p = place.notes(song { { 0, 24, 60 }, { 24, 24, 62 } }, opts())
  t.eq(p.columns_used, 1, "legato in one column")
  t.eq(cell(p, 1, 1).note, 62, "next note at the end")
  t.eq(#p.cells, 3, "two notes and the last off")
end

-- Note-offs disabled ------------------------------------------------------------

do
  local p = place.notes(song { { 0, 24, 60 }, { 48, 24, 62 } }, opts { note_offs = false })
  t.eq(#p.cells, 2, "only notes")
end

-- Off lands on a later line with its delay ---------------------------------------

do
  -- note 0..30 ticks: off at 320/256 = line 1 delay 64
  local p = place.notes(song { { 0, 30, 60 } }, opts())
  local off = cell(p, 1, 1) --[[@as PlacedCell]]
  t.eq(off.note, place.OFF, "off line")
  t.eq(off.delay, 64, "off delay")
end

-- Very short note on one line: off moves to the next line -------------------------

do
  local p = place.notes(song { { 0, 2, 60 } }, opts())
  local off = cell(p, 1, 1) --[[@as PlacedCell]]
  t.eq(off and off.note, place.OFF, "off pushed to next line")
  t.eq(off and off.delay, 0, "pushed off has no delay")
end

-- An off that would share a line with the next note is dropped --------------------

do
  -- note A: line 0, ends at tick 26 (line 1 delay 21); note B starts tick 30 (line 1 delay 64)
  local p = place.notes(song { { 0, 26, 60 }, { 30, 24, 62 } }, opts())
  t.eq(p.columns_used, 1, "same column")
  t.eq(cell(p, 1, 1).note, 62, "next note owns the line")
end

-- Column stealing and dropping when columns run out -------------------------------

do
  local p =
    place.notes(song { { 0, 96, 60 }, { 0, 48, 64 }, { 24, 24, 67 } }, opts { max_columns = 2 })
  t.eq(p.columns_used, 2, "two columns")
  t.eq(p.cut, 1, "one note cut")
  t.eq(cell(p, 1, 2).note, 67, "stole the column of the note ending first")
  t.eq(p.dropped, 0, "nothing dropped")

  p = place.notes(song { { 0, 24, 60 }, { 0, 24, 64 }, { 0, 24, 67 } }, opts { max_columns = 2 })
  t.eq(p.dropped, 1, "third simultaneous note dropped")
  t.eq(p.notes_placed, 2, "two placed")
end

-- Out of range pitches ------------------------------------------------------------

do
  local p = place.notes(song { { 0, 24, 125 }, { 0, 24, 60 } }, opts())
  t.eq(p.out_of_range, 1, "pitch above 119 counted")
  t.eq(p.notes_placed, 1, "valid note placed")
end

-- Clip length counts trailing silence ---------------------------------------------

do
  local p = place.notes(song({ { 0, 24, 60 } }, 96, 4 * 96), opts())
  t.eq(p.lines_used, 16, "one bar at LPB 4")
  p = place.notes(song({}, 96, 0), opts())
  t.eq(p.lines_used, 0, "empty clip")
  t.eq(#p.cells, 0, "no cells")
end

-- Cells are sorted by line then column ---------------------------------------------

do
  local p = place.notes(song { { 0, 48, 60 }, { 24, 48, 64 } }, opts())
  local ok = true
  for i = 2, #p.cells do
    local a, b = p.cells[i - 1], p.cells[i]
    if a.line > b.line or (a.line == b.line and a.column > b.column) then
      ok = false
    end
  end
  t.check(ok, "sorted cells")
end

-- locate: spill across sequence slots ----------------------------------------------

do
  local lengths = { 64, 16, 32 }
  local seq, line = place.locate(1, 60, lengths, 0)
  t.eq(seq, 1, "same slot")
  t.eq(line, 60, "same line")
  seq, line = place.locate(1, 60, lengths, 5)
  t.eq(seq, 2, "spills into slot 2")
  t.eq(line, 1, "first line of slot 2")
  seq, line = place.locate(1, 60, lengths, 20)
  t.eq(seq, 2, "last line of slot 2")
  t.eq(line, 16, "line 16 of slot 2")
  seq, line = place.locate(1, 60, lengths, 21)
  t.eq(seq, 3, "spills into slot 3")
  t.eq(line, 1, "first line of slot 3")
  seq, line = place.locate(2, 1, lengths, 47)
  t.eq(seq, 3, "last line of slot 3")
  t.eq(line, 32, "line 32")
  seq, line = place.locate(2, 1, lengths, 48)
  t.eq(seq, nil, "past the end")
  t.eq(line, 1, "one line past the end")
end

t.done()
