--[[
  Turns parsed MIDI notes into tracker cells. Pure Lua (no `renoise.*`), so
  `just test` runs it under plain LuaJIT.

  Timing is beat based: a quarter note is `lpb` lines whatever the tempo, so BPM
  never matters, only LPB. Positions are kept in 1/256 of a line, which is the
  resolution of Renoise's delay column. This is the exact inverse of MidiConvert's
  export (`time = (line + delay / 256) * ppq / lpb`), so a round trip lands on
  the same cells.
]]

local M = {}

M.OFF = 120
M.MAX_COLUMNS = 12
M.MAX_NOTE = 119

---@class PlaceOptions
---@field lpb integer Lines per beat of the target (song or phrase).
---@field timing "delay"|"line" Keep sub-line timing in the delay column, or snap to lines.
---@field note_offs boolean Write OFF where a note ends before the next one in its column.
---@field velocity boolean Write velocity into the volume column (127 is left empty).
---@field max_columns integer Note columns available, 1-12.

---@class PlacedCell
---@field line integer 0-based line offset from the drop position.
---@field column integer 1-based note column.
---@field note integer Note value 0-119, or `M.OFF`.
---@field volume integer|nil 0-127, nil leaves the volume column empty.
---@field delay integer 0-255.

---@class Placement
---@field cells PlacedCell[] Sorted by line, then column.
---@field lines_used integer Lines covered, including trailing silence of the clip.
---@field columns_used integer
---@field notes_placed integer
---@field dropped integer Notes left out: more simultaneous notes than columns.
---@field cut integer Notes shortened because their column was needed.
---@field out_of_range integer Notes above B-9 that Renoise cannot play.
---@field uses_delay boolean Any cell has a non-zero delay.
---@field uses_volume boolean Any cell has a volume.

---@class PlacedNote
---@field start integer Position in 1/256 lines.
---@field stop integer
---@field line integer
---@field pitch integer
---@field vel integer

---Place `song.notes` into note columns.
---@param song {notes: SmfNote[], ppq: integer, length_ticks: integer}
---@param opts PlaceOptions
---@return Placement
function M.notes(song, opts)
  local lpb, ppq = opts.lpb, song.ppq
  local snap = opts.timing == "line"
  local max_columns = math.max(1, math.min(M.MAX_COLUMNS, opts.max_columns or M.MAX_COLUMNS))

  ---@param tick number
  ---@return integer
  local function to_pos(tick)
    if snap then
      return math.floor(tick * lpb / ppq + 0.5) * 256
    end
    return math.floor(tick * lpb * 256 / ppq + 0.5)
  end

  ---@type Placement
  local result = {
    cells = {},
    lines_used = 0,
    columns_used = 0,
    notes_placed = 0,
    dropped = 0,
    cut = 0,
    out_of_range = 0,
    uses_delay = false,
    uses_volume = false,
  }

  ---@type {notes: PlacedNote[], last: PlacedNote|nil}[]
  local columns = {}
  for c = 1, max_columns do
    columns[c] = { notes = {}, last = nil }
  end

  for _, n in ipairs(song.notes) do
    if n.pitch > M.MAX_NOTE then
      result.out_of_range = result.out_of_range + 1
    else
      local start = to_pos(n.tick)
      local stop = to_pos(n.tick + n.dur)
      if stop <= start then
        stop = start + (snap and 256 or 1)
      end
      local line = math.floor(start / 256)

      -- Lowest column whose last note has ended (and is not on this very line).
      local chosen
      for c = 1, max_columns do
        local last = columns[c].last
        if not last or (last.stop <= start and last.line < line) then
          chosen = c
          break
        end
      end
      -- None free: cut the note that ends first, if it started on an earlier line.
      if not chosen then
        local best_stop
        for c = 1, max_columns do
          local last = columns[c].last --[[@as PlacedNote]]
          if last.line < line and (not best_stop or last.stop < best_stop) then
            chosen, best_stop = c, last.stop
          end
        end
        if chosen then
          columns[chosen].last.stop = start
          result.cut = result.cut + 1
        end
      end

      if chosen then
        local placed = { start = start, stop = stop, line = line, pitch = n.pitch, vel = n.vel }
        local col = columns[chosen]
        col.notes[#col.notes + 1] = placed
        col.last = placed
        result.notes_placed = result.notes_placed + 1
        if chosen > result.columns_used then
          result.columns_used = chosen
        end
      else
        result.dropped = result.dropped + 1
      end
    end
  end

  local cells = result.cells
  local last_line = -1
  for c = 1, max_columns do
    local list = columns[c].notes
    for i, placed in ipairs(list) do
      local volume = nil
      if opts.velocity and placed.vel < 127 then
        volume = placed.vel
        result.uses_volume = true
      end
      local delay = placed.start % 256
      cells[#cells + 1] = {
        line = placed.line,
        column = c,
        note = placed.pitch,
        volume = volume,
        delay = delay,
      }
      if delay ~= 0 then
        result.uses_delay = true
      end
      last_line = math.max(last_line, placed.line)

      local nxt = list[i + 1]
      if opts.note_offs and (not nxt or nxt.start > placed.stop) then
        local off_line, off_delay = math.floor(placed.stop / 256), placed.stop % 256
        if off_line <= placed.line then
          off_line, off_delay = placed.line + 1, 0
        end
        -- If the next note shares the line, it cuts this one anyway.
        if not nxt or off_line < nxt.line then
          cells[#cells + 1] = { line = off_line, column = c, note = M.OFF, delay = off_delay }
          if off_delay ~= 0 then
            result.uses_delay = true
          end
          last_line = math.max(last_line, off_line)
        end
      end
    end
  end

  table.sort(cells, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.column < b.column
  end)

  local clip_lines = math.ceil(song.length_ticks * lpb / ppq - 1e-9)
  result.lines_used = math.max(last_line + 1, clip_lines)
  return result
end

---Map a line offset from a start position onto a run of sequence slots.
---@param start_seq integer 1-based sequence index of the drop.
---@param start_line integer 1-based line of the drop in that slot.
---@param lengths integer[] Line count of each sequence slot's pattern.
---@param offset integer 0-based line offset from the drop position.
---@return integer|nil seq, integer line 1-based; seq is nil past the last slot.
function M.locate(start_seq, start_line, lengths, offset)
  local seq, line = start_seq, start_line + offset
  while seq <= #lengths do
    if line <= lengths[seq] then
      return seq, line
    end
    line = line - lengths[seq]
    seq = seq + 1
  end
  return nil, line
end

return M
