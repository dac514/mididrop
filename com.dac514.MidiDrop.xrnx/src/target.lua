--[[
  Where a drop lands right now: pattern or phrase editor, track, instrument,
  line, LPB, and whether tempo/LPB are automated. Reads the song only; never
  modifies it. `renoise.song()` is passed in, never cached.
]]

local M = {}

---@class DropTarget : TargetPosition
---@field mode "pattern"|"phrase"
---@field seq integer Selected sequence slot (pattern mode).
---@field pattern integer Pattern index at that slot.
---@field line integer 1-based line in the pattern or phrase.
---@field track integer 1-based track index.
---@field track_name string
---@field instrument integer 1-based instrument index.
---@field instrument_name string
---@field phrase integer|nil Phrase index (phrase mode).
---@field lpb integer LPB used for placement (phrase LPB in phrase mode).
---@field phrase_lpb boolean
---@field bpm number
---@field automation AutomationState

---@param song renoise.Song
---@return renoise.Track|nil
local function master_track(song)
  for _, track in ipairs(song.tracks) do
    if track.type == renoise.Track.TRACK_TYPE_MASTER then
      return track
    end
  end
  return nil
end

---Is the master track's BPM or LPB parameter automated?
---@param song renoise.Song
---@return boolean lpb, boolean bpm
local function global_automation(song)
  local master = master_track(song)
  local lpb, bpm = false, false
  if master and master.devices[1] then
    for _, p in ipairs(master.devices[1].parameters) do
      if p.name == "LPB" then
        lpb = p.is_automated
      elseif p.name == "BPM" then
        bpm = p.is_automated
      end
    end
  end
  return lpb, bpm
end

---Count ZLxx / ZTxx effect commands in one pattern (all tracks).
---@param song renoise.Song
---@param pattern_index integer
---@return integer lpb, integer bpm
function M.tempo_commands(song, pattern_index)
  local pattern = song:pattern(pattern_index)
  local lines = pattern.number_of_lines
  local lpb, bpm = 0, 0
  for t, track in ipairs(song.tracks) do
    local columns = track.visible_effect_columns
    local ptrack = pattern:track(t)
    if columns > 0 and not ptrack.is_empty then
      for _, line in ipairs(ptrack:lines_in_range(1, lines)) do
        for c = 1, columns do
          local fx = line:effect_column(c)
          if not fx.is_empty then
            local number = fx.number_string
            if number == "ZL" then
              lpb = lpb + 1
            elseif number == "ZT" then
              bpm = bpm + 1
            end
          end
        end
      end
    end
  end
  return lpb, bpm
end

---Resolve the current drop target.
---@param song renoise.Song|nil
---@return DropTarget|nil target, string|nil err
function M.resolve(song)
  if not song then
    return nil, "No song loaded"
  end
  local track = song.selected_track
  local instrument = song.selected_instrument
  local window = renoise.app().window
  local phrase = song.selected_phrase
  local in_phrase = window.active_middle_frame
      == renoise.ApplicationWindow.MIDDLE_FRAME_INSTRUMENT_PHRASE_EDITOR
    and phrase ~= nil

  local lpb_auto, bpm_auto = global_automation(song)
  ---@type DropTarget
  local target = {
    mode = in_phrase and "phrase" or "pattern",
    seq = song.selected_sequence_index,
    pattern = song.selected_pattern_index,
    line = song.selected_line_index,
    track = song.selected_track_index,
    track_name = track.name,
    instrument = song.selected_instrument_index,
    instrument_name = instrument.name,
    phrase = nil,
    lpb = song.transport.lpb,
    phrase_lpb = false,
    bpm = song.transport.bpm,
    automation = {
      lpb_automated = lpb_auto,
      bpm_automated = bpm_auto,
      lpb_commands = 0,
      bpm_commands = 0,
    },
  }

  if in_phrase then
    ---@cast phrase renoise.InstrumentPhrase
    target.phrase = song.selected_phrase_index
    target.line = song.selected_phrase_line_index
    target.lpb = phrase.lpb
    target.phrase_lpb = true
    return target, nil
  end

  local lpb_cmds, bpm_cmds = M.tempo_commands(song, target.pattern)
  target.automation.lpb_commands = lpb_cmds
  target.automation.bpm_commands = bpm_cmds
  if track.type ~= renoise.Track.TRACK_TYPE_SEQUENCER then
    return target, "Select a note track (not a group, send or master track)"
  end
  return target, nil
end

return M
