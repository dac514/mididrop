--[[
  Localhost TCP listener for the MIDI Drop window. Renoise cannot hand a tool
  an OS file drop without replacing the song, so the drop lands on a small
  external window instead, which forwards the bytes here (see src/wire.lua).

  Socket callbacks run on Renoise's main thread: never block, never receive or
  close from inside them (the window closes its end after reading the reply).
]]

local wire = require "src.wire"

local M = {}

local BUFFER_TTL = 30 -- seconds an incomplete frame may wait
local RETRY_MS = 1000 -- Renoise frees a closed port a moment later: keep retrying

---@class ServerState
---@field server renoise.Socket.SocketServer|nil
---@field port integer|nil
---@field error string|nil Why the server is not listening.
---@field last_contact integer|nil `os.time()` of the last request.
---@field buffers table<string, {data: string, t: integer}>
---@field retry fun()|nil Pending bind retry timer.

---@type ServerState
M.state = { server = nil, port = nil, error = nil, last_contact = nil, buffers = {}, retry = nil }

---@param client renoise.Socket.SocketClient
---@return string
local function client_key(client)
  local ok, key = pcall(function()
    return client.peer_address .. ":" .. tostring(client.peer_port)
  end)
  return ok and key or tostring(client)
end

---@param client renoise.Socket.SocketClient
---@return boolean
local function is_local(client)
  local ok, addr = pcall(function()
    return client.peer_address
  end)
  return ok and (addr == "127.0.0.1" or addr == "::1" or addr == "localhost")
end

---Start listening on 127.0.0.1:`port`. Stops a previous listener first. When
---the port is busy (the previous instance's socket after a reload, or another
---program), binding is retried every second until it works or `stop()`.
---@param port integer
---@param handler fun(records: table<string, string>): table<string, any> Builds the reply.
---@param log fun(kind: string, text: string)
function M.start(port, handler, log)
  M.stop()
  local state = M.state

  local notifier = {}

  function notifier.socket_error(err)
    log("server", "socket error: " .. tostring(err))
  end

  function notifier.socket_accepted()
    local now = os.time()
    for key, buf in pairs(state.buffers) do
      if now - buf.t > BUFFER_TTL then
        state.buffers[key] = nil
      end
    end
  end

  ---@param client renoise.Socket.SocketClient
  ---@param message string
  function notifier.socket_message(client, message)
    if not is_local(client) then
      return
    end
    local key = client_key(client)
    local buf = state.buffers[key]
    if not buf then
      buf = { data = "", t = os.time() }
      state.buffers[key] = buf
    end
    buf.data = buf.data .. message
    local records, err = wire.decode(buf.data)
    if err then
      state.buffers[key] = nil
      client:send(wire.encode { status = "error", error = "protocol: " .. err })
      return
    end
    if not records then
      return -- wait for the rest of the frame
    end
    state.buffers[key] = nil
    state.last_contact = os.time()
    local ok, reply = pcall(handler, records)
    if not ok then
      log("error", "request failed: " .. tostring(reply))
      reply = { status = "error", error = tostring(reply) }
    end
    reply.status = reply.status or "ok"
    client:send(wire.encode(reply))
  end

  local function bind()
    local server, err = renoise.Socket.create_server("127.0.0.1", port, renoise.Socket.PROTOCOL_TCP)
    if server then
      server:run(notifier)
      state.server, state.port, state.error = server, port, nil
      log("server", ("listening on 127.0.0.1:%d"):format(port))
      return true
    end
    state.error = ("Port %d unavailable: %s"):format(port, tostring(err))
    return false
  end

  if bind() then
    return
  end
  log("server", state.error .. " (retrying)")
  local tool = renoise.tool()
  local function retry()
    if bind() then
      tool:remove_timer(retry)
      state.retry = nil
    end
  end
  state.retry = retry
  tool:add_timer(retry, RETRY_MS)
end

function M.stop()
  local state = M.state
  local tool = renoise.tool()
  if state.retry and tool:has_timer(state.retry) then
    tool:remove_timer(state.retry)
  end
  state.retry = nil
  if state.server then
    pcall(function()
      state.server:stop()
    end)
    pcall(function()
      state.server:close()
    end)
  end
  state.server, state.port, state.error, state.buffers = nil, nil, nil, {}
end

---Whole seconds since the window last talked to us, or nil if it never did.
---@return number|nil
function M.seconds_since_contact()
  if not M.state.last_contact then
    return nil
  end
  return os.time() - M.state.last_contact
end

return M
