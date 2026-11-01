--[[
  Standard MIDI File reader. Pure Lua (no `renoise.*`), so `just test` runs it
  under plain LuaJIT.

  Ported from the `Midi` class in MidiConvert (Dac Chartrand, after Valentin
  Schmidt's PHP MIDI class): the variable length reader, the RMID unwrap and the
  status-nibble dispatch. Unlike the original it walks chunks by their declared
  length (a literal "MTrk" inside sysex or text data no longer splits a track),
  handles running status for every channel message, accepts format 2, and
  returns paired notes instead of MF2T text lines.
]]

local M = {}

---@class SmfNote
---@field tick integer Start, in ticks from the beginning of the file.
---@field dur integer Length in ticks (0 for a note-on immediately followed by its note-off).
---@field pitch integer MIDI note number 0-127.
---@field vel integer Note-on velocity 1-127.
---@field ch integer MIDI channel 1-16.

---@class SmfTempo
---@field tick integer
---@field bpm number

---@class SmfSong
---@field format integer 0, 1 or 2.
---@field ppq integer Ticks per quarter note.
---@field track_count integer Number of MTrk chunks read.
---@field notes SmfNote[] All tracks merged, sorted by tick, then pitch.
---@field length_ticks integer End of the longest track or note.
---@field tempos SmfTempo[]
---@field name string|nil First track/sequence name found.

-- Data bytes that follow each channel status, by high nibble.
local DATA_LEN = { [0x8] = 2, [0x9] = 2, [0xA] = 2, [0xB] = 2, [0xC] = 1, [0xD] = 1, [0xE] = 2 }

---@param s string
---@param i integer
---@return integer
local function u16(s, i)
  local a, b = s:byte(i, i + 1)
  return a * 256 + b
end

---@param s string
---@param i integer
---@return integer
local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

---Raise a parse error that `M.parse` turns into `nil, message`.
---@param msg string
local function fail(msg)
  error({ smf = msg }, 0)
end

---Read a variable length quantity starting at `p`.
---@param s string
---@param p integer
---@param stop integer Last readable index.
---@return integer value, integer next
local function read_vlq(s, p, stop)
  local value = 0
  for _ = 1, 4 do
    if p > stop then
      fail "truncated variable length value"
    end
    local c = s:byte(p)
    p = p + 1
    value = value * 128 + c % 128
    if c < 0x80 then
      return value, p
    end
  end
  fail "variable length value longer than 4 bytes"
  return value, p -- unreachable; keeps LuaLS happy
end

---@param s string
---@param p integer First byte of the track body.
---@param stop integer Last byte of the track body.
---@param song SmfSong
local function parse_track(s, p, stop, song)
  local time = 0
  local running = nil ---@type integer|nil
  local open = {} ---@type table<integer, {tick: integer, vel: integer}[]>
  local notes = song.notes

  local function note_off(ch, pitch)
    local queue = open[ch * 128 + pitch]
    if queue and #queue > 0 then
      local on = table.remove(queue, 1)
      notes[#notes + 1] =
        { tick = on.tick, dur = time - on.tick, pitch = pitch, vel = on.vel, ch = ch + 1 }
    end
  end

  while p <= stop do
    local dt
    dt, p = read_vlq(s, p, stop)
    time = time + dt
    if p > stop then
      break -- delta time with no event: tolerate a missing end-of-track
    end
    local status = s:byte(p)
    if status >= 0x80 then
      p = p + 1
    elseif running then
      status = running -- running status: this byte is already data
    else
      fail(("data byte 0x%02X without a status byte"):format(status))
    end

    if status < 0xF0 then
      running = status
      local hi, ch = math.floor(status / 16), status % 16
      local n = DATA_LEN[hi]
      if p + n - 1 > stop then
        fail "truncated channel message"
      end
      local d1, d2 = s:byte(p), s:byte(p + 1)
      p = p + n
      if hi == 0x9 and d2 > 0 then
        local key = ch * 128 + d1
        open[key] = open[key] or {}
        table.insert(open[key], { tick = time, vel = d2 })
      elseif hi == 0x8 or hi == 0x9 then
        note_off(ch, d1)
      end
    elseif status == 0xFF then
      -- Meta event. Running status is deliberately kept: some writers rely on it.
      if p > stop then
        fail "truncated meta event"
      end
      local kind = s:byte(p)
      local len
      len, p = read_vlq(s, p + 1, stop)
      local data = s:sub(p, p + len - 1)
      p = p + len
      if kind == 0x2F then
        break
      elseif kind == 0x51 and #data == 3 then
        local usec = (data:byte(1) * 256 + data:byte(2)) * 256 + data:byte(3)
        if usec > 0 then
          song.tempos[#song.tempos + 1] = { tick = time, bpm = 60000000 / usec }
        end
      elseif kind == 0x03 and song.name == nil and data ~= "" then
        song.name = data
      end
    elseif status == 0xF0 or status == 0xF7 then
      running = nil
      local len
      len, p = read_vlq(s, p, stop)
      p = p + len
    else
      fail(("unexpected system message 0x%02X in track"):format(status))
    end
  end

  -- Notes still sounding at the end of the track end there.
  for key, queue in pairs(open) do
    for _, on in ipairs(queue) do
      local ch, pitch = math.floor(key / 128), key % 128
      notes[#notes + 1] =
        { tick = on.tick, dur = time - on.tick, pitch = pitch, vel = on.vel, ch = ch + 1 }
    end
  end
  if time > song.length_ticks then
    song.length_ticks = time
  end
end

---Parse a Standard MIDI File (optionally wrapped in a RIFF RMID container).
---@param bytes string The whole file.
---@return SmfSong|nil song, string|nil err
function M.parse(bytes)
  if type(bytes) ~= "string" then
    return nil, "no data"
  end
  local start = bytes:find("MThd", 1, true)
  if not start or (start > 1 and bytes:sub(1, 4) ~= "RIFF") then
    return nil, "not a MIDI file"
  end
  if #bytes < start + 13 then
    return nil, "truncated MIDI header"
  end
  local header_len = u32(bytes, start + 4)
  local division = u16(bytes, start + 12)
  if division >= 0x8000 then
    return nil, "SMPTE timed MIDI files are not supported"
  end
  if division == 0 then
    return nil, "MIDI file has zero ticks per quarter note"
  end

  ---@type SmfSong
  local song = {
    format = u16(bytes, start + 8),
    ppq = division,
    track_count = 0,
    notes = {},
    length_ticks = 0,
    tempos = {},
    name = nil,
  }

  local ok, err = pcall(function()
    local p = start + 8 + header_len
    while p + 7 <= #bytes do
      local id = bytes:sub(p, p + 3)
      local len = u32(bytes, p + 4)
      local body = p + 8
      local stop = math.min(body + len - 1, #bytes) -- tolerate a truncated last chunk
      if id == "MTrk" then
        song.track_count = song.track_count + 1
        parse_track(bytes, body, stop, song)
      end
      p = body + len
    end
  end)
  if not ok then
    if type(err) == "table" and err.smf then
      return nil, err.smf
    end
    error(err, 0)
  end
  if song.track_count == 0 then
    return nil, "MIDI file has no tracks"
  end

  local order = {} ---@type table<SmfNote, integer>
  for i, note in ipairs(song.notes) do
    order[note] = i
  end
  table.sort(song.notes, function(a, b)
    if a.tick ~= b.tick then
      return a.tick < b.tick
    end
    if a.pitch ~= b.pitch then
      return a.pitch < b.pitch
    end
    return order[a] < order[b]
  end)
  for _, note in ipairs(song.notes) do
    if note.tick + note.dur > song.length_ticks then
      song.length_ticks = note.tick + note.dur
    end
  end
  return song, nil
end

return M
