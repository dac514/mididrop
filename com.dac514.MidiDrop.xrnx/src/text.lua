--[[
  Text for the MIDI Drop monitor and status bar. Pure Lua on purpose: no
  `renoise.*`, no Renoise additions to the standard library, so `just test` can
  run it under plain LuaJIT. `src/ui.lua` and `src/app.lua` read the song and
  hand plain values in here.
]]

local M = {}

M.NONE = "-"

---File name without its directory (either separator).
---@param path string
---@return string
function M.basename(path)
  return (path:match "([^/\\]+)$") or path
end

---Shorten `s` to at most `max` characters, keeping the start and the end
---(file extensions stay visible). Counts bytes; fine for the ASCII-heavy names
---plugins produce.
---@param s string
---@param max integer
---@return string
function M.ellipsize(s, max)
  if #s <= max then
    return s
  end
  local tail = math.floor((max - 3) / 3)
  return s:sub(1, max - 3 - tail) .. "..." .. s:sub(-tail)
end

---@param mode "pattern"|"phrase"|nil
---@return string
function M.mode(mode)
  if mode == "phrase" then
    return "Phrase editor"
  elseif mode == "pattern" then
    return "Pattern editor"
  end
  return M.NONE
end

---@param index integer|nil 1-based track index.
---@param name string|nil
---@return string
function M.track(index, name)
  if not index then
    return M.NONE
  end
  return ("%02d  %s"):format(index, name or "")
end

---Instrument numbers are shown the way Renoise shows them: 0-based hex.
---@param index integer|nil 1-based instrument index.
---@param name string|nil
---@return string
function M.instrument(index, name)
  if not index then
    return M.NONE
  end
  if not name or name == "" then
    name = "(untitled)"
  end
  return ("%02X  %s"):format(index - 1, name)
end

---@class TargetPosition
---@field mode "pattern"|"phrase"
---@field seq integer|nil Sequence slot (pattern mode).
---@field pattern integer|nil Pattern index (pattern mode).
---@field phrase integer|nil Phrase index (phrase mode).
---@field line integer 1-based line.

---@param pos TargetPosition|nil
---@return string
function M.position(pos)
  if not pos then
    return M.NONE
  end
  if pos.mode == "phrase" then
    return ("Phrase %02d  ·  Line %03d"):format(pos.phrase or 0, pos.line - 1)
  end
  return ("Seq %02d  ·  Pattern %02d  ·  Line %03d"):format(
    (pos.seq or 1) - 1,
    (pos.pattern or 1) - 1,
    pos.line - 1
  )
end

---@param bpm number|nil
---@param lpb integer|nil
---@param phrase_lpb boolean|nil True when the LPB comes from the phrase, not the song.
---@return string
function M.tempo(bpm, lpb, phrase_lpb)
  if not lpb then
    return M.NONE
  end
  local lpb_text = ("%d LPB%s"):format(lpb, phrase_lpb and " (phrase)" or "")
  if not bpm then
    return lpb_text
  end
  return ("%s  ·  %g BPM"):format(lpb_text, math.floor(bpm * 100 + 0.5) / 100)
end

---@class AutomationState
---@field lpb_automated boolean
---@field bpm_automated boolean
---@field lpb_commands integer ZLxx commands in the target pattern.
---@field bpm_commands integer ZTxx commands in the target pattern.

---One line describing tempo/LPB automation, or nil when there is none.
---@param a AutomationState|nil
---@return string|nil
function M.automation(a)
  if not a then
    return nil
  end
  if a.lpb_automated or a.lpb_commands > 0 then
    return "LPB changes in this song: notes are placed at the current LPB"
  end
  if a.bpm_automated or a.bpm_commands > 0 then
    return "BPM is automated (no effect on placement)"
  end
  return nil
end

---@param n integer
---@param word string
---@return string
local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

---@param p Placement
---@return string
function M.summary(p)
  return ("%s  ·  %s  ·  %s"):format(
    plural(p.notes_placed, "note"),
    plural(p.columns_used, "column"),
    plural(p.lines_used, "line")
  )
end

---@class DropReport
---@field file string File name (no directory).
---@field placement Placement
---@field where string Where it landed, from `M.position`.
---@field truncated integer Cells cut off at the end of the pattern/phrase.
---@field skipped integer Cells skipped in mix mode because the target was not empty.
---@field aliased boolean A spilled-into pattern also plays elsewhere in the sequence.
---@field lpb_changes boolean

---Warnings worth showing after a drop, most important first.
---@param r DropReport
---@return string[]
function M.warnings(r)
  local p = r.placement
  local out = {}
  if p.dropped > 0 then
    out[#out + 1] = ("%s dropped: more simultaneous notes than columns"):format(
      plural(p.dropped, "note")
    )
  end
  if r.truncated > 0 then
    out[#out + 1] = ("%s did not fit and were cut"):format(plural(r.truncated, "event"))
  end
  if r.skipped > 0 then
    out[#out + 1] = ("%s skipped: mix paste keeps existing notes"):format(
      plural(r.skipped, "event")
    )
  end
  if p.cut > 0 then
    out[#out + 1] = ("%s shortened to free a column"):format(plural(p.cut, "note"))
  end
  if p.out_of_range > 0 then
    out[#out + 1] = ("%s above B-9 ignored"):format(plural(p.out_of_range, "note"))
  end
  if r.aliased then
    out[#out + 1] = "A pattern written to also plays elsewhere in the sequence"
  end
  if r.lpb_changes then
    out[#out + 1] = "LPB changes in this range: timing uses the LPB at the drop line"
  end
  return out
end

---One line for the status bar after a drop.
---@param r DropReport
---@return string
function M.status(r)
  local warnings = M.warnings(r)
  local line = ("MIDI Drop: %s  →  %s  (%s)"):format(r.file, r.where, M.summary(r.placement))
  if #warnings > 0 then
    line = line .. "  ·  " .. warnings[1]
  end
  return line
end

return M
