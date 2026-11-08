//! Remembering where the window was, on Linux.
//!
//! eframe (`persistence` feature) saves the window's position and size under the
//! key `"window"` and restores them on the next start. It restores the *outer*
//! position (frame included) on Linux. Under X11, winit can report the outer
//! position as equal to the inner one, for example with GNOME (Mutter) on
//! XWayland. The window then came back one title bar lower on every start.
//!
//! The fix: once per session, compare where the inner window landed with the
//! outer position eframe asked for. The difference is the frame. When saving,
//! work out the outer position from the inner position and the frame.
//! Windows and macOS do not need this: eframe gets their positions right.

use eframe::egui::{Pos2, Vec2};
use serde::{Deserialize, Serialize};

/// eframe's storage key for the window settings.
pub const KEY: &str = "window";

/// The largest frame we believe, in pixels. A bigger difference means that the
/// window manager moved the window, for example to keep it on the screen.
const MAX_FRAME: f32 = 64.0;

/// The same fields as `egui_winit::WindowSettings`, which keeps them private.
/// Positions are in physical pixels, the size in points.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Saved {
    pub inner_position_pixels: Option<Pos2>,
    pub outer_position_pixels: Option<Pos2>,
    pub fullscreen: bool,
    pub maximized: bool,
    pub inner_size_points: Option<Vec2>,
}

/// The frame size: where the inner window landed minus the outer position that
/// was asked for. `None` when that does not look like a window frame.
pub fn frame_offset(requested_outer: Pos2, landed_inner: Pos2) -> Option<Vec2> {
    let d = landed_inner - requested_outer;
    let plausible = |v: f32| (0.0..=MAX_FRAME).contains(&v);
    (plausible(d.x) && plausible(d.y)).then_some(d)
}

/// `saved` with the outer position worked out from the inner position.
pub fn corrected(mut saved: Saved, frame: Vec2) -> Saved {
    if let Some(inner) = saved.inner_position_pixels {
        saved.outer_position_pixels = Some(inner - frame);
    }
    saved
}

#[cfg(test)]
mod tests {
    use super::*;
    use eframe::egui::{pos2, vec2};

    #[test]
    fn learns_a_title_bar() {
        assert_eq!(
            frame_offset(pos2(200.0, 150.0), pos2(200.0, 178.0)),
            Some(vec2(0.0, 28.0))
        );
        assert_eq!(
            frame_offset(pos2(10.0, 10.0), pos2(18.0, 41.0)),
            Some(vec2(8.0, 31.0))
        );
        assert_eq!(
            frame_offset(pos2(5.0, 5.0), pos2(5.0, 5.0)),
            Some(vec2(0.0, 0.0))
        );
    }

    #[test]
    fn ignores_moves_that_are_not_a_frame() {
        // Pulled back onto the screen, or moved up or left.
        assert_eq!(frame_offset(pos2(3000.0, 150.0), pos2(1500.0, 178.0)), None);
        assert_eq!(frame_offset(pos2(200.0, 150.0), pos2(200.0, 140.0)), None);
        assert_eq!(frame_offset(pos2(200.0, 150.0), pos2(200.0, 400.0)), None);
    }

    #[test]
    fn saves_the_outer_position_from_the_inner_one() {
        let saved = Saved {
            inner_position_pixels: Some(pos2(200.0, 178.0)),
            outer_position_pixels: Some(pos2(200.0, 178.0)),
            inner_size_points: Some(vec2(420.0, 320.0)),
            ..Default::default()
        };
        let fixed = corrected(saved.clone(), vec2(0.0, 28.0));
        assert_eq!(fixed.outer_position_pixels, Some(pos2(200.0, 150.0)));
        assert_eq!(fixed.inner_position_pixels, saved.inner_position_pixels);
        assert_eq!(fixed.inner_size_points, saved.inner_size_points);
        // Nothing to work from: leave it alone.
        assert_eq!(
            corrected(Saved::default(), vec2(0.0, 28.0)),
            Saved::default()
        );
    }

    #[test]
    fn reads_what_eframe_writes() {
        // Copied from a real app.ron (eframe 0.33, Linux).
        let ron = "(inner_position_pixels:Some((x:1090.0,y:562.0)),\
                   outer_position_pixels:Some((x:1090.0,y:562.0)),\
                   fullscreen:false,maximized:false,\
                   inner_size_points:Some((x:380.0,y:300.0)))";
        let mut storage = Memory::default();
        eframe::Storage::set_string(&mut storage, KEY, ron.to_owned());
        let saved: Saved = eframe::get_value(&storage, KEY).expect("decodes");
        assert_eq!(saved.inner_position_pixels, Some(pos2(1090.0, 562.0)));
        assert_eq!(saved.inner_size_points, Some(vec2(380.0, 300.0)));
        eframe::set_value(&mut storage, KEY, &saved);
        let again: Saved = eframe::get_value(&storage, KEY).expect("round trip");
        assert_eq!(again, saved);
    }

    #[derive(Default)]
    struct Memory(std::collections::HashMap<String, String>);

    impl eframe::Storage for Memory {
        fn get_string(&self, key: &str) -> Option<String> {
            self.0.get(key).cloned()
        }
        fn set_string(&mut self, key: &str, value: String) {
            self.0.insert(key.to_owned(), value);
        }
        fn flush(&mut self) {}
    }
}
