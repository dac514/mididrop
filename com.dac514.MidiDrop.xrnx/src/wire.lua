--[[
  Wire format between the MIDI Drop window and the tool. Pure Lua (no
  `renoise.*`) so `just test` covers it. Same framing as the dev bridge, so
  both sides stay binary safe and trivial to implement:

    frame   := <body_len>\n<body>
    body    := (<name> <len>\n<bytes>)*

  Requests carry `kind` ("status", "drop", or "shutdown"). Status requests
  include the drop window's local UDP control port; drops add `name` (file name)
  and `data` (the raw .mid bytes; the window reads the file at drop time because
  plugins delete their temp files when the drag ends). Replies carry `status`
  ("ok" or "error") plus text records for the window to show. The one-way
  shutdown signal uses the same frame on the advertised UDP control port.
]]

local M = {}

M.MAX_FRAME = 8 * 1024 * 1024 -- a MIDI clip is a few KB; refuse anything absurd

---Try to decode one frame from the start of `buf`.
---@param buf string
---@return table<string, string>|nil records Nil while the frame is incomplete or on error.
---@return string|nil err Protocol error; the connection should be dropped.
function M.decode(buf)
  local nl = buf:find("\n", 1, true)
  if not nl then
    if #buf > 20 then
      return nil, "bad frame header"
    end
    return nil, nil
  end
  local total = tonumber(buf:sub(1, nl - 1))
  if not total or total < 0 or total ~= math.floor(total) then
    return nil, "bad frame header"
  end
  if total > M.MAX_FRAME then
    return nil, "frame too large"
  end
  if #buf < nl + total then
    return nil, nil
  end
  local body = buf:sub(nl + 1, nl + total)
  local records, pos = {}, 1
  while pos <= #body do
    local lnl = body:find("\n", pos, true)
    if not lnl then
      return nil, "bad record header"
    end
    local name, len = body:sub(pos, lnl - 1):match "^([%w_]+) (%d+)$"
    if not name then
      return nil, "bad record header"
    end
    len = tonumber(len)
    if lnl + len > #body then
      return nil, "record overruns frame"
    end
    records[name] = body:sub(lnl + 1, lnl + len)
    pos = lnl + len + 1
  end
  return records, nil
end

---Encode records as one frame. Names are sorted (`status` and `kind` first) so
---output is deterministic.
---@param records table<string, any>
---@return string
function M.encode(records)
  local names = {}
  for k, v in pairs(records) do
    if v ~= nil then
      names[#names + 1] = k
    end
  end
  local first = { status = 1, kind = 1 }
  table.sort(names, function(a, b)
    if first[a] ~= first[b] then
      return first[a] ~= nil
    end
    return a < b
  end)
  local parts = {}
  for _, k in ipairs(names) do
    local v = tostring(records[k])
    parts[#parts + 1] = ("%s %d\n%s"):format(k, #v, v)
  end
  local body = table.concat(parts)
  return ("%d\n%s"):format(#body, body)
end

return M
