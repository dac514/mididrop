# CLAUDE.md

This repository is a [Renoise](https://www.renoise.com) tool written in Lua, plus the
command-line tooling to format, type-check, install, reload and inspect it while Renoise runs.

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
  Windows runs PowerShell `Start-Process` (so the child does not inherit Renoise's sockets)
  through `io.popen`, never `os.execute`: see the Windows facts below.
  The path comes from the window itself: every `status` request carries `exe`
  (`current_exe()`), and the tool saves it in `dropper_path` (`src/drop_window.lua` turns it
  into the `.app` on macOS and skips App Translocation copies). The request also carries a local
  UDP `control_port`: on `tool_will_unload` (reload, disable or Renoise quitting) the tool sends
  one `kind = shutdown` frame there, and the window closes unless a tool reconnects within eight
  seconds. With no known path, *Launch window* shows the "Get the drop window" dialog
  (`src/get_window_ui.lua`), which links to the releases page, names this OS's file, closes
  itself when the window connects, and still offers a file prompt.
- The drop window remembers its position and size through eframe's `persistence` feature
  (`app.ron` in `~/.local/share/midi-drop`, `~/Library/Application Support/midi-drop` or
  `%APPDATA%\midi-drop\data`). On Linux, `dropper/src/window_memory.rs` corrects the saved
  outer position (see below). A lost window comes back with *Tools > Find MIDI Drop Window*
  (`App.find_dropper`, also a key binding): while a window is connected, the next `status` reply
  carries `summon = "1"`, and the window moves to (80, 80) on the main screen and takes focus.
  With no window connected, it does what *Launch window* does.
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
- *Launch window* on macOS (`open` + Gatekeeper on the unsigned app).
- macOS file promises (`NSFilePromiseProvider`): winit only delivers real file paths.
- On Unix the window closes inherited fds at startup (`close_inherited_fds` in `main.rs`). On
  Windows `Start-Process` keeps them out of the window (verified: a reload rebinds both ports while
  the window runs), but `cmd.exe` and PowerShell hold copies for the moment they run.
- Check that the drop window reopens where it was left on Windows and macOS. Both use eframe's own
  restore, untested here. Also check a saved position on a monitor that is no longer connected
  (eframe pulls it back on Windows, macOS does it by itself; GNOME did it on Linux), and that
  *Find MIDI Drop Window* brings an open window back on both.
- Check that a window started from Finder / Explorer is remembered on Windows and macOS, and that
  *Launch window* then starts it from that path. Paths under `AppData\Local\Temp` (opened from
  inside the zip) and App Translocation copies are not remembered on purpose.
- Check *Find MIDI Drop Window* on a minimized window on Windows and macOS. The window checks in
  from `update()`; if the OS stops redrawing a minimized window, it looks closed after 3 s and
  *Find* starts a second one.
- `just dropper-run` connects too, so it saves the `dropper/target/` path in `dropper_path`.

### Verified the hard way (2026-11-08, Renoise 3.5.4, Windows 11)

- **Every `os.execute` from a button or menu costs about 5.3 s while Renoise is the front window**,
  even `echo hi`; from a timer with another app in front the same call takes 0.3 s. `system()`
  blocks Renoise's main thread, `cmd.exe` needs a new console window, and Windows waits for the
  front window's thread to acknowledge the activation until its 5 s hung-window timeout. The
  program only starts after that. v1.00 and v1.01 behaved alike; the "1.01 regression" was this.
  `io.popen` returns as soon as the shell is started (15 ms measured, window on screen within a
  second); `pclose` waits for the shell, so the pipe is closed later from the launch-check timer.
  The shell's console now flashes briefly; before, it was created behind the blocked Renoise.
- `start "" /B ...` inside `os.execute` is not a fix: cmd's quoting turned it into bare interactive
  `cmd.exe` windows that never exit and hold inherited copies of Renoise's listening sockets.
  Symptom after the next reload: two `LISTENING` rows per port in `netstat -ano`, connections
  refused, bridge "dead" until those processes are killed.
- `renoise.app():open_url(path)` goes to the default browser for every string, `.exe` paths and
  `file://` URLs included; `open_path(exe)` selects the file in Explorer. Neither starts a program.
- With `core.autocrlf=true` the checkout was CRLF and `stylua --check` failed on every file.
  `.gitattributes` forces LF for all text files; never add line-ending flags to the justfile.

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
- (2026-11-07, GNOME on XWayland) winit reports the drop window's outer position as equal to its
  inner position, and eframe restores the outer one, so the window came back one title bar (28 px)
  lower on every start. `window_memory.rs` learns the frame once per session and saves
  outer = inner - frame. The first restart after a fresh install still moves down once.
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
| `just doctor` | check stylua, lua-language-server, just, luajit, Renoise folders, the bridge |
| `just check` | `stylua --check .` + `lua-language-server --check .` (+ Renoise's own parser via the bridge when reachable) |
| `just test` | run `tests/*_test.lua` under plain LuaJIT with the bundle on `package.path`; no Renoise needed. `just test tests/x_test.lua` runs one file, `-- ARGS` go to the test |
| `just fmt` | format all Lua in place |
| `just install` | install into Renoise through OSC `install_tool` (Renoise copies and loads the bundle); falls back to a symlink/copy that needs *Tools > Reload All Tools* once |
| `just reload` | **full reload** (default): zip the bundle (with `dev/`) and `install_tool` it through OSC; fresh Lua state, new `boot_id`, about a second |
| `just reload-soft` | quick reload of `src/` only: sync into the installed copy, `APP.stop()`, drop `src.*` from `package.loaded`, `APP.start()`. It keeps the Lua state, so closures registered outside `App.reg` stay. It does not touch `main.lua`, `manifest.xml` or `dev/`. After a Lua error the old module stays stopped (menus gone) until a reload succeeds |
| `just ping` | bridge alive? prints boot_id, bundle path, Renoise/API version |
| `just eval 'CODE'` | run Lua (an expression or statements) inside the tool's Lua state; prints captured `print` output and `=> value` per return value |
| `just views` | view tree of every open registered dialog: `Type #id WxH visible text=... value=...` |
| `just log` | last prints, errors, bridge messages from inside the tool (`-n 100`, `--clear`) |
| `just song` | one-screen summary of the current song |
| `just screenshot` | PNGs into `dist/`: on X11/XWayland one per Renoise window (dialogs are `-2`, `-3`...), whole screen elsewhere; then Read them |
| `just package` | distributable `dist/<Id>.xrnx` without `dev/` and `preferences.xml` |
| `just init com.you.Name "Name" ["You [you@x.com]"]` | rename the template placeholder once |
| `just update-defs` | refresh `definitions/` and `docs/renoise/` from GitHub |

### The development loop

1. Edit `src/*.lua` (behaviour and UI), `main.lua` (entry), `manifest.xml`, or `dev/*` (bridge).
2. `just check`, and `just test` when a pure module or a test changed. Fix everything they report before reloading.
3. `just reload`. `just reload-soft` is faster for `src/`-only edits, within the limits in the table.
4. Verify inside the running Renoise: `just eval 'APP.show_dialog()'`, `just views`,
   `just eval 'dev.set("max_columns", 4)'`, `just log`, `just screenshot`. Do not report a GUI
   change as working until `views` (and, for layout, a screenshot) shows it.
5. `just check` again, then commit.

Eval helpers available as the global `dev`: `dev.dialog([name])`, `dev.view(id)`,
`dev.set(id, value)` (assigning `.value` fires the control's notifier, the only way to
"click" programmatically), `dev.log(...)`. `APP` is the application module.

If `renoise.py` exits 3, Renoise is not running or the tool is not installed/loaded
(`just install`). If its message says it "found other tools instead", this tool's bridge is
still starting (retry in a moment) or not loaded. If it exits 4, Renoise is probably stuck on
a dialog: take a screenshot and tell the user instead of retrying blindly.

## Setting up a fresh machine

When asked to set the project up, read `docs/setup.md` and follow it in order.

## Updating a project made from an older ReSlop

When asked to bring in kit fixes, read `UPGRADING.md` in https://github.com/dac514/reslop (main)
and apply the entries newer than this project, following the rules at the top of that page.
Never rename this project's own `<Id>.xrnx` folder or ids.

## Directory map

```
CLAUDE.md, README.md          this file; human quick start
docs/setup.md                 setting up a fresh machine
docs/publishing.md            the renoise.com rules
justfile                      task runner (python3 on POSIX/WSL, python on Windows)
scripts/renoise.py            the CLI behind every recipe, plus paths, uninstall and sync
.luarc.json                   LuaLS: LuaJIT runtime, definitions as library, class plugin
stylua.toml                   2-space, 100 cols, double quotes, call_parentheses = None
definitions/                  vendored renoise/definitions (LuaCATS); UPSTREAM.md records the commit
docs/renoise/                 vendored xrnx guide pages (start/, guide/)
.github/workflows/ci.yml      stylua, LuaLS, unit tests, package; dropper fmt/test/build on 3 OSes
.github/workflows/release.yml tag v* -> GitHub release with the .xrnx and the 3 drop window archives
<Id>.xrnx/manifest.xml        Id, Version, ApiVersion (rules under Hard constraints)
<Id>.xrnx/cover.png           optional renoise.com cover (600x350), with thumbnail.png (120x45)
<Id>.xrnx/main.lua            thin entry: package.path, preferences, APP = require "src.app", APP.start(), dev bridge
<Id>.xrnx/src/app.lua         App.start/stop, App.reg (menu/key/notifier/timer), App.register_dialog, App.guard, App.defer
<Id>.xrnx/src/ui.lua          the monitor dialog; returns (vb, root)
<Id>.xrnx/src/smf.lua, place.lua, text.lua, wire.lua, drop_window.lua   pure Lua (no renoise.*), unit-tested
<Id>.xrnx/src/get_window_ui.lua  the "Get the drop window" dialog; returns (vb, root)
<Id>.xrnx/src/target.lua, writer.lua, server.lua       read the song / edit it / listen on 19870
tests/helper.lua              test helpers for tests/*_test.lua
tests/midi_builder.lua        builds MIDI file bytes for tests (no binary fixtures)
dropper/                      the drop window: Rust + eframe; src/main.rs, app.rs (UI), net.rs, wire.rs,
                              window_memory.rs (Linux fix for the saved window position)
<Id>.xrnx/dev/                dev bridge (bridge.lua, commands.lua, serialize.lua, home_port.lua); never shipped
```

## Hard constraints

- Never hand-edit `definitions/` or `docs/renoise/`; run `just update-defs`
  (it re-applies any local patches, which are listed in `definitions/UPSTREAM.md`).
- `dev/` is development only: `src/` must never `require` anything from `dev.*`,
  and `package` strips it. `tests/` lives outside the bundle and is never shipped.
- The bridge binds `127.0.0.1`. A non-loopback bind (`dev/bind`) requires the token in
  `dev/.token`; `install` writes both on WSL.
- Logic worth unit-testing goes in a pure module (like `src/place.lua`): no `renoise.*`
  and no Renoise additions to the Lua stdlib (`table.find`, `oprint`, ...), because
  `just test` runs under plain LuaJIT where those do not exist. `src/app.lua` and
  `src/ui.lua` are not testable that way; keep them thin and push logic into pure modules.
  A test is `tests/<name>_test.lua`: `local t = require "tests.helper"`, then `t.eq`,
  `t.check`, `t.fails`, and `t.done()` last (it exits non-zero on failure).
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

- Reference: `definitions/library/renoise/**/*.lua`. Grep for the class, e.g. `---@class renoise.Song`, `---@class renoise.Views.Button`,
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
  annotated, and constructors return the class rather than an instance.

## Renoise facts learned while building this kit

- Several tools in development can be installed at once, each with its own bridge. Each bridge
  listens on a **home port** from its tool id (`dev/home_port.lua`; `home_port()` in
  `scripts/renoise.py` must compute the same number, `tests/home_port_test.lua` pins both).
  `renoise.py` pings candidate ports and only uses the one whose `tool_id` matches this project;
  the bridge refuses requests whose `tool` record names another tool. `--port N` skips the check.
  Never "fix" a clash by uninstalling another tool.
- A program started with `os.execute` inherits Renoise's open sockets, including every bridge's
  listening port: while it runs, a reloaded tool cannot bind its port again. Programs a tool
  launches should close inherited descriptors (or be started through the OS shell).
- `print` goes only to Renoise's Scripting Terminal (not Log.txt, not stdout); the bridge
  captures it, so `just eval`/`just log` is the way to read it.
- Relative `require` resolves only while `main.lua` is loading (Renoise's working directory is
  elsewhere in callbacks); `main.lua` prepends `bundle_path` to `package.path` for that reason.
- `renoise.app():install_tool(path)` with a *directory* nests a copy inside an existing install;
  with a `.xrnx` zip it upgrades in place. `renoise.py` always sends a zip.
- The OSC `/renoise/evaluate` endpoint runs in a sandbox (no `io`, `os`, `require`) and never
  replies; it is only used to trigger `install_tool`. All feedback comes through the bridge.
- When a full reload fails to load, Renoise shows an error popup and keeps the old tool instance
  running. The bridge reports the load error for `src/` modules, and `just check` catches syntax
  errors before that.
- `_AUTO_RELOAD_DEBUG = true` makes Renoise reload the tool whenever its window regains focus
  after a file changed, and *opening a dialog counts as regaining focus*. That is why it is off
  in `main.lua` and `just reload` goes through OSC instead.
- A tool's custom dialog is a separate OS window; `just screenshot` captures it as its own PNG.
- Renoise loads tools before it has finished starting. In that phase `renoise.app().theme` and
  `renoise.app().theme_observable` raise "can not access the application theme while the
  application initializes", and the tool fails to load. `just install` and `just reload` run
  on a Renoise that is already up, so they never show it: only a fresh Renoise start does.
  Keep `App.start` to menus, key bindings and `renoise.tool()` observables; register
  `renoise.app()` observables when a dialog first opens (in `App.show_dialog`).

## Git

- Tags `vX.YY` must match `manifest.xml` `<Version>`; pushing one publishes a GitHub release.
- Commit only formatted (`just fmt`) and type-clean code. CI must be green.
- Before tagging, quit Renoise, start it again and check that the tool loads without a
  "Scripting Tool Error".

## Publishing on renoise.com

Read `docs/publishing.md` before uploading to renoise.com, and before changing the bundle's
`README.md`, the manifest `<Description>`, `cover.png` or `thumbnail.png`.
