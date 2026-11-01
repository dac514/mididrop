--[[
  MIDI Drop monitor dialog: drop window status, where the next drop lands,
  placement options and the last drop. Pure construction plus a refresh timer;
  returns the builder (so the dev bridge can map ids to views) and the root view.
]]

local text = require "src.text"
local target = require "src.target"
local server = require "src.server"

local M = {}

local LABEL_WIDTH = 84
local VALUE_WIDTH = 270
local SECTION_WIDTH = LABEL_WIDTH + VALUE_WIDTH + 2 * renoise.ViewBuilder.DEFAULT_CONTROL_MARGIN
local REFRESH_MS = 250
local WARNING_ROWS = 3
local BUTTON_WIDTH = 132
-- Text beside a button, so the button's right edge lines up with the value column.
local WAY_TEXT_WIDTH = LABEL_WIDTH
  + VALUE_WIDTH
  + renoise.ViewBuilder.DEFAULT_CONTROL_SPACING * 2
  - BUTTON_WIDTH
  - renoise.ViewBuilder.DEFAULT_CONTROL_SPACING * 4
local FILE_CHARS = 44 -- longer file names would widen the dialog

local COLOR_OK = { 0x6c, 0xd0, 0x8a }
local COLOR_IDLE = { 0xc8, 0xa8, 0x50 }
local COLOR_ERROR = { 0xe0, 0x60, 0x60 }

---@param app table The application module (`src/app.lua`).
---@return renoise.ViewBuilder vb, renoise.Views.View root
function M.build(app)
  local vb = renoise.ViewBuilder()
  local prefs = app.prefs()
  local margin = renoise.ViewBuilder.DEFAULT_CONTROL_MARGIN
  local spacing = renoise.ViewBuilder.DEFAULT_CONTROL_SPACING

  ---A labelled row: fixed-width label column so every section lines up.
  ---@param label string
  ---@param view renoise.Views.View
  ---@return renoise.Views.Rack
  local function row(label, view)
    return vb:row {
      spacing = spacing,
      vb:text { text = label, width = LABEL_WIDTH, style = "disabled" },
      view,
    }
  end

  ---@param id string
  ---@return renoise.Views.Text
  local function value(id)
    return vb:text { id = id, width = VALUE_WIDTH, text = text.NONE }
  end

  ---A titled group box.
  ---@param title string
  ---@param ... renoise.Views.View
  ---@return renoise.Views.Rack
  local function section(title, ...)
    local col = vb:column {
      background = "group",
      margin = margin * 2,
      spacing = spacing * 2,
      width = SECTION_WIDTH,
      vb:text { text = title, font = "bold" },
    }
    for _, view in ipairs { ... } do
      col:add_view(view)
    end
    return col
  end

  ---One way to bring MIDI in: a headline and a hint on the left, its button on the right.
  ---@param headline renoise.Views.Text
  ---@param hint string
  ---@param button renoise.Views.Button
  ---@return renoise.Views.Rack
  local function way(headline, hint, button)
    return vb:row {
      spacing = spacing * 4,
      vb:column {
        headline,
        vb:text { text = hint, style = "disabled", width = WAY_TEXT_WIDTH },
      },
      vb:column {
        vb:space { height = 7 }, -- centers the button on the two text lines
        button,
      },
    }
  end

  local warnings = vb:column { spacing = spacing }
  for i = 1, WARNING_ROWS do
    warnings:add_view(vb:text {
      id = "warning_" .. i,
      text = "",
      style = "strong",
      width = SECTION_WIDTH - 2 * margin,
      visible = false,
    })
  end

  local root = vb:column {
    id = "root",
    margin = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN * 2,
    spacing = renoise.ViewBuilder.DEFAULT_DIALOG_SPACING,

    vb:column {
      spacing = spacing,
      vb:text { text = "MIDI Drop", font = "big" },
      vb:text {
        text = "Places MIDI at the cursor, on the selected instrument.",
        style = "disabled",
      },
    },

    section(
      "Bring MIDI in",
      way(
        vb:text { id = "server", text = text.NONE, width = WAY_TEXT_WIDTH },
        "Drag from a plugin onto the drop window.",
        vb:button {
          id = "launch",
          text = "Launch window",
          width = BUTTON_WIDTH,
          height = renoise.ViewBuilder.DEFAULT_DIALOG_BUTTON_HEIGHT,
          notifier = app.guard(app.launch_dropper),
        }
      ),
      way(
        vb:text { text = "Or import a .mid file", width = WAY_TEXT_WIDTH },
        "MIDI already on disk, no window needed.",
        vb:button {
          id = "import",
          text = "Import .mid file…",
          width = BUTTON_WIDTH,
          height = renoise.ViewBuilder.DEFAULT_DIALOG_BUTTON_HEIGHT,
          notifier = app.guard(function()
            local path =
              renoise.app():prompt_for_filename_to_read({ "mid", "midi" }, "Import MIDI at cursor")
            if path ~= "" then
              app.import_file(path)
            end
          end),
        }
      ),
      row(
        "Window port",
        vb:valuebox {
          id = "port",
          min = 1024,
          max = 65535,
          width = 80,
          bind = prefs.port,
        }
      )
    ),

    section(
      "Next import lands in",
      row("Editor", value "mode"),
      row("Track", value "track"),
      row("Instrument", value "instrument"),
      row("Position", value "position"),
      row("Timing", value "tempo"),
      vb:text {
        id = "automation",
        text = "",
        style = "strong",
        width = SECTION_WIDTH - 2 * margin,
        visible = false,
      }
    ),

    section(
      "Placement",
      row(
        "Timing",
        vb:switch {
          id = "timing",
          width = VALUE_WIDTH,
          items = { "Delay column", "Snap to lines" },
          bind = prefs.timing,
        }
      ),
      row(
        "Paste",
        vb:switch {
          id = "paste",
          width = VALUE_WIDTH,
          items = { "Overwrite", "Mix (keep existing)" },
          bind = prefs.paste,
        }
      ),
      row(
        "Overflow",
        vb:popup {
          id = "overflow",
          width = VALUE_WIDTH,
          items = { "Spill into next patterns", "Grow the pattern", "Truncate" },
          bind = prefs.overflow,
        }
      ),
      row(
        "Columns",
        vb:row {
          spacing = spacing * 4,
          vb:valuebox { id = "max_columns", min = 1, max = 12, width = 56, bind = prefs.max_columns },
          vb:row {
            spacing = spacing,
            vb:checkbox { id = "note_offs", bind = prefs.note_offs },
            vb:text { text = "Note-offs" },
          },
          vb:row {
            spacing = spacing,
            vb:checkbox { id = "velocity", bind = prefs.velocity },
            vb:text { text = "Velocity to volume" },
          },
        }
      )
    ),

    section(
      "Last import",
      row("File", value "last_file"),
      row("Result", value "last_result"),
      row("Landed at", value "last_where"),
      warnings
    ),
  }

  local views = vb.views

  ---@param id string
  ---@param s string
  local function set(id, s)
    local v = views[id] --[[@as renoise.Views.Text]]
    if v.text ~= s then
      v.text = s
    end
  end

  ---Like `set`, but the row only takes space while it has text.
  ---@param id string
  ---@param s string
  local function set_optional(id, s)
    set(id, s)
    local v = views[id]
    if v.visible ~= (s ~= "") then
      v.visible = s ~= ""
    end
  end

  local function refresh_server()
    local v = views.server --[[@as renoise.Views.Text]]
    local state = server.state
    local s, color = "Not listening", COLOR_ERROR ---@type string, RGBColor
    local err = state.error
    if err then
      s = err
    elseif state.server then
      local since = server.seconds_since_contact()
      if since and since <= 3 then
        s, color = "Window connected", COLOR_OK
      else
        s, color = ("Waiting for the window on port %d"):format(state.port), COLOR_IDLE
      end
    end
    if v.text ~= s then
      v.text = s
      v.color = color
    end
  end

  local function refresh_target()
    local where, err = target.resolve(renoise.song())
    if not where then
      for _, id in ipairs { "mode", "track", "instrument", "position", "tempo" } do
        set(id, text.NONE)
      end
      set_optional("automation", err or "")
      return
    end
    set("mode", text.mode(where.mode))
    set("track", text.track(where.track, where.track_name))
    set("instrument", text.instrument(where.instrument, where.instrument_name))
    set("position", text.position(where))
    set("tempo", text.tempo(where.bpm, where.lpb, where.phrase_lpb))
    set_optional("automation", err or text.automation(where.automation) or "")
  end

  local shown_drop = false
  local function refresh_last()
    local last = app.last_drop
    if last == shown_drop then
      return
    end
    shown_drop = last
    local lines = {}
    if not last then
      set("last_file", text.NONE)
      set("last_result", text.NONE)
      set("last_where", text.NONE)
    elseif last.error then
      set("last_file", text.ellipsize(last.file, FILE_CHARS))
      set("last_result", "Not imported")
      set("last_where", text.NONE)
      lines = { last.error }
    else
      set("last_file", text.ellipsize(last.file, FILE_CHARS))
      set("last_result", text.summary(last.report.placement))
      set("last_where", last.report.where)
      lines = text.warnings(last.report)
    end
    for i = 1, WARNING_ROWS do
      set_optional("warning_" .. i, lines[i] or "")
    end
  end

  local function refresh()
    refresh_server()
    refresh_target()
    refresh_last()
  end

  local tick
  tick = app.guard(function()
    local entry = app.dialogs.main
    if not entry or not entry.dialog.visible then
      if renoise.tool():has_timer(tick) then
        renoise.tool():remove_timer(tick)
      end
      return
    end
    refresh()
  end)
  refresh()
  app.reg.timer(tick, REFRESH_MS)

  return vb, root
end

return M
