--[[
  "Get the drop window" dialog: shown by *Launch window* when the tool does not
  know where the drop window program is yet. Three short steps, a button to the
  download page, and first, a way to pick a program that is already on disk.
  Returns the builder (so the dev bridge can map ids to views) and the root view.
]]

local drop_window = require "src.drop_window"

local M = {}

local NUMBER_WIDTH = 18
local STEP_WIDTH = 330
local BUTTON_WIDTH = 150

---@class GetWindowActions
---@field open_page fun() Open the download page in the browser.
---@field locate fun() Ask for the program on disk.

---@param platform string What `os.platform()` returns.
---@param actions GetWindowActions
---@return renoise.ViewBuilder vb, renoise.Views.View root
function M.build(platform, actions)
  local vb = renoise.ViewBuilder()
  local margin = renoise.ViewBuilder.DEFAULT_CONTROL_MARGIN
  local spacing = renoise.ViewBuilder.DEFAULT_CONTROL_SPACING
  local button_height = renoise.ViewBuilder.DEFAULT_DIALOG_BUTTON_HEIGHT
  local download = drop_window.download(platform)

  ---One numbered step: a bold headline and up to two lines under it. The second
  ---line is grey, or bright when `strong` (the file to download).
  ---@param n integer
  ---@param headline string
  ---@param line1 string
  ---@param line2 string|nil
  ---@param strong boolean|nil
  ---@return renoise.Views.Rack
  local function step(n, headline, line1, line2, strong)
    local lines = vb:column {
      vb:text { text = headline, font = "bold", width = STEP_WIDTH },
      vb:text { text = line1, style = "disabled", width = STEP_WIDTH },
    }
    if line2 then
      lines:add_view(vb:text {
        text = line2,
        style = strong and "strong" or "disabled",
        font = strong and "bold" or "normal",
        width = STEP_WIDTH,
      })
    end
    return vb:row {
      spacing = spacing,
      vb:text { text = tostring(n), font = "bold", style = "strong", width = NUMBER_WIDTH },
      lines,
    }
  end

  local inner_width = NUMBER_WIDTH + spacing + STEP_WIDTH

  local root = vb:column {
    id = "root",
    margin = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN * 2,
    spacing = renoise.ViewBuilder.DEFAULT_DIALOG_SPACING,

    vb:column {
      spacing = spacing,
      vb:text { text = "Get the drop window", font = "big" },
      vb:text {
        text = "You drag MIDI from a plugin onto a small window that stays on top.",
        style = "disabled",
      },
      vb:text {
        text = "It is a separate program. You download it once.",
        style = "disabled",
      },
    },

    vb:row {
      spacing = spacing * 2,
      vb:button {
        id = "locate",
        text = "Choose the program…",
        width = BUTTON_WIDTH,
        height = button_height,
        notifier = actions.locate,
      },
      vb:column {
        vb:space { height = 2 }, -- lines the text up with the button label
        vb:text { text = "if you already have it on this computer.", style = "disabled" },
      },
    },

    vb:text { text = "Don't have it yet? Three steps:", font = "bold" },

    vb:column {
      background = "group",
      margin = margin * 2,
      spacing = spacing * 3,
      step(1, "Download it", "From the download page, take this file:", download.file, true),
      step(2, "Unpack it", download.unpack),
      step(3, "Open it once", download.first_open, download.warning),
      vb:row {
        vb:space { width = NUMBER_WIDTH + spacing },
        vb:text {
          text = "MIDI Drop then remembers it. Launch window starts it from now on.",
          width = STEP_WIDTH,
        },
      },
      vb:horizontal_aligner {
        width = inner_width,
        mode = "right",
        vb:button {
          id = "open_page",
          text = "Open download page",
          width = BUTTON_WIDTH,
          height = button_height,
          color = { 0xd3, 0x5e, 0x2d },
          notifier = actions.open_page,
        },
      },
    },
  }

  return vb, root
end

return M
