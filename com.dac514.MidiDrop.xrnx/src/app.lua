--[[
  Application module. Owns everything the tool registers with Renoise (menu
  entries, key bindings, notifiers, timers, dialogs) so that it can be started
  and stopped cleanly. That is what makes the dev bridge's soft reload safe:
  `APP.stop()` on the old module, re-require `src/`, `APP.start()` on the new one.

  Rules:
  * Register only through `App.reg.*` and `App.register_dialog`.
  * No side effects at module level; do them in `App.start()`.
  * `App.start()` can run while Renoise is still starting, when reading
    `renoise.app().theme` raises an error. Register `renoise.app()`
    observables when a dialog first opens instead.
  * Wrap callbacks that Renoise invokes with `App.guard` so errors reach the
    dev log.
  * Inside song list notifiers, read dependents through `App.defer`.
]]

local smf = require "src.smf"
local place = require "src.place"
local text = require "src.text"
local target = require "src.target"
local writer = require "src.writer"
local server = require "src.server"

local App = {}

---@class MidiDropPreferences : renoise.Document.DocumentNode
---@field port renoise.Document.ObservableNumber
---@field timing renoise.Document.ObservableNumber 1 = delay column, 2 = snap to lines.
---@field note_offs renoise.Document.ObservableBoolean
---@field velocity renoise.Document.ObservableBoolean
---@field paste renoise.Document.ObservableNumber 1 = overwrite, 2 = mix.
---@field overflow renoise.Document.ObservableNumber 1 = spill, 2 = grow, 3 = truncate.
---@field max_columns renoise.Document.ObservableNumber
---@field dropper_path renoise.Document.ObservableString

App.name = "MIDI Drop"
App.menu_entry = "Main Menu:Tools:" .. App.name .. "..."
App.keybinding = "Global:Tools:Show " .. App.name
App.pattern_menu_entry = "Pattern Editor:" .. App.name .. "..."
App.phrase_menu_entry = "Phrase Editor:" .. App.name .. "..."
App.launch_menu_entry = "Main Menu:Tools:" .. App.name .. " Window"
App.launch_keybinding = "Global:Tools:Launch " .. App.name .. " Window"

local OVERFLOW = { "spill", "grow", "truncate" }
local PASTE = { "overwrite", "mix" }
local TIMING = { "delay", "line" }

---The last drop, for the dialog: a report, or an error message.
---@type {report: DropReport|nil, error: string|nil, file: string}|nil
App.last_drop = nil

---@class AppDialogEntry
---@field dialog renoise.Dialog
---@field vb renoise.ViewBuilder
---@field root renoise.Views.View

---Registered dialogs by name. Read by the dev bridge's `views` command.
---@type table<string, AppDialogEntry>
App.dialogs = {}

---Log sink. The dev bridge replaces it to capture messages into its ring buffer.
---@type fun(kind: string, text: string)
App.log_sink = function(kind, text)
  print(("[%s] %s"):format(kind, text))
end

---Replace the log sink (used by the dev bridge).
---@param sink fun(kind: string, text: string)
function App.set_log_sink(sink)
  App.log_sink = sink
end

---@param text string
function App.log(text)
  App.log_sink("app", text)
end

---@return MidiDropPreferences
function App.prefs()
  return renoise.tool().preferences --[[@as MidiDropPreferences]]
end

---Wrap a callback so that errors are logged before being re-raised.
---@generic F : function
---@param fn F
---@return F
function App.guard(fn)
  return function(...)
    local n = select("#", ...)
    local args = { ... }
    local results = {
      xpcall(function()
        return fn(unpack(args, 1, n))
      end, function(err)
        return debug.traceback(tostring(err), 2)
      end),
    }
    if not results[1] then
      local message = results[2] and tostring(results[2]) or "unknown error"
      App.log_sink("error", message)
      error(message, 0)
    end
    return unpack(results, 2)
  end
end

-- Registration ---------------------------------------------------------------

---Registration helpers. Everything registered here is undone by `App.stop()`.
local reg = {
  ---@type string[]
  menus = {},
  ---@type string[]
  keys = {},
  ---@type { observable: renoise.Document.Observable, fn: function }[]
  notifiers = {},
  ---@type function[]
  timers = {},
}
App.reg = reg

---@param entry ToolMenuEntry
function reg.menu(entry)
  local tool = renoise.tool()
  if tool:has_menu_entry(entry.name) then
    tool:remove_menu_entry(entry.name)
  end
  tool:add_menu_entry(entry)
  table.insert(reg.menus, entry.name)
end

---@param binding ToolKeybindingEntry
function reg.key(binding)
  local tool = renoise.tool()
  if tool:has_keybinding(binding.name) then
    tool:remove_keybinding(binding.name)
  end
  tool:add_keybinding(binding)
  table.insert(reg.keys, binding.name)
end

---@param observable renoise.Document.Observable
---@param fn function
function reg.notifier(observable, fn)
  if observable:has_notifier(fn) then
    return -- already registered and tracked; safe to call again on refresh
  end
  observable:add_notifier(fn)
  table.insert(reg.notifiers, { observable = observable, fn = fn })
end

---@param fn function
---@param interval_ms integer
function reg.timer(fn, interval_ms)
  local tool = renoise.tool()
  if tool:has_timer(fn) then
    tool:remove_timer(fn)
  end
  tool:add_timer(fn, interval_ms)
  table.insert(reg.timers, fn)
end

-- Deferral -------------------------------------------------------------------

---@type fun()[]
local deferred = {}

local function run_deferred()
  renoise.tool().app_idle_observable:remove_notifier(run_deferred)
  local queue = deferred
  deferred = {}
  for _, fn in ipairs(queue) do
    pcall(App.guard(fn)) -- guard logs the error, pcall keeps the queue going
  end
end

---Queue `fn` (once) for the next idle tick, after Renoise has finished the
---current operation. Song list notifiers (`tracks_observable`,
---`instruments_observable`, `sequencer.pattern_sequence_observable`,
---`phrase_mappings_observable`) fire *during* the edit: inside them the list is
---updated but patterns, sequence and selection are not, and the song must not
---be modified. Observe the dependent object when it has an observable;
---otherwise defer the work with this.
---https://forum.renoise.com/t/79511  https://forum.renoise.com/t/33796/11
---@param fn fun()
function App.defer(fn)
  if table.find(deferred, fn) then
    return
  end
  table.insert(deferred, fn)
  local idle = renoise.tool().app_idle_observable
  if not idle:has_notifier(run_deferred) then
    idle:add_notifier(run_deferred)
  end
end

-- Dialogs --------------------------------------------------------------------

---@param name string
---@param dialog renoise.Dialog
---@param vb renoise.ViewBuilder
---@param root renoise.Views.View
function App.register_dialog(name, dialog, vb, root)
  App.dialogs[name] = { dialog = dialog, vb = vb, root = root }
end

function App.close_dialogs()
  for name, entry in pairs(App.dialogs) do
    if entry.dialog.visible then
      entry.dialog:close()
    end
    App.dialogs[name] = nil
  end
end

---Show the main dialog, creating it if needed.
function App.show_dialog()
  local existing = App.dialogs.main
  if existing and existing.dialog.visible then
    existing.dialog:show()
    return
  end
  local ui = require "src.ui"
  local vb, root = ui.build(App)
  local dialog = renoise.app():show_custom_dialog(App.name, root)
  App.register_dialog("main", dialog, vb, root)
end

-- Import -----------------------------------------------------------------------

---Place MIDI file bytes at the current target. Used by the drop window (through
---the server) and by `just eval` for testing.
---@param name string File name (directory is stripped).
---@param bytes string
---@return DropReport|nil report, string|nil err
function App.import_bytes(name, bytes)
  local file = text.basename(name ~= "" and name or "clip.mid")
  local function failed(err)
    App.last_drop = { report = nil, error = err, file = file }
    renoise.app():show_status("MIDI Drop: " .. file .. ": " .. err)
    return nil, err
  end

  local parsed, perr = smf.parse(bytes)
  if not parsed then
    return failed(perr or "unreadable MIDI file")
  end
  local song = renoise.song()
  local where, terr = target.resolve(song)
  if not where or terr then
    return failed(terr or "no target")
  end
  ---@cast song renoise.Song
  local prefs = App.prefs()
  local placement = place.notes(parsed, {
    lpb = where.lpb,
    timing = TIMING[prefs.timing.value] or "delay",
    note_offs = prefs.note_offs.value,
    velocity = prefs.velocity.value,
    max_columns = prefs.max_columns.value,
  })
  if placement.notes_placed == 0 then
    return failed "no notes in this MIDI file"
  end
  local report = writer.apply(song, where, placement, {
    file = file,
    paste = PASTE[prefs.paste.value] or "overwrite",
    overflow = OVERFLOW[prefs.overflow.value] or "spill",
  })
  App.last_drop = { report = report, error = nil, file = file }
  renoise.app():show_status(text.status(report))
  App.log(text.status(report))
  return report, nil
end

---Read a .mid file from disk and import it (testing, and the "Import file" button).
---@param path string
---@return DropReport|nil report, string|nil err
function App.import_file(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil, "cannot open " .. path
  end
  local bytes = fh:read "*a"
  fh:close()
  return App.import_bytes(path, bytes)
end

---Records describing the current target, for the drop window.
---@return table<string, string>
function App.target_records()
  local where, err = target.resolve(renoise.song())
  if not where then
    return { ready = "0", target = err or "No song", detail = "" }
  end
  local detail = text.tempo(where.bpm, where.lpb, where.phrase_lpb)
  local automation = text.automation(where.automation)
  if automation then
    detail = detail .. "\n" .. automation
  end
  return {
    ready = err and "0" or "1",
    target = err or ("%s  ·  %s  ·  Instr %s"):format(
      where.mode == "phrase" and "Phrase" or "Pattern",
      text.track(where.track, where.track_name),
      text.instrument(where.instrument, where.instrument_name)
    ),
    position = text.position(where),
    detail = detail,
  }
end

---Server request handler.
---@param records table<string, string>
---@return table<string, any>
function App.handle_request(records)
  if records.kind == "status" then
    return App.target_records()
  elseif records.kind == "drop" then
    local report, err = App.import_bytes(records.name or "", records.data or "")
    if not report then
      return { status = "error", error = err }
    end
    local reply = App.target_records()
    reply.result = text.summary(report.placement)
    reply.where = report.where
    reply.warnings = table.concat(text.warnings(report), "\n")
    return reply
  end
  return { status = "error", error = "unknown request: " .. tostring(records.kind) }
end

---(Re)start the listener on the configured port.
function App.restart_server()
  server.start(App.prefs().port.value, App.guard(App.handle_request), App.log_sink)
end

-- Drop window --------------------------------------------------------------------

---POSIX shell single quotes.
---@param s string
---@return string
local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---PowerShell single quotes (Windows paths cannot contain double quotes).
---@param s string
---@return string
local function ps_quote(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

local LAUNCH_CHECK_MS = 4000 -- how long the window gets to say hello

---@type fun()|nil
local launch_check = nil

---Start the external drop window, asking for its location the first time.
---Does nothing (but say so) when a window is already talking to us, and warns
---when the launched window never connects.
function App.launch_dropper()
  local since = server.seconds_since_contact()
  if since and since <= 3 then
    renoise.app():show_status "MIDI Drop: the drop window is already open"
    return
  end
  local prefs = App.prefs()
  local path = prefs.dropper_path.value
  if (path == "" or not io.exists(path)) and os.platform() == "MACINTOSH" then
    -- The usual install spots for the app bundle.
    local home = os.getenv "HOME" or ""
    for _, candidate in ipairs {
      "/Applications/MIDI Drop.app",
      home .. "/Applications/MIDI Drop.app",
    } do
      if io.exists(candidate) then
        path = candidate
        prefs.dropper_path.value = path
        break
      end
    end
  end
  if path == "" or not io.exists(path) then
    path = renoise.app():prompt_for_filename_to_read({ "*" }, "Locate the MIDI Drop window program")
    if path == "" then
      return
    end
    prefs.dropper_path.value = path
  end
  local port = tostring(prefs.port.value)
  local platform = os.platform()
  -- Picked the program inside the bundle? Launch the bundle.
  local bundle = path:match "^(.-%.app)/Contents/MacOS/"
  if platform == "MACINTOSH" and bundle then
    path = bundle
  end
  local cmd
  if platform == "WINDOWS" then
    -- Start-Process goes through the Windows shell, so the window does not
    -- inherit Renoise's sockets (cmd's `start` would hand it the tool's port).
    cmd = ("powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command \"Start-Process -FilePath %s -ArgumentList '--port','%s'\""):format(
      ps_quote(path),
      port
    )
  elseif platform == "MACINTOSH" and path:match "%.app/?$" then
    -- `open` starts the app through launchd: no inherited sockets.
    cmd = ("open -n %s --args --port %s"):format(shell_quote(path), port)
  else
    -- Browser downloads drop the executable bit; restore it (rwxr-xr-x).
    io.chmod(path, 755)
    cmd = ("%s --port %s >/dev/null 2>&1 &"):format(shell_quote(path), port)
  end
  App.log("launch: " .. cmd)
  os.execute(cmd)

  local tool = renoise.tool()
  if launch_check and tool:has_timer(launch_check) then
    tool:remove_timer(launch_check)
  end
  local launched_at = os.time()
  local check
  check = App.guard(function()
    tool:remove_timer(check)
    local contact = server.state.last_contact
    if not contact or contact < launched_at then
      renoise.app():show_status(
        "MIDI Drop: the drop window did not start. Check its path and permissions: " .. path
      )
    end
  end)
  launch_check = check
  reg.timer(check, LAUNCH_CHECK_MS)
end

-- Lifecycle ------------------------------------------------------------------

function App.start()
  reg.menu {
    name = App.menu_entry,
    invoke = App.guard(App.show_dialog),
  }
  reg.key {
    name = App.keybinding,
    invoke = App.guard(App.show_dialog),
  }
  reg.menu { name = App.pattern_menu_entry, invoke = App.guard(App.show_dialog) }
  reg.menu { name = App.phrase_menu_entry, invoke = App.guard(App.show_dialog) }
  reg.menu { name = App.launch_menu_entry, invoke = App.guard(App.launch_dropper) }
  reg.key { name = App.launch_keybinding, invoke = App.guard(App.launch_dropper) }
  -- Close dialogs when the song changes so no view keeps stale song references.
  reg.notifier(renoise.tool().app_new_document_observable, App.close_dialogs)
  reg.notifier(renoise.tool().tool_will_unload_observable, server.stop)
  reg.notifier(App.prefs().port, App.restart_server)
  App.restart_server()
  App.log "started"
end

function App.stop()
  App.close_dialogs()
  server.stop()
  local tool = renoise.tool()
  for _, name in ipairs(reg.menus) do
    if tool:has_menu_entry(name) then
      tool:remove_menu_entry(name)
    end
  end
  for _, name in ipairs(reg.keys) do
    if tool:has_keybinding(name) then
      tool:remove_keybinding(name)
    end
  end
  for _, n in ipairs(reg.notifiers) do
    -- The observable may belong to a song that no longer exists.
    pcall(function()
      if n.observable:has_notifier(n.fn) then
        n.observable:remove_notifier(n.fn)
      end
    end)
  end
  for _, fn in ipairs(reg.timers) do
    if tool:has_timer(fn) then
      tool:remove_timer(fn)
    end
  end
  deferred = {}
  if tool.app_idle_observable:has_notifier(run_deferred) then
    tool.app_idle_observable:remove_notifier(run_deferred)
  end
  reg.menus, reg.keys, reg.notifiers, reg.timers = {}, {}, {}, {}
  App.log "stopped"
end

return App
