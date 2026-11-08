//! The window: a header with the connection state, a big drop zone showing where
//! the next drop lands, and a footer with the result of the last drop.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::{Duration, Instant};

use eframe::egui::{
    self, epaint::tessellator::path::rounded_rectangle, pos2, text::LayoutJob, vec2, Align, Align2,
    Color32, CornerRadius, FontId, Pos2, Rect, Sense, Shape, Stroke, StrokeKind,
};

use crate::net::{self, Reply, Request};
#[cfg(target_os = "linux")]
use crate::window_memory;
use crate::wire::{self, Records};

const POLL: Duration = Duration::from_millis(700);
const FLASH: Duration = Duration::from_millis(900);
const SHUTDOWN_GRACE: Duration = Duration::from_secs(8);

#[derive(Default)]
struct ShutdownTimer {
    started: Option<Instant>,
}

impl ShutdownTimer {
    fn signal(&mut self) {
        self.started = Some(Instant::now());
    }

    fn reconnected(&mut self) {
        self.started = None;
    }

    fn expired(&self, now: Instant) -> bool {
        self.started
            .is_some_and(|started| now.saturating_duration_since(started) >= SHUTDOWN_GRACE)
    }
}

/// Where *Launch window* in Renoise brings an open window back to: near the
/// top-left corner of the main screen, which every OS puts at (0, 0).
const SUMMON_AT: Pos2 = Pos2 { x: 80.0, y: 80.0 };

const MARGIN: f32 = 18.0;
const GAP: f32 = 12.0;
const ZONE_RADIUS: u8 = 14;

struct Palette {
    bg: Color32,
    zone: Color32,
    border: Color32,
    text: Color32,
    muted: Color32,
    accent: Color32,
    ok: Color32,
    warn: Color32,
    error: Color32,
}

const P: Palette = Palette {
    bg: Color32::from_rgb(0x17, 0x19, 0x1d),
    zone: Color32::from_rgb(0x20, 0x23, 0x28),
    border: Color32::from_rgb(0x3d, 0x42, 0x4b),
    text: Color32::from_rgb(0xe8, 0xe9, 0xeb),
    muted: Color32::from_rgb(0x8e, 0x94, 0x9e),
    accent: Color32::from_rgb(0xf0, 0x8a, 0x3c),
    ok: Color32::from_rgb(0x6c, 0xd0, 0x8a),
    warn: Color32::from_rgb(0xd8, 0xb4, 0x5a),
    error: Color32::from_rgb(0xe8, 0x6a, 0x6a),
};

enum Link {
    Connecting,
    Online,
    Offline,
}

/// What the footer shows.
enum Outcome {
    Idle,
    Sending(String),
    Placed {
        file: String,
        summary: String,
        detail: String,
        warnings: Vec<String>,
    },
    Failed {
        file: String,
        error: String,
    },
}

#[derive(Default)]
struct Target {
    ready: bool,
    line: String,
    position: String,
    detail: String,
}

impl Target {
    fn from_records(r: &Records) -> Self {
        Self {
            ready: wire::text(r, "ready") == "1",
            line: wire::text(r, "target"),
            position: wire::text(r, "position"),
            detail: wire::text(r, "detail"),
        }
    }
}

pub struct DropApp {
    port: u16,
    requests: Sender<Request>,
    replies: Receiver<Reply>,
    in_flight: usize,
    last_poll: Option<Instant>,
    link: Link,
    target: Target,
    outcome: Outcome,
    flash: Option<(Instant, Color32)>,
    /// Files from the command line, placed on the first frame.
    startup: Vec<PathBuf>,
    shutdown: ShutdownTimer,
    #[cfg(target_os = "linux")]
    frame: FrameProbe,
}

/// Learns the window frame once per session (see `window_memory`).
#[cfg(target_os = "linux")]
struct FrameProbe {
    started: Instant,
    /// The outer position eframe restored, in pixels; `None` once probed.
    requested: Option<Pos2>,
    found: Option<egui::Vec2>,
}

#[cfg(target_os = "linux")]
impl FrameProbe {
    /// The window manager places the window a moment after it opens.
    const SETTLE: Duration = Duration::from_millis(500);

    fn new(storage: Option<&dyn eframe::Storage>) -> Self {
        let requested = storage
            .and_then(|s| eframe::get_value::<window_memory::Saved>(s, window_memory::KEY))
            .and_then(|saved| saved.outer_position_pixels);
        Self {
            started: Instant::now(),
            requested,
            found: None,
        }
    }

    fn update(&mut self, ctx: &egui::Context) {
        let Some(requested) = self.requested else {
            return;
        };
        if self.started.elapsed() < Self::SETTLE {
            ctx.request_repaint_after(Self::SETTLE);
            return;
        }
        if let Some(inner) = ctx.input(|i| i.viewport().inner_rect) {
            let landed = (inner.min.to_vec2() * ctx.pixels_per_point()).to_pos2();
            self.found = window_memory::frame_offset(requested, landed);
        }
        self.requested = None;
    }
}

impl DropApp {
    pub fn new(cc: &eframe::CreationContext<'_>, port: u16, files: Vec<PathBuf>) -> Self {
        let ctx = cc.egui_ctx.clone();
        style(&ctx);
        let (requests, worker_requests) = mpsc::channel();
        let (worker_replies, replies) = mpsc::channel();
        std::thread::spawn(move || {
            net::worker(port, worker_requests, worker_replies, move || {
                ctx.request_repaint()
            })
        });
        Self {
            port,
            requests,
            replies,
            in_flight: 0,
            last_poll: None,
            link: Link::Connecting,
            target: Target::default(),
            outcome: Outcome::Idle,
            flash: None,
            startup: files,
            shutdown: ShutdownTimer::default(),
            #[cfg(target_os = "linux")]
            frame: FrameProbe::new(cc.storage),
        }
    }

    fn send(&mut self, request: Request) {
        if self.requests.send(request).is_ok() {
            self.in_flight += 1;
        }
    }

    fn poll(&mut self) {
        let due = self.last_poll.is_none_or(|t| t.elapsed() >= POLL);
        if due && self.in_flight == 0 {
            self.last_poll = Some(Instant::now());
            self.send(Request::Status);
        }
    }

    fn receive(&mut self, ctx: &egui::Context) {
        while let Ok(reply) = self.replies.try_recv() {
            self.in_flight = self.in_flight.saturating_sub(1);
            match reply {
                Reply::Status(r) => {
                    self.shutdown.reconnected();
                    self.link = Link::Online;
                    self.target = Target::from_records(&r);
                    if wire::text(&r, "summon") == "1" {
                        self.summon(ctx);
                    }
                }
                Reply::Dropped(r) => {
                    self.shutdown.reconnected();
                    self.link = Link::Online;
                    self.target = Target::from_records(&r);
                    let file = match &self.outcome {
                        Outcome::Sending(f) => f.clone(),
                        _ => String::new(),
                    };
                    let warnings = wire::text(&r, "warnings");
                    self.outcome = Outcome::Placed {
                        file,
                        summary: wire::text(&r, "result"),
                        detail: wire::text(&r, "where"),
                        warnings: warnings.lines().map(str::to_owned).collect(),
                    };
                    self.flash = Some((Instant::now(), P.ok));
                }
                Reply::Rejected(error) => {
                    self.shutdown.reconnected();
                    self.link = Link::Online;
                    self.fail(error);
                }
                Reply::Shutdown => {
                    self.shutdown.signal();
                }
                Reply::Offline => {
                    self.link = Link::Offline;
                    if let Outcome::Sending(_) = self.outcome {
                        self.fail(format!(
                            "Renoise is not reachable on port {}. Is the MIDI Drop tool installed?",
                            self.port
                        ));
                    }
                }
            }
        }
    }

    fn fail(&mut self, error: String) {
        let file = match &self.outcome {
            Outcome::Sending(f) => f.clone(),
            Outcome::Failed { file, .. } => file.clone(),
            _ => String::new(),
        };
        self.outcome = Outcome::Failed { file, error };
        self.flash = Some((Instant::now(), P.error));
    }

    /// Come back to the main screen and to the front, for a window that is lost
    /// (on a monitor that is gone, or behind other windows).
    fn summon(&mut self, ctx: &egui::Context) {
        ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(false));
        ctx.send_viewport_cmd(egui::ViewportCommand::OuterPosition(SUMMON_AT));
        ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
        self.flash = Some((Instant::now(), P.accent));
    }

    fn take_drops(&mut self, ctx: &egui::Context) {
        // One clip at a time, like a drop: only the first file is placed.
        if let Some(path) = std::mem::take(&mut self.startup).into_iter().next() {
            let name = file_name(&path, "");
            let data = std::fs::read(&path).map_err(|e| e.to_string());
            self.place(name, data);
            return;
        }
        let dropped = ctx.input(|i| i.raw.dropped_files.clone());
        let Some(file) = dropped.into_iter().next() else {
            return;
        };
        let name = file
            .path
            .as_deref()
            .map(|p| file_name(p, &file.name))
            .unwrap_or(file.name.clone());
        // Read now: plugins delete their temp file as soon as the drag ends.
        let data = match (&file.bytes, &file.path) {
            (Some(bytes), _) => Ok(bytes.to_vec()),
            (None, Some(path)) => std::fs::read(path).map_err(|e| e.to_string()),
            (None, None) => Err("the drop carried no file".to_string()),
        };
        self.place(name, data);
    }

    fn place(&mut self, name: String, data: Result<Vec<u8>, String>) {
        let is_midi = Path::new(&name)
            .extension()
            .map(|e| e.eq_ignore_ascii_case("mid") || e.eq_ignore_ascii_case("midi"))
            .unwrap_or(false);
        self.outcome = Outcome::Sending(name.clone());
        if !is_midi {
            self.fail("Not a MIDI file (.mid or .midi)".into());
            return;
        }
        match data {
            Ok(data) => self.send(Request::Drop { name, data }),
            Err(e) => self.fail(format!("Could not read the file: {e}")),
        }
    }
}

fn file_name(path: &Path, fallback: &str) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| fallback.to_string())
}

impl eframe::App for DropApp {
    /// eframe saves the window position and size by itself (`persistence`);
    /// nothing else of the UI needs to survive a restart.
    fn persist_egui_memory(&self) -> bool {
        false
    }

    /// eframe has just put the window settings into `storage`; fix their outer
    /// position before it writes them to disk.
    #[cfg(target_os = "linux")]
    fn save(&mut self, storage: &mut dyn eframe::Storage) {
        let Some(frame) = self.frame.found else {
            return;
        };
        if let Some(saved) = eframe::get_value(storage, window_memory::KEY) {
            let fixed = window_memory::corrected(saved, frame);
            eframe::set_value(storage, window_memory::KEY, &fixed);
        }
    }

    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        #[cfg(target_os = "linux")]
        self.frame.update(ctx);
        self.receive(ctx);
        if self.shutdown.expired(Instant::now()) {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
        self.take_drops(ctx);
        self.poll();
        ctx.request_repaint_after(POLL);

        let hovering = ctx.input(|i| !i.raw.hovered_files.is_empty());
        let flash = self.flash.and_then(|(t, c)| {
            let k = t.elapsed().as_secs_f32() / FLASH.as_secs_f32();
            (k < 1.0).then(|| {
                ctx.request_repaint();
                (c, 1.0 - k)
            })
        });

        egui::CentralPanel::default()
            .frame(egui::Frame::new().fill(P.bg).inner_margin(MARGIN))
            .show(ctx, |ui| {
                let full = ui.available_rect_before_wrap();
                let header = Rect::from_min_size(full.min, vec2(full.width(), 22.0));
                let footer_h = 58.0;
                let footer =
                    Rect::from_min_max(pos2(full.left(), full.bottom() - footer_h), full.max);
                let zone = Rect::from_min_max(
                    pos2(full.left(), header.bottom() + GAP),
                    pos2(full.right(), footer.top() - GAP),
                );
                ui.allocate_rect(full, Sense::hover());
                let painter = ui.painter();

                self.paint_header(painter, header);
                self.paint_zone(painter, zone, hovering, flash);
                self.paint_footer(painter, footer);
            });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shutdown_expires_after_the_grace_period() {
        let started = Instant::now();
        let timer = ShutdownTimer {
            started: Some(started),
        };
        assert!(!timer.expired(started + SHUTDOWN_GRACE - Duration::from_millis(1)));
        assert!(timer.expired(started + SHUTDOWN_GRACE));
    }

    #[test]
    fn reconnect_cancels_the_pending_shutdown() {
        let mut timer = ShutdownTimer {
            started: Some(Instant::now()),
        };
        timer.reconnected();
        assert!(!timer.expired(Instant::now() + SHUTDOWN_GRACE));
    }
}

impl DropApp {
    fn paint_header(&self, painter: &egui::Painter, rect: Rect) {
        painter.text(
            rect.left_center(),
            Align2::LEFT_CENTER,
            "MIDI Drop",
            FontId::proportional(16.0),
            P.text,
        );
        let (dot, label) = match self.link {
            Link::Connecting => (P.muted, "Connecting…".to_string()),
            Link::Online => (P.ok, "Renoise connected".to_string()),
            Link::Offline => (P.error, format!("Renoise offline · port {}", self.port)),
        };
        let galley = painter.layout_no_wrap(label, FontId::proportional(12.0), P.muted);
        let text_pos = pos2(
            rect.right() - galley.size().x,
            rect.center().y - galley.size().y / 2.0,
        );
        painter.circle_filled(pos2(text_pos.x - 9.0, rect.center().y), 4.0, dot);
        painter.galley(text_pos, galley, P.muted);
    }

    fn paint_zone(
        &self,
        painter: &egui::Painter,
        rect: Rect,
        hovering: bool,
        flash: Option<(Color32, f32)>,
    ) {
        let radius = CornerRadius::same(ZONE_RADIUS);
        let fill = if hovering {
            mix(P.zone, P.accent, 0.14)
        } else if let Some((c, k)) = flash {
            mix(P.zone, c, 0.16 * k)
        } else {
            P.zone
        };
        painter.rect_filled(rect, radius, fill);

        if hovering {
            painter.rect_stroke(rect, radius, Stroke::new(2.0, P.accent), StrokeKind::Inside);
        } else {
            let color = flash.map(|(c, k)| mix(P.border, c, k)).unwrap_or(P.border);
            let mut path: Vec<Pos2> = Vec::new();
            rounded_rectangle(&mut path, rect.shrink(1.0), radius.into());
            if let Some(first) = path.first().copied() {
                path.push(first);
            }
            painter.extend(Shape::dashed_line(&path, Stroke::new(1.5, color), 7.0, 5.0));
        }

        let inner = rect.shrink2(vec2(20.0, 16.0));
        let wrap = inner.width();
        let title = match (&self.link, hovering) {
            (_, true) => "Release to place",
            (Link::Offline, _) => "Waiting for Renoise",
            _ => "Drop MIDI here",
        };
        let mut lines = vec![(title.to_string(), FontId::proportional(21.0), P.text)];
        match self.link {
            Link::Offline => lines.push((
                format!(
                    "Start Renoise with the MIDI Drop tool installed. It listens on port {}.",
                    self.port
                ),
                FontId::proportional(12.5),
                P.muted,
            )),
            _ if !self.target.line.is_empty() => {
                let color = if self.target.ready { P.text } else { P.warn };
                lines.push((self.target.line.clone(), FontId::proportional(13.0), color));
                if !self.target.position.is_empty() {
                    lines.push((
                        self.target.position.clone(),
                        FontId::proportional(12.0),
                        P.muted,
                    ));
                }
                for detail in self.target.detail.lines() {
                    lines.push((detail.to_string(), FontId::proportional(12.0), P.muted));
                }
            }
            _ => {}
        }

        let galleys: Vec<_> = lines
            .into_iter()
            .map(|(t, f, c)| {
                let mut job = LayoutJob::simple(t, f, c, wrap);
                job.halign = Align::Center;
                painter.layout_job(job)
            })
            .collect();
        // Title, a wider gap, then the target lines close together.
        let gap = |i: usize| if i == 0 { 10.0 } else { 4.0 };
        let total: f32 = galleys.iter().map(|g| g.size().y).sum::<f32>()
            + (0..galleys.len().saturating_sub(1)).map(gap).sum::<f32>();
        let mut y = inner.center().y - total / 2.0;
        for (i, g) in galleys.into_iter().enumerate() {
            // Centered rows: shift so the galley's own bounds sit on the center line.
            let x = inner.center().x - g.rect.center().x;
            let h = g.size().y;
            painter.galley(pos2(x, y), g, P.text);
            y += h + gap(i);
        }
    }

    fn paint_footer(&self, painter: &egui::Painter, rect: Rect) {
        let wrap = rect.width();
        // (text, size, color, max rows): long plugin file names are elided, not wrapped.
        let mut lines: Vec<(String, f32, Color32, usize)> = Vec::new();
        match &self.outcome {
            Outcome::Idle => {
                lines.push((
                    "Keep this window beside your plugin, drag MIDI onto it.".into(),
                    12.0,
                    P.muted,
                    1,
                ));
                lines.push((
                    "Undo in Renoise removes a drop in one step.".into(),
                    12.0,
                    P.muted,
                    1,
                ));
            }
            Outcome::Sending(file) => lines.push((format!("Sending {file}…"), 12.5, P.muted, 1)),
            Outcome::Placed {
                file,
                summary,
                detail,
                warnings,
            } => {
                lines.push((format!("✔  {summary}  ·  {file}"), 13.0, P.ok, 1));
                match warnings.first() {
                    Some(w) => lines.push((w.clone(), 12.0, P.warn, 2)),
                    None => lines.push((format!("Placed at {detail}"), 12.0, P.muted, 1)),
                }
            }
            Outcome::Failed { file, error } => {
                let head = if file.is_empty() {
                    "Not placed".to_string()
                } else {
                    format!("Not placed: {file}")
                };
                lines.push((head, 13.0, P.error, 1));
                lines.push((error.clone(), 12.0, P.muted, 2));
            }
        }
        let mut y = rect.top() + 6.0;
        for (text, size, color, rows) in lines {
            let mut job = LayoutJob::simple(text, FontId::proportional(size), color, wrap);
            job.wrap.max_rows = rows;
            job.wrap.break_anywhere = rows == 1;
            job.wrap.overflow_character = Some('…');
            let g = painter.layout_job(job);
            let h = g.size().y;
            painter.galley(pos2(rect.left(), y), g, color);
            y += h + 4.0;
        }
    }
}

fn mix(a: Color32, b: Color32, t: f32) -> Color32 {
    let t = t.clamp(0.0, 1.0);
    let lerp = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round() as u8;
    Color32::from_rgb(lerp(a.r(), b.r()), lerp(a.g(), b.g()), lerp(a.b(), b.b()))
}

fn style(ctx: &egui::Context) {
    ctx.set_visuals(egui::Visuals::dark());
    ctx.style_mut(|s| {
        s.visuals.panel_fill = P.bg;
        s.visuals.window_fill = P.bg;
    });
}
