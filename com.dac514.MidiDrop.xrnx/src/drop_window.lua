--[[
  Facts about the drop window program, for starting it and for helping people
  get it. Pure Lua on purpose: no `renoise.*`, no Renoise additions to the
  standard library, so `just test` can run it under plain LuaJIT.
  `platform` is what `os.platform()` returns: "WINDOWS", "MACINTOSH" or "LINUX".
]]

local M = {}

M.RELEASES_URL = "https://github.com/dac514/mididrop/releases/latest"

---@class DropWindowDownload
---@field file string The release file for this platform.
---@field unpack string How to unpack and place it.
---@field first_open string How to open it the first time.
---@field warning string|nil What the system says about an unsigned program, and what to click.

---@type table<string, DropWindowDownload>
local DOWNLOADS = {
  WINDOWS = {
    file = "midi-drop-windows-x86_64.zip",
    unpack = "Unzip it into any folder you like.",
    first_open = "Double-click midi-drop.exe.",
    warning = "If Windows warns you, click More info, then Run anyway.",
  },
  MACINTOSH = {
    file = "midi-drop-macos-universal.zip",
    unpack = "Unzip it and move MIDI Drop.app to Applications.",
    first_open = "Right-click MIDI Drop.app and choose Open.",
    warning = "Click Open again. You only do this the first time.",
  },
  LINUX = {
    file = "midi-drop-linux-x86_64.tar.gz",
    unpack = "Unpack it into any folder you like, for example ~/.local/bin.",
    first_open = "Start the midi-drop program.",
  },
}

---What to download and how to open it on this platform.
---@param platform string
---@return DropWindowDownload
function M.download(platform)
  return DOWNLOADS[platform] or DOWNLOADS.LINUX
end

---The `.app` bundle that contains `path`, or nil when `path` is not inside one.
---@param path string
---@return string|nil
function M.app_bundle(path)
  return path:match "^(.-%.app)/Contents/MacOS/" or path:match "^(.-%.app)/?$"
end

---The path worth remembering for a program path that a running drop window
---reported, or nil. On macOS this is the `.app` bundle. Temporary copies are
---gone later, so they are not remembered: a Mac app started straight from
---Downloads ("App Translocation"), and on Windows a program opened from inside
---a zip file, which runs from the Temp folder.
---@param exe string|nil
---@param platform string
---@return string|nil
function M.remembered_path(exe, platform)
  if not exe or exe == "" then
    return nil
  end
  -- Linux names a program file that was replaced while it runs "... (deleted)".
  exe = exe:gsub(" %(deleted%)$", "")
  if platform == "WINDOWS" then
    if exe:lower():find("\\appdata\\local\\temp\\", 1, true) then
      return nil
    end
    return exe
  end
  if platform == "MACINTOSH" then
    if exe:find("/AppTranslocation/", 1, true) then
      return nil
    end
    return M.app_bundle(exe) or exe
  end
  return exe
end

return M
