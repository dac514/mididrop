--[[
  Writes a `Placement` (src/place.lua) into the song at a `DropTarget`
  (src/target.lua): pattern track lines (spilling across sequence slots when
  asked) or the selected phrase. The only module that edits the song.
]]

local place = require "src.place"
local text = require "src.text"

local M = {}

local EMPTY_INSTRUMENT = 255
local EMPTY_VOLUME = 255

---@class WriteOptions
---@field file string File name for the undo description.
---@field paste "overwrite"|"mix"
---@field overflow "spill"|"grow"|"truncate"

---@param song renoise.Song
---@return integer[]
local function sequence_lengths(song)
  local lengths = {}
  for i, pattern_index in ipairs(song.sequencer.pattern_sequence) do
    lengths[i] = song:pattern(pattern_index).number_of_lines
  end
  return lengths
end

---Prepare the pattern run the drop will cover and return a line resolver.
---@param song renoise.Song
---@param target DropTarget
---@param span integer Lines the drop covers.
---@param overflow "spill"|"grow"|"truncate"
---@return fun(offset: integer): (renoise.PatternTrack|nil, integer), boolean aliased
local function pattern_run(song, target, span, overflow)
  local sequencer = song.sequencer
  local last = math.max(span, 1) - 1
  local lengths

  if overflow == "spill" then
    lengths = sequence_lengths(song)
    local slot_lines = lengths[target.seq]
    while place.locate(target.seq, target.line, lengths, last) == nil do
      local at = #lengths + 1
      local index = sequencer:insert_new_pattern_at(at)
      song:pattern(index).number_of_lines = slot_lines
      lengths[at] = slot_lines
    end
  else
    local pattern = song:pattern(target.pattern)
    if overflow == "grow" then
      local needed = math.min(target.line + last, renoise.Pattern.MAX_NUMBER_OF_LINES)
      if needed > pattern.number_of_lines then
        pattern.number_of_lines = needed
      end
    end
    -- Only the selected slot: a fake one-slot sequence.
    lengths = { pattern.number_of_lines }
  end

  local sequence = sequencer.pattern_sequence
  local first_seq = overflow == "spill" and target.seq or 1
  local seq_of = function(slot)
    return overflow == "spill" and slot or target.seq
  end

  -- A pattern written to that also plays at another slot changes there too.
  local aliased = false
  local last_slot = place.locate(first_seq, target.line, lengths, last) or #lengths
  local touched = {}
  for slot = first_seq, last_slot do
    touched[sequence[seq_of(slot)]] = true
  end
  local seen = {}
  for _, pattern_index in ipairs(sequence) do
    if touched[pattern_index] then
      if seen[pattern_index] then
        aliased = true
      end
      seen[pattern_index] = true
    end
  end

  local function resolve(offset)
    local slot, line = place.locate(first_seq, target.line, lengths, offset)
    if not slot then
      return nil, 0
    end
    local pattern = song:pattern(sequence[seq_of(slot)])
    return pattern:track(target.track), line
  end
  return resolve, aliased
end

---Write `placement` at `target`. Returns the report the UI and status bar show.
---@param song renoise.Song
---@param target DropTarget
---@param placement Placement
---@param opts WriteOptions
---@return DropReport
function M.apply(song, target, placement, opts)
  song:describe_undo("MIDI Drop: " .. opts.file)

  ---@type DropReport
  local report = {
    file = opts.file,
    placement = placement,
    where = text.position(target),
    truncated = 0,
    skipped = 0,
    aliased = false,
    lpb_changes = target.automation.lpb_automated or target.automation.lpb_commands > 0,
  }
  local columns = placement.columns_used
  local span = placement.lines_used

  ---@type fun(offset: integer): renoise.PatternLine|nil
  local line_at
  ---@type renoise.Track|renoise.InstrumentPhrase
  local columns_owner
  local instrument_value

  if target.mode == "phrase" then
    local phrase = song.selected_phrase --[[@as renoise.InstrumentPhrase]]
    if opts.overflow ~= "truncate" then
      local needed = math.min(target.line + span - 1, renoise.InstrumentPhrase.MAX_NUMBER_OF_LINES)
      if needed > phrase.number_of_lines then
        phrase.number_of_lines = needed
      end
    end
    local count = phrase.number_of_lines
    line_at = function(offset)
      local line = target.line + offset
      if line > count then
        return nil
      end
      return phrase:line(line)
    end
    columns_owner = phrase
    instrument_value = EMPTY_INSTRUMENT -- phrases play their own instrument
  else
    local resolve, aliased = pattern_run(song, target, span, opts.overflow)
    report.aliased = aliased
    line_at = function(offset)
      local ptrack, line = resolve(offset)
      if not ptrack then
        return nil
      end
      return ptrack:line(line)
    end
    columns_owner = song:track(target.track)
    instrument_value = target.instrument - 1
  end

  if columns == 0 then
    return report
  end

  if columns > columns_owner.visible_note_columns then
    columns_owner.visible_note_columns = columns
  end
  if placement.uses_volume then
    columns_owner.volume_column_visible = true
  end
  if placement.uses_delay then
    columns_owner.delay_column_visible = true
  end

  if opts.paste == "overwrite" then
    for offset = 0, span - 1 do
      local line = line_at(offset)
      if line then
        for c = 1, columns do
          line:note_column(c):clear()
        end
      end
    end
  end

  for _, cell in ipairs(placement.cells) do
    local line = line_at(cell.line)
    if not line then
      report.truncated = report.truncated + 1
    else
      local nc = line:note_column(cell.column)
      if opts.paste == "mix" and not nc.is_empty then
        report.skipped = report.skipped + 1
      else
        nc.note_value = cell.note
        nc.instrument_value = cell.note == place.OFF and EMPTY_INSTRUMENT or instrument_value
        nc.volume_value = cell.volume or EMPTY_VOLUME
        nc.delay_value = cell.delay
      end
    end
  end
  return report
end

return M
