# CLAUDE.md

This repository is a **Renoise tool**: an `.xrnx` scripting tool for the
[Renoise](https://www.renoise.com) tracker, written in Lua against the Renoise
Scripting API, plus the tooling to format, type-check, install, reload and
inspect it from the command line while Renoise is running.

## What you are working on

- The tool is the single `*.xrnx/` folder in the repo root
  (`com.dac514.MidiDrop.xrnx/`) plus the drop window in `dropper/`. Everything else is tooling.
- Lua dialect: **LuaJIT** = Lua 5.1 syntax (`unpack`, `loadstring`, `setfenv`;
  `bit` is built in; no `goto`, no `//`, no integer subtype).
- Renoise API version **6.2** (Renoise 3.5). The API reference is vendored in
  `definitions/library/` and the guides in `docs/renoise/`. Prefer those over memory.
- Renoise must be running, with the tool installed, for every command that talks
  to the dev bridge (`ping`, `eval`, `reload`, `views`, `log`, `song`, `check`).

## This project: MIDI Drop

Repo: https://github.com/dac514/mididrop. Users are mostly on **Windows and macOS**; it was built
and verified on Linux. Prefer fixes that keep all three working, and say which OS you verified on.

- The tool places MIDI at the Renoise cursor (pattern or phrase editor, selected instrument).
  Pipeline: `src/smf.lua` (parse) -> `src/target.lua` (where) -> `src/place.lua` (cells) ->
  `src/writer.lua` (song edit, one undo step). `App.import_bytes(name, bytes)` /
  `App.import_file(path)` run it; both are callable from `just eval`.
- Drops arrive from `dropper/` (Rust, eframe 0.33 pinned for Rust 1.88+, `Cargo.lock` committed,
  CI uses `--locked`), a separate always-on-top window that reads the dropped file at once and sends
  its bytes to `src/server.lua` on `127.0.0.1:19870` (`src/wire.lua` framing, mirrored in
  `dropper/src/wire.rs`; keep both and their tests in sync).
- *Launch window* (`App.launch_dropper`): Linux runs the binary (after `io.chmod 755`), macOS runs
  `open -n "MIDI Drop.app" --args --port N` (finds `/Applications/MIDI Drop.app` by itself),
  Windows runs PowerShell `Start-Process` so the child does not inherit Renoise's sockets.
- User-facing text: `src/text.lua` (Lua, unit-tested) and `dropper/src/app.rs`. READMEs use plain,
  friendly English for readers whose first language is not English: short sentences, no idioms.

### Testing without a plugin, on any OS

- `just dropper-run` builds and starts the window. Drag any `.mid` from Finder / Explorer / a file
  manager onto it, or pass one: `just dropper-run -- path/to/clip.mid` (placed on startup).
- `just eval 'return APP.import_file("/path/clip.mid")'` runs the same import without the window.
- Read cells back with `just eval` (`song:pattern(p):track(t):line(l).note_columns[c].note_string`).
- `just views` / `just screenshot` for the monitor. The drop window is not a Renoise window: on X11,
  capture it with `import -window <id>` (find the id with `xprop -root _NET_CLIENT_LIST`); elsewhere
  use the OS screenshot tool.
- CI (`.github/workflows/ci.yml`) builds and tests the window on ubuntu, windows and macos on every
  push. `release.yml` attaches a Linux `.tar.gz`, a Windows `.zip` and a universal, ad-hoc signed
  `MIDI Drop.app` zip to each `v*` tag.

### Open items (good first work, especially on Windows/macOS)

- Real plugin drag on Windows and macOS (Linux was tested with file-manager drags only).
- *Launch window* on Windows (PowerShell path) and macOS (`open` + Gatekeeper on the unsigned app).
- macOS file promises (`NSFilePromiseProvider`): winit only delivers real file paths.
- Check whether Windows sockets leak into the launched window anyway (`Start-Process` should prevent
  it). On Unix the window closes inherited fds at startup (`close_inherited_fds` in `main.rs`).

### Verified the hard way (2026-11-01, Renoise 3.5.4, Linux)

- `add_file_import_hook` for `.mid`: only category `"song"` overrides native import, and Renoise
  then asks to save and **replaces the song before calling the hook**. Other categories are
  ignored. Never register it; that is why the external window exists.
- ViewBuilder views cannot receive OS file drops.
- winit's native Wayland backend rejects file drops; the window forces X11 (`WAYLAND_DISPLAY`
  removed at startup) and accepts drops from Wayland apps and X11 plugin windows.
- A program started with `os.execute` inherits Renoise's listening sockets (dev bridge ports and
  the tool's 19870), so the tool cannot re-bind after a reload while it runs.
- `song:can_undo()` reads false inside bridge evals, yet real Undo works and removes a drop in
  one step ("'MIDI Drop: x.mid' was undone").
- Cursor changes (`selected_line_index`, `transport.edit_pos`) apply on the next idle tick:
  set the cursor in one `just eval`, drop in the next.
- Renoise frees a closed listening port a moment later; `server.start` keeps retrying the bind.
- Several tools in development at once each run a dev bridge, and the old kit bridges all fought
  over 18765 (after a reload `just eval` could run inside another tool). Now each bridge listens on
  its own **home port** from its tool id (`dev/home_port.lua`, same formula as `home_port()` in
  `scripts/renoise.py`; MidiDrop = 18867). `renoise.py` pings each candidate port and only uses the
  one whose `tool_id` matches this project; the bridge refuses requests whose `tool` record names
  another tool. `--port N` skips the check, for talking to another tool's bridge on purpose.

## Commands

All recipes wrap `python3 scripts/renoise.py <cmd>` (stdlib only), so the same
things work without `just`. `renoise.py` prints `ok ...` or `error ...` on the
first line; exit codes: 0 ok, 1 remote/Lua error, 2 usage, 3 cannot connect,
4 timeout, 5 unsupported on this platform. `--json` gives one JSON object.

| command | what it does |
|---|---|
| `just doctor` | check stylua, lua-language-server, just, Renoise folders, the bridge |
| `just check` | `stylua --check .` + `lua-language-server --check .` (+ Renoise's own parser via the bridge when reachable) |
| `just test` | run `tests/*_test.lua` under plain LuaJIT with the bundle on `package.path`; no Renoise needed. `just test tests/x_test.lua` runs one file, `-- ARGS` go to the test |
| `just fmt` | format all Lua in place |
| `just install` | install into Renoise through OSC `install_tool` (Renoise copies and loads the bundle); falls back to a symlink/copy that needs *Tools > Reload All Tools* once |
| `just reload` | **full reload** (default): zip the bundle (with `dev/`) and `install_tool` it through OSC; fresh Lua state, new `boot_id`, about a second |
| `just reload-soft` | quick in-place reload of `src/` only: sync into the installed copy, `APP.stop()`, drop `src.*` from `package.loaded`, `APP.start()`; keeps the Lua state |
| `just ping` | bridge alive? prints boot_id, bundle path, Renoise/API version |
| `just eval 'CODE'` | run Lua inside the tool's Lua state; `CODE` is an expression or statements; prints captured `print` output and `=> value` per return value |
| `just views` | view tree of every open registered dialog: `Type #id WxH visible text=... value=...` |
| `just log` | last prints, errors, bridge messages from inside the tool (`-n 100`, `--clear`) |
| `just song` | one-screen summary of the current song |
| `just screenshot` | PNGs into `dist/`: on X11/XWayland one file per Renoise window (main window, then each open dialog as `-2`, `-3`...), whole screen elsewhere; then Read the PNGs |
| `just package` | distributable `dist/<Id>.xrnx` without `dev/` |
| `just init com.you.Name "Name" ["You [you@x.com]"]` | rename the template placeholder once |
| `just update-defs` | refresh `definitions/` and `docs/renoise/` from GitHub |

### The development loop

1. Edit `src/*.lua` (behaviour and UI), `main.lua` (entry), `manifest.xml`, or `dev/*` (bridge).
2. `just check`, and `just test` when a pure module or a test changed. Fix everything they report before reloading.
3. `just reload` (full, any file). `just reload-soft` is faster for `src/`-only edits but keeps old
   closures registered outside `App.reg` and does not touch `main.lua`, `manifest.xml` or `dev/`.
4. Verify inside the running Renoise: `just eval 'APP.show_dialog()'`, `just views`,
   `just eval 'dev.set("max_columns", 4)'`, `just log`, `just screenshot`. Do not report a GUI
   change as working until `views` (and, for layout, a screenshot) shows it.
5. `just check` again, then commit.

Eval helpers available as the global `dev`: `dev.dialog([name])`, `dev.view(id)`,
`dev.set(id, value)` (assigning `.value` fires the control's notifier, the only way to
"click" programmatically), `dev.log(...)`. `APP` is the application module.

If `renoise.py` exits 3, Renoise is not running or the tool is not installed/loaded
(`just install`). If it exits 4, Renoise is probably stuck on a dialog: take a
screenshot and tell the user instead of retrying blindly. If `reload-soft` reports a
Lua error, the old module stays stopped (menus gone) until a reload succeeds. A full
`reload` that fails to load leaves Renoise showing an error popup and running the old
instance; `just check` catches syntax errors before that happens.

## Setting up a fresh machine

The README tells people to open the project in Claude Code and ask for a setup.
When asked to set the project up, do all of this, in order, and report at the end:

1. `python3 scripts/renoise.py doctor` (`python scripts/renoise.py doctor` on native
   Windows). It lists what is missing with per-OS install hints. Python itself missing?
   macOS and Linux ship it; on Windows `winget install Python.Python.3.13`, or use WSL.
2. Install what is missing. Prefer user-local installs and ask before anything that
   needs `sudo` or an admin shell. Pinned, known-good versions: StyLua 2.6.0,
   lua-language-server 3.19.2 (must be >= 3.13.6), just 1.59.0. LuaJIT 2.1 (any build)
   runs the unit tests; `lua5.1` is accepted as a fallback.
   - macOS: `brew install just stylua lua-language-server luajit` (offer to install Homebrew if absent).
   - Windows: `winget install Casey.Just JohnnyMorganz.StyLua LuaLS.lua-language-server`
     (or `scoop install just stylua lua-language-server`), plus `scoop install luajit`.
   - Linux / WSL: `just` and `luajit` from the distro (`sudo dnf install just luajit`,
     `sudo apt install just luajit`) or the release archive; StyLua and lua-language-server from their GitHub release
     archives into `~/.local/bin` (for LuaLS unpack the tarball under
     `~/.local/share/lua-language-server` and symlink `bin/lua-language-server`).
     Make sure `~/.local/bin` is on `PATH`.
3. Rename the placeholder if the user gave a name:
   `just init com.theirname.ToolName "Tool Name" "Their Name [email]"`. The id must be
   reverse-domain style (`com.yourname.ToolName`); ask if you only have a tool name.
4. `just check` and `just test` must pass. Then `just install` (needs Renoise running with its OSC
   server enabled: *Edit > Preferences > OSC > Enable Server*, UDP, port 8000). If the
   bridge does not answer, say exactly which of those is missing instead of guessing.
5. `just ping` and `just song`, then tell the user what you can see (song name, BPM).

## Directory map

```
CLAUDE.md, README.md          this file; human quick start
justfile                      task runner (python3 on POSIX/WSL, python on Windows)
scripts/renoise.py            CLI: doctor, paths, install, uninstall, sync, ping, eval, reload,
                              views, log, song, check, test, screenshot, package, init, update-defs
.luarc.json                   LuaLS: LuaJIT runtime, definitions as library, class plugin
stylua.toml                   2-space, 100 cols, double quotes, call_parentheses = None
definitions/                  vendored renoise/definitions (LuaCATS); UPSTREAM.md records the commit
docs/renoise/                 vendored xrnx guide pages (start/, guide/)
.github/workflows/ci.yml      stylua, LuaLS, unit tests, package; dropper fmt/test/build on 3 OSes
.github/workflows/release.yml tag v* -> GitHub release with the .xrnx and the 3 drop window archives
<Id>.xrnx/manifest.xml        Id (== folder name), ApiVersion 6.2, Version like 1.02 (no semver)
<Id>.xrnx/main.lua            thin entry: package.path, preferences, APP = require "src.app", APP.start(), dev bridge
<Id>.xrnx/src/app.lua         App.start/stop, App.reg (menu/key/notifier/timer), App.register_dialog, App.guard, App.defer
<Id>.xrnx/src/ui.lua          the monitor dialog; returns (vb, root)
<Id>.xrnx/src/smf.lua, place.lua, text.lua, wire.lua   pure Lua (no renoise.*), unit-tested
<Id>.xrnx/src/target.lua, writer.lua, server.lua       read the song / edit it / listen on 19870
tests/helper.lua              check/eq/fails/done for test files; tests/*_test.lua run under LuaJIT via `just test`
tests/midi_builder.lua        builds MIDI file bytes for tests (no binary fixtures)
dropper/                      the drop window: Rust + eframe; src/main.rs, app.rs (UI), net.rs, wire.rs
<Id>.xrnx/dev/                dev bridge (bridge.lua, commands.lua, serialize.lua); never shipped
```

## Hard constraints

- Never hand-edit `definitions/` or `docs/renoise/`; run `just update-defs`
  (it re-applies any local patches, which are listed in `definitions/UPSTREAM.md`).
- `dev/` is development only: `src/` must never `require` anything from `dev.*`,
  and `package` strips it. `tests/` lives outside the bundle and is never shipped.
- Logic worth unit-testing goes in a pure module (like `src/place.lua`): no `renoise.*`
  and no Renoise additions to the Lua stdlib (`table.find`, `oprint`, ...), because
  `just test` runs under plain LuaJIT where those do not exist. `src/app.lua` and
  `src/ui.lua` are not testable that way; keep them thin and push logic into pure modules.
  A test is `tests/<name>_test.lua`: `local t = require "tests.helper"`, then `t.eq`,
  `t.check`, `t.fails`, and `t.done()` last (it exits non-zero on failure). The bridge binds `127.0.0.1`; a non-loopback bind
  (`dev/bind`) requires the token in `dev/.token` (both written by `install` on WSL).
- `main.lua` stays thin and idempotent. Behaviour lives in `src/` behind
  `APP.start()` / `APP.stop()`. No module-level side effects.
- Register menu entries, key bindings, notifiers and timers only through
  `App.reg.*`, and every dialog through `App.register_dialog(name, dialog, vb, root)`.
  That is what makes `reload`, `views` and `dev.view` work.
- Wrap callbacks that Renoise invokes with `App.guard(fn)` so errors reach `just log`.
- Always `require "src.x"` (the `src.` prefix is what the soft reload clears).
- Never `local print = print` at module scope (the bridge hooks the global `print`).
- Never block Renoise's main thread: no `client:receive()`, `client:close()` or
  `server:wait()` inside socket callbacks, no busy loops; long jobs use coroutines
  (see `docs/renoise/guide/`) or `renoise.tool():add_timer`.
- `renoise.song()` can be nil (no song) and changes on load/new; never cache it
  across documents. `App.close_dialogs` runs on `app_new_document_observable`.
- Song list notifiers (`tracks_observable`, `instruments_observable`,
  `sequencer.pattern_sequence_observable`, `phrase_mappings_observable`) fire *during* the edit:
  the list is updated, dependents (pattern tracks, sequence, selection) are not, and they also
  fire on undo/redo. Inside them never edit the song; observe the dependent object if it has an
  observable, else `App.defer(fn)`.
- ViewBuilder constructor tables accept only documented fields; a typo such as
  `vb:text { margin = 1 }` crashes at runtime and LuaLS cannot catch it.
- Manifest: `Id` must equal the folder name without `.xrnx`; `Version` is a
  number like `1.02` (`1.0.2` is invalid); `ApiVersion` is `6.2`.
- Commit only formatted (`just fmt`) and type-clean code; CI runs both checks.

## Conventions

- LuaCATS annotations (`---@param`, `---@return`, `---@class`) on every public
  function and module table; `local` by default; modules return a table.
- Luabind classes are written `class "Name"` (no parentheses; the LuaLS plugin
  only recognises that form), which is why StyLua uses `call_parentheses = "None"`:
  `vb:text { ... }`, `require "src.app"`.
- Prefer `renoise.app():show_status(msg)` over modal dialogs while developing.
- User-visible strings and menu paths live in `src/app.lua` (`App.name`,
  `App.menu_entry`, `App.keybinding`).

## API knowledge

- Reference: `definitions/library/renoise/*.lua` and `definitions/library/renoise/**/*.lua`.
  Grep for the class, e.g. `---@class renoise.Song`, `---@class renoise.Views.Button`,
  `function renoise.ScriptingTool:add_menu_entry`. Constructor property tables are the
  `*Properties` classes (`ButtonProperties`, `TextFieldProperties`, ...).
- Renoise's additions to the Lua stdlib are in `definitions/library/standard.lua`:
  `class`, `oprint`, `rprint`, `objinfo`, `ripairs`, `table.create/copy/rcopy/count/find/keys/values/clear/is_empty`,
  `os.platform/currentdir/dirnames/filenames/mkdir/move`, `io.exists/stat/chmod`,
  `math.lin2db/db2lin`, `_AUTO_RELOAD_DEBUG`. `type(obj)` returns the class name for API objects
  (`"Song"`, `"Button"`); `rawequal` compares API objects, `==` does not work on views.
- Guides: `docs/renoise/start/*.md` (tool structure, debugging, distribution) and
  `docs/renoise/guide/*.md` (application, song, document/observables, midi, osc, sockets, sqlite).
  Online: https://renoise.github.io/xrnx/ . Links to `../API/...` in the vendored pages are not
  vendored; use the definitions instead.
- Example tools worth copying patterns from: https://github.com/renoise/xrnx/tree/master/tools
  (`ExampleToolGui` for every ViewBuilder control, `ExampleToolSlicedProcess` for coroutines).
- Known gaps in the definitions (upstream README): `__eq/__lt/__le/__index` metamethods are not
  annotated; constructors return the class rather than an instance; unknown constructor fields
  are not flagged.

## Renoise facts learned while building this kit

- `print` goes only to Renoise's Scripting Terminal (not Log.txt, not stdout); the bridge
  captures it, so `just eval`/`just log` is the way to read it.
- Relative `require` resolves only while `main.lua` is loading (Renoise's working directory is
  elsewhere in callbacks); `main.lua` prepends `bundle_path` to `package.path` for that reason.
- `renoise.app():install_tool(path)` with a *directory* nests a copy inside an existing install;
  with a `.xrnx` zip it upgrades in place. `renoise.py` always sends a zip.
- The OSC `/renoise/evaluate` endpoint runs in a sandbox (no `io`, `os`, `require`) and never
  replies; it is only used to trigger `install_tool`. All feedback comes through the bridge.
- Renoise keeps the old tool instance running when a reload fails to load; the bridge reports
  the load error for `src/` modules, and `just check` catches syntax errors before that.
- `_AUTO_RELOAD_DEBUG = true` makes Renoise reload the tool whenever its window regains focus
  after a file changed, and *opening a dialog counts as regaining focus*. That is why it is off
  in `main.lua` and `just reload` goes through OSC instead.
- A tool's custom dialog is a separate OS window; `just screenshot` captures it as its own PNG.

## Git

- Tags `vX.YY` must match `manifest.xml` `<Version>`; pushing one publishes a GitHub release.
- CI must be green: StyLua, LuaLS, `test` and `package`.
