--[[
  Builds Standard MIDI File bytes for tests, so no binary fixtures are needed.

    local mb = require "tests.midi_builder"
    local bytes = mb.file { ppq = 96, tracks = {
      mb.track { {0, 0x90, 60, 100}, {48, 0x80, 60, 0} },  -- {delta, status, data...}
    } }

  Events are raw: pass `M.RS` as status to write running status (data bytes only),
  or `mb.meta(kind, data)` / `mb.raw(bytes)` for anything else.
]]

local M = {}

---Placeholder status meaning "running status": write the data bytes only.
M.RS = false

---@param n integer
---@return string
function M.vlq(n)
  local bytes = { n % 128 }
  n = math.floor(n / 128)
  while n > 0 do
    table.insert(bytes, 1, n % 128 + 128)
    n = math.floor(n / 128)
  end
  return string.char(unpack(bytes))
end

---@param n integer
---@return string
function M.u32(n)
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256
  )
end

---@param n integer
---@return string
function M.u16(n)
  return string.char(math.floor(n / 256) % 256, n % 256)
end

---@param kind integer
---@param data string
---@return table
function M.meta(kind, data)
  return { raw = "\255" .. string.char(kind) .. M.vlq(#data) .. data }
end

---@param bytes string
---@return table
function M.raw(bytes)
  return { raw = bytes }
end

---@param events table[] `{delta, status|M.RS, data...}` or `{delta, M.meta(...)}`.
---@param opts {no_end: boolean}|nil
---@return string
function M.track(events, opts)
  local body = {}
  for _, e in ipairs(events) do
    body[#body + 1] = M.vlq(e[1])
    if type(e[2]) == "table" then
      body[#body + 1] = e[2].raw
    else
      for i = 2, #e do
        if e[i] then
          body[#body + 1] = string.char(e[i])
        end
      end
    end
  end
  if not (opts and opts.no_end) then
    body[#body + 1] = "\0\255\47\0"
  end
  local data = table.concat(body)
  return "MTrk" .. M.u32(#data) .. data
end

---@param spec {format: integer|nil, ppq: integer|nil, division: integer|nil, tracks: string[]}
---@return string
function M.file(spec)
  local tracks = spec.tracks
  local header = "MThd"
    .. M.u32(6)
    .. M.u16(spec.format or (#tracks > 1 and 1 or 0))
    .. M.u16(#tracks)
    .. M.u16(spec.division or spec.ppq or 96)
  return header .. table.concat(tracks)
end

---Wrap SMF bytes in a RIFF RMID container.
---@param smf string
---@return string
function M.rmid(smf)
  local data = "data" .. string.char(#smf % 256, math.floor(#smf / 256) % 256, 0, 0) .. smf
  local size = 4 + #data
  return "RIFF" .. string.char(size % 256, math.floor(size / 256) % 256, 0, 0) .. "RMID" .. data
end

return M
