//! MIDI Drop window: a small always-on-top drop target for the MIDI Drop Renoise
//! tool. Drag MIDI out of a plugin onto it; the bytes go to the tool over
//! localhost and the notes land at the Renoise cursor.
//!
//! Renoise cannot hand a tool an OS file drop without replacing the song, which
//! is why this window exists at all.

#![cfg_attr(windows, windows_subsystem = "windows")]

use std::path::PathBuf;

mod app;
mod net;
mod wire;

const DEFAULT_PORT: u16 = 19870;

fn usage() -> ! {
    println!(
        "midi-drop [--port N] [FILE.mid]\n\n\
         Drop window for the MIDI Drop Renoise tool.\n\
         --port N   tool port (default {DEFAULT_PORT}, or $MIDIDROP_PORT)\n\
         FILE.mid   placed at the Renoise cursor on startup, as if dropped\n\
         Linux: runs under X11/XWayland so drags from X11 plugin windows work;\n\
         set MIDIDROP_WAYLAND=1 to use native Wayland (no file drops there yet)."
    );
    std::process::exit(0)
}

/// The tool port and any files to place on startup ("Open with", drop on the icon).
fn parse_args() -> (u16, Vec<PathBuf>) {
    let mut port = std::env::var("MIDIDROP_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(DEFAULT_PORT);
    let mut files = Vec::new();
    let mut args = std::env::args_os().skip(1);
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--port" | "-p") => {
                match args
                    .next()
                    .and_then(|p| p.to_str().and_then(|p| p.parse().ok()))
                {
                    Some(p) => port = p,
                    None => usage(),
                }
            }
            Some(a) if a.starts_with('-') => usage(),
            _ => files.push(PathBuf::from(arg)),
        }
    }
    (port, files)
}

/// When Renoise starts this window (`os.execute`), the child inherits Renoise's
/// open sockets, including the tool's listening port, which then cannot be bound
/// again after a tool reload. Close everything but stdin/out/err first thing.
#[cfg(unix)]
fn close_inherited_fds() {
    extern "C" {
        fn close(fd: i32) -> i32;
    }
    let dir = if cfg!(target_os = "linux") {
        "/proc/self/fd"
    } else {
        "/dev/fd"
    };
    let fds: Vec<i32> = match std::fs::read_dir(dir) {
        Ok(entries) => entries
            .filter_map(|e| e.ok()?.file_name().to_str()?.parse().ok())
            .collect(),
        Err(_) => (3..1024).collect(),
    };
    for fd in fds.into_iter().filter(|&fd| fd > 2) {
        // SAFETY: nothing in this process has opened files yet; closing a stale
        // or already-closed descriptor (the read_dir handle) just fails with EBADF.
        unsafe {
            close(fd);
        }
    }
}

fn main() -> eframe::Result {
    #[cfg(unix)]
    close_inherited_fds();
    let (port, files) = parse_args();

    // winit's Wayland backend does not accept file drops yet; XWayland does,
    // and Renoise and its plugin windows are X11 clients anyway.
    #[cfg(target_os = "linux")]
    if std::env::var_os("MIDIDROP_WAYLAND").is_none() {
        std::env::remove_var("WAYLAND_DISPLAY");
    }

    let options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_title("MIDI Drop")
            .with_app_id("midi-drop")
            .with_inner_size([380.0, 300.0])
            .with_min_inner_size([300.0, 240.0])
            .with_always_on_top()
            .with_drag_and_drop(true),
        ..Default::default()
    };
    eframe::run_native(
        "MIDI Drop",
        options,
        Box::new(move |cc| Ok(Box::new(app::DropApp::new(cc, port, files)))),
    )
}
