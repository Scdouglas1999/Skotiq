//! The field scale a solve is told, and what a solve measures of it.

use crate::device::{ConnectionState, DeviceType};

/// The field-scale facts a solve can be told up front.
///
/// A solver given no scale has to find one. ASTAP sweeps its field-of-view
/// ladder downward from ~9.5°, and on a narrow field that sweep is the
/// difference between a 0.3 s solve and five consecutive failures on the same
/// frames, same catalogs, same sensor. Both numbers here are measured rather
/// than assumed — the focal length is the operator's own profile entry and the
/// pitch is what the camera reports — so a rig that reports neither contributes
/// no card and the solver behaves exactly as it did before.
///
/// Gather once per solve with [`gather_solve_hints`] and hand the result to
/// whichever writer stamps the frame the solver will read: the solver never
/// sees these values as flags, it reads them out of the FITS header.
#[derive(Debug, Clone)]
pub(crate) struct SolveHints {
    /// Telescope focal length in millimetres (FITS `FOCALLEN`).
    pub(crate) focal_length_mm: Option<f64>,
    /// UNBINNED sensor pixel pitch in microns, `(x, y)` (FITS `PIXSIZE1/2`).
    pub(crate) pixel_size_um: Option<(f64, f64)>,
    /// Binning the frame was taken at. `XPIXSZ`/`YPIXSZ` are the pitch scaled
    /// by it, which is what a solver needs to derive the plate scale.
    pub(crate) binning: (i32, i32),
}

impl Default for SolveHints {
    fn default() -> Self {
        Self {
            focal_length_mm: None,
            pixel_size_um: None,
            // Unbinned, so a caller that never learned the binning still
            // stamps a truthful pitch rather than zeroing it.
            binning: (1, 1),
        }
    }
}

/// Plate scale in arcsec per UNBINNED pixel, per camera id, as measured by the
/// most recent successful solve on that camera.
///
/// Normalised to unbinned on the way in and scaled back up on the way out, so
/// one remembered number serves every binning the rig images at.
///
/// Process-global for the same reason [`ACTIVE_SOLVER_PREF`] is: the solve call
/// sites sit deep in the call stack with nowhere to thread a parameter. Session
/// lifetime only — the first solve after a restart still has to sweep, and
/// promoting this to the durable profile store is the obvious next step. It is
/// not a substitute for the focal length: an operator who enters the real focal
/// length gets the computed scale, which is authoritative and binning-exact.
///
/// [`ACTIVE_SOLVER_PREF`]: skotiq_imaging
static MEASURED_PLATE_SCALE: std::sync::LazyLock<
    std::sync::RwLock<std::collections::HashMap<String, f64>>,
> = std::sync::LazyLock::new(|| std::sync::RwLock::new(std::collections::HashMap::new()));

impl SolveHints {
    /// The header `frame` is written to the solver with: the exposure's own
    /// facts and these scale cards, through the header a saved capture gets,
    /// so a solver cannot tell a solve frame from a light frame. It names no
    /// pointing; a caller that trusts a position sets `ra`/`dec`.
    pub(crate) fn solve_frame_header(
        &self,
        frame: &skotiq_sequencer::ImageData,
    ) -> crate::frame_header::FrameHeader {
        let started_at =
            chrono::DateTime::from_timestamp(frame.timestamp, 0).unwrap_or_else(chrono::Utc::now);
        crate::frame_header::FrameHeader {
            object_name: Some("Plate Solve".to_string()),
            exposure_time: frame.exposure_secs,
            capture_timestamp: started_at.to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            frame_type: "Light".to_string(),
            filter: frame.filter.clone(),
            gain: frame.gain,
            offset: frame.offset,
            ccd_temp: frame.temperature,
            bin_x: self.binning.0,
            bin_y: self.binning.1,
            focal_length: self.focal_length_mm,
            pixel_size_x: self.pixel_size_um.map(|(x, _)| x),
            pixel_size_y: self.pixel_size_um.map(|(_, y)| y),
            bayer_pattern: frame.color_filter.as_ref().map(|p| p.letters()),
            ..Default::default()
        }
    }

    /// The plate scale these hints describe, in arcsec per pixel **of the
    /// frame as taken** — pitch scaled by binning, which is the number a
    /// solver turns into a field size.
    ///
    /// This is the value the solver is handed as `-fov`.
    pub(crate) fn arcsec_per_px(&self) -> Option<f64> {
        let focal = self.focal_length_mm.filter(|f| f.is_finite() && *f > 0.0)?;
        let (pitch_x, _) = self.pixel_size_um?;
        let binned_pitch = pitch_x * f64::from(self.binning.0.max(1));
        let scale = 206.264_806 * binned_pitch / focal;
        scale.is_finite().then_some(scale).filter(|s| *s > 0.0)
    }
}

/// One solve's field-scale facts, the camera they were read from, and what an
/// earlier solve on that camera measured.
///
/// [`SolveHints`] is a bridged type and stays exactly the set of cards that go
/// into the FITS header. This wraps it with the two things a header has no slot
/// for: WHICH camera the pitch came from, and the scale this rig's own optics
/// have already been measured at.
#[derive(Debug, Clone)]
pub(crate) struct SolveScale {
    /// The cards the frame's header is stamped from.
    pub(crate) hints: SolveHints,
    /// The camera [`SolveHints::pixel_size_um`] was read from, when one was
    /// resolved. Also the key a measurement is remembered under.
    pub(crate) camera_id: Option<String>,
    /// Plate scale in arcsec per UNBINNED pixel, as MEASURED by an earlier
    /// successful solve on [`Self::camera_id`] this session.
    ///
    /// The weaker of the two sources and only consulted when the profile
    /// cannot supply a focal length — but it is a real measurement of the rig
    /// in front of the operator rather than a number typed into a form, and it
    /// was the one available on the night this was written: the owner's first
    /// solve measured 0.7877"/px on a sensor reporting 3.8 um, i.e. 995 mm,
    /// while every later solve that night was still told nothing and had to
    /// sweep for the scale. One of those sweeps is what made the
    /// drift-recenter time out.
    measured_arcsec_per_px: Option<f64>,
    /// Whether this frame is [`Self::camera_id`]'s own frame, so what its
    /// solve measures is that camera's scale.
    learns_from_solve: bool,
}

impl SolveScale {
    /// The scale to hand this solve, in arcsec per pixel of the frame as
    /// taken: computed from the optics when the profile can supply them, else
    /// carried over from what this camera's last solve measured.
    pub(crate) fn arcsec_per_px(&self) -> Option<f64> {
        self.hints
            .arcsec_per_px()
            .or_else(|| self.remembered_arcsec_per_px())
    }

    /// The scale an earlier solve on this camera MEASURED, scaled to the
    /// binning this frame was taken at.
    fn remembered_arcsec_per_px(&self) -> Option<f64> {
        let unbinned = self
            .measured_arcsec_per_px
            .filter(|s| s.is_finite() && *s > 0.0)?;
        let scale = unbinned * f64::from(self.hints.binning.0.max(1));
        scale.is_finite().then_some(scale).filter(|s| *s > 0.0)
    }

    /// The focal length this rig's measured scale implies, for operator-facing
    /// copy. `None` unless both a measurement and a pitch are in hand.
    fn implied_focal_length_mm(&self) -> Option<f64> {
        let unbinned = self
            .measured_arcsec_per_px
            .filter(|s| s.is_finite() && *s > 0.0)?;
        let (pitch_x, _) = self.hints.pixel_size_um?;
        let focal = 206.264_806 * pitch_x / unbinned;
        focal.is_finite().then_some(focal).filter(|f| *f > 0.0)
    }

    /// Remember what a successful solve measured, so the next solve on this
    /// camera can be told the scale instead of sweeping for it.
    ///
    /// Recorded per camera and normalised to unbinned. A solve whose scale was
    /// already computed from the optics is recorded too: it costs nothing and
    /// keeps the memory warm for a later run whose profile has been edited.
    pub(crate) fn record_measured_scale(&self, solved_arcsec_per_px: f64) {
        let Some(camera_id) = self.camera_id.as_deref().filter(|_| self.learns_from_solve) else {
            return;
        };
        if !solved_arcsec_per_px.is_finite() || solved_arcsec_per_px <= 0.0 {
            return;
        }
        let unbinned = solved_arcsec_per_px / f64::from(self.hints.binning.0.max(1));
        if !unbinned.is_finite() || unbinned <= 0.0 {
            return;
        }
        MEASURED_PLATE_SCALE
            .write()
            .expect("measured-scale RwLock")
            .insert(camera_id.to_string(), unbinned);
    }

    /// Three outcomes: a hint computed from the optics, a hint carried over
    /// from what this rig's own solve measured, and no hint at all. The
    /// warning names only the input that is missing.
    pub(crate) fn log_scale(&self, context: &str) {
        if let (Some(focal), Some((pitch_x, _))) =
            (self.hints.focal_length_mm, self.hints.pixel_size_um)
        {
            tracing::info!(
                "{} scale hint: focal length {:.1} mm, pixel pitch {:.2} um \
                 ({:.2}\"/px unbinned)",
                context,
                focal,
                pitch_x,
                206.264_806 * pitch_x / focal
            );
            return;
        }

        if let Some(scale) = self.remembered_arcsec_per_px() {
            tracing::info!(
                "{} scale hint {:.4}\"/px, MEASURED by an earlier solve on camera {}{}. No \
                 focal length is set on the active equipment profile; set it and the scale is \
                 computed exactly instead of carried over.",
                context,
                scale,
                self.camera_id.as_deref().unwrap_or("(unknown)"),
                self.implied_focal_length_mm()
                    .map_or_else(String::new, |focal| format!(
                        " (implying a focal length of {focal:.0} mm)"
                    )),
            );
            return;
        }

        // Each arm says what is missing, where it comes from, and what is
        // already in hand.
        let missing = self.missing_scale_input();
        tracing::warn!(
            "{} has no field-scale hint: {missing}. The solver must search for the scale, \
             which is slower and can fail on a field it would otherwise solve. The first \
             successful solve on this camera is remembered and hints every solve after it.",
            context,
        );
    }

    /// Which of the two scale inputs this solve is missing, as an
    /// operator-facing clause. Only reached when at least one is absent.
    fn missing_scale_input(&self) -> String {
        match (self.hints.focal_length_mm, self.hints.pixel_size_um) {
            (None, None) => "no telescope focal length (no active equipment profile, or none \
                             set on it) and no pixel pitch (no camera resolved, or its driver \
                             reports none)"
                .to_string(),
            (None, Some((pitch_x, _))) => format!(
                "no telescope focal length on the active equipment profile — the camera's \
                 {pitch_x:.2} um pitch on its own cannot give a scale. Set the focal length \
                 there"
            ),
            (Some(focal), None) => format!(
                "no pixel pitch (no camera resolved, or its driver reports none) — the \
                 profile's {focal:.1} mm focal length on its own cannot give a scale. Connect \
                 the imaging camera, or name it on the active profile"
            ),
            // Both present is the computed branch above.
            (Some(_), Some(_)) => unreachable!("handled by the computed branch"),
        }
    }
}

/// Read the active profile's optics and the active camera's pixel pitch so a
/// solve of that camera's frame can be told the field scale. A camera that
/// cannot be queried is logged and skipped, never guessed at.
pub(crate) async fn gather_solve_hints() -> SolveScale {
    gather_solve_hints_for_camera(None).await
}

impl SolveScale {
    /// The scale context of a frame read from disk: the profile's optics and
    /// camera, as [`gather_solve_hints`] reads them. The frame's solve teaches
    /// that camera's scale only when the frame is the camera's whole sensor at
    /// the binning the camera is set to; a cropped, stacked-and-drizzled or
    /// imported frame does not.
    pub(crate) async fn for_frame_file(path: &std::path::Path) -> Self {
        let (mut scale, camera_frame) = gather(None).await;
        scale.learns_from_solve =
            camera_frame.is_some() && camera_frame == skotiq_platesolve::fits_frame_size(path);
        scale
    }
}

/// As [`gather_solve_hints`], but for a caller that is imaging through a
/// camera of its own rather than the profile's imaging camera.
///
/// The pitch has to come from the camera that took the frame: stamping the
/// profile camera's pitch onto a frame from a different sensor would hand the
/// solver a confidently wrong scale, which is worse than handing it none.
pub(crate) async fn gather_solve_hints_for_camera(camera_id: Option<&str>) -> SolveScale {
    gather(camera_id).await.0
}

/// The scale context of the camera's frame, and the size in pixels of that
/// camera's whole frame at its binning when it reports one.
async fn gather(camera_id: Option<&str>) -> (SolveScale, Option<(u32, u32)>) {
    let mut scale = SolveScale {
        hints: SolveHints::default(),
        camera_id: None,
        measured_arcsec_per_px: None,
        learns_from_solve: true,
    };
    let mut camera_frame = None;
    let hints = &mut scale.hints;

    // The two facts come from two independent sources and neither gates the
    // other: the pitch is the camera's to report, not the profile's.
    let profile = crate::state::get_state().get_profile().await;

    hints.focal_length_mm = profile
        .as_ref()
        .map(|p| p.telescope_focal_length)
        .filter(|focal| focal.is_finite() && *focal > 0.0);

    // The camera that took the frame, in order of how well each source knows
    // it: the caller's own, then the profile's imaging camera, then the one
    // camera that is actually connected.
    //
    // That last rung matters: `profile.camera_id` is unset on a rig whose
    // devices were connected from the Equipment screen without being saved
    // into the profile, and the connected camera still knows its pixel pitch.
    //
    // Exactly one connected camera, though. Two means guessing which sensor
    // the frame came off, and the pitch of the WRONG sensor is a confidently
    // wrong scale — worse than none, as this module's own note above says.
    let resolved_camera_id = match camera_id {
        Some(id) => Some(id.to_string()),
        None => match profile.as_ref().and_then(|p| p.camera_id.clone()) {
            Some(id) => Some(id),
            None => {
                let connected: Vec<String> = crate::device_manager::get_device_manager()
                    .get_devices_by_type(DeviceType::Camera)
                    .await
                    .into_iter()
                    .filter(|d| d.connection_state == ConnectionState::Connected)
                    .map(|d| d.info.id)
                    .collect();
                match connected.as_slice() {
                    [only] => {
                        tracing::debug!(
                            "Plate solve: no imaging camera on the active profile; reading the \
                             pixel pitch from the one connected camera '{}'",
                            only
                        );
                        Some(only.clone())
                    }
                    [] => None,
                    many => {
                        tracing::debug!(
                            "Plate solve: no imaging camera on the active profile and {} \
                             cameras are connected; solving without a pixel-scale hint rather \
                             than guessing which sensor took the frame",
                            many.len()
                        );
                        None
                    }
                }
            }
        },
    };

    let Some(camera_id) = resolved_camera_id else {
        return (scale, camera_frame);
    };

    match crate::api::devices::camera::get_camera_status(camera_id.clone()).await {
        Ok(status) => {
            // 0.0 is a driver saying "I don't know", not a pitch.
            if status.pixel_size_x > 0.0 && status.pixel_size_y > 0.0 {
                hints.pixel_size_um = Some((status.pixel_size_x, status.pixel_size_y));
            }
            if status.bin_x > 0 && status.bin_y > 0 {
                hints.binning = (status.bin_x, status.bin_y);
                camera_frame = Some((
                    status.sensor_width / status.bin_x.unsigned_abs(),
                    status.sensor_height / status.bin_y.unsigned_abs(),
                ))
                .filter(|&(width, height)| width > 0 && height > 0);
            }
        }
        Err(e) => tracing::debug!(
            "Plate solve: camera '{}' status unavailable ({}); solving without a \
             pixel-scale hint",
            camera_id,
            e
        ),
    }

    scale.measured_arcsec_per_px = MEASURED_PLATE_SCALE
        .read()
        .expect("measured-scale RwLock")
        .get(&camera_id)
        .copied();
    scale.camera_id = Some(camera_id);

    (scale, camera_frame)
}

#[cfg(test)]
mod tests {
    use super::{SolveHints, SolveScale};

    fn frame() -> skotiq_sequencer::ImageData {
        skotiq_sequencer::ImageData {
            width: 2,
            height: 2,
            data: vec![0; 4],
            bits_per_pixel: 16,
            exposure_secs: 2.0,
            gain: None,
            offset: None,
            temperature: None,
            filter: None,
            timestamp: 1_789_000_000,
            sensor_type: None,
            color_filter: None,
            camera_file: None,
            readout_mode: None,
        }
    }

    /// `XPIXSZ` is the *binned* pitch — that is the number a solver turns into
    /// a plate scale. Stamping the unbinned pitch on a 2x2 frame would tell it
    /// the field is twice as wide as it is.
    #[test]
    fn xpixsz_is_the_pitch_the_frame_was_actually_taken_at() {
        let hints = SolveHints {
            focal_length_mm: Some(416.0),
            pixel_size_um: Some((3.76, 3.76)),
            binning: (2, 2),
        };
        let header = hints.solve_frame_header(&frame()).fits_header();

        assert_eq!(header.get_float("FOCALLEN"), Some(416.0));
        assert_eq!(header.get_float("PIXSIZE1"), Some(3.76));
        assert_eq!(header.get_float("XPIXSZ"), Some(7.52));
        assert_eq!(header.get_float("YPIXSZ"), Some(7.52));
        assert_eq!(header.get_int("XBINNING"), Some(2));
    }

    /// The scale handed to the solver is the scale of the frame as taken.
    /// 600 mm at 3.76 um is 1.29"/px unbinned and 2.59"/px at 2x2 — one of
    /// those two numbers describes the pixels ASTAP is about to measure.
    #[test]
    fn the_solver_scale_is_the_binned_sampling() {
        let unbinned = SolveHints {
            focal_length_mm: Some(600.0),
            pixel_size_um: Some((3.76, 3.76)),
            binning: (1, 1),
        };
        assert!((unbinned.arcsec_per_px().unwrap() - 1.292_59).abs() < 1e-4);

        let binned = SolveHints {
            binning: (2, 2),
            ..unbinned.clone()
        };
        assert!((binned.arcsec_per_px().unwrap() - 2.585_18).abs() < 1e-4);
    }

    /// A rig that reports no optics gets no hint — the solver searches, as it
    /// always did. A fabricated scale would be worse than none.
    #[test]
    fn missing_optics_produce_no_scale_rather_than_a_guess() {
        assert_eq!(SolveHints::default().arcsec_per_px(), None);
        assert_eq!(
            SolveHints {
                focal_length_mm: Some(600.0),
                pixel_size_um: None,
                binning: (1, 1),
            }
            .arcsec_per_px(),
            None
        );
        assert_eq!(
            SolveHints {
                focal_length_mm: Some(0.0),
                pixel_size_um: Some((3.76, 3.76)),
                binning: (1, 1),
            }
            .arcsec_per_px(),
            None
        );
    }

    /// The scale the app can DERIVE when the profile carries no focal length:
    /// what this rig's own last solve measured.
    ///
    /// The owner's numbers from 2026-09-15 — a solve that measured 0.7877"/px
    /// on an ASI1600MM reporting 3.8 um, i.e. 995 mm — because every solve
    /// after that one was still told nothing and had to sweep for the scale,
    /// and one of those sweeps is what made the drift-recenter time out.
    #[test]
    fn a_measured_scale_hints_the_next_solve_when_the_profile_has_no_focal_length() {
        let scale = SolveScale {
            hints: SolveHints {
                focal_length_mm: None,
                pixel_size_um: Some((3.8, 3.8)),
                binning: (1, 1),
            },
            camera_id: Some("native:zwo:1".to_string()),
            measured_arcsec_per_px: None,
            learns_from_solve: true,
        };
        assert_eq!(
            scale.arcsec_per_px(),
            None,
            "nothing has been measured yet, so there is nothing to carry over"
        );

        scale.record_measured_scale(0.7877);
        let next = SolveScale {
            measured_arcsec_per_px: super::MEASURED_PLATE_SCALE
                .read()
                .expect("measured-scale RwLock")
                .get("native:zwo:1")
                .copied(),
            ..scale.clone()
        };
        let hinted = next
            .arcsec_per_px()
            .expect("the next solve on this camera is hinted");
        assert!(
            (hinted - 0.7877).abs() < 1e-9,
            "the measurement carries over verbatim at the binning it was taken at, got {hinted}"
        );
        let implied = next
            .implied_focal_length_mm()
            .expect("a measured scale plus a known pitch implies a focal length");
        assert!(
            (implied - 995.0).abs() < 1.0,
            "0.7877\"/px at 3.8 um is a 995 mm scope, got {implied}"
        );
    }

    /// The warning must name what is MISSING, and only that.
    ///
    /// The first version of this branch printed "(focal length unknown, pixel
    /// pitch unknown)" whenever either input was absent, so a rig whose camera
    /// was reporting 3.8 um was told both were unknown. The replacement was
    /// then caught on a live run saying "this run knows the telescope focal
    /// length" about the one input it did not have — the same lie, inverted.
    #[test]
    fn the_warning_names_only_the_absent_input() {
        // No way to assert on `tracing` output here without a subscriber, so
        // the arms are asserted through the same match the warning uses.
        let pitch_only = SolveScale {
            hints: SolveHints {
                focal_length_mm: None,
                pixel_size_um: Some((3.8, 3.8)),
                binning: (1, 1),
            },
            camera_id: Some("pitch-only-camera".to_string()),
            measured_arcsec_per_px: None,
            learns_from_solve: true,
        };
        assert_eq!(
            pitch_only.missing_scale_input(),
            "no telescope focal length on the active equipment profile — the camera's 3.80 um \
             pitch on its own cannot give a scale. Set the focal length there"
        );

        let focal_only = SolveScale {
            hints: SolveHints {
                focal_length_mm: Some(995.0),
                pixel_size_um: None,
                binning: (1, 1),
            },
            camera_id: None,
            measured_arcsec_per_px: None,
            learns_from_solve: true,
        };
        assert!(
            focal_only
                .missing_scale_input()
                .starts_with("no pixel pitch"),
            "got: {}",
            focal_only.missing_scale_input()
        );
        assert!(
            focal_only.missing_scale_input().contains("995.0 mm"),
            "the input it DOES have is stated as held, not as missing"
        );

        let neither = SolveScale {
            hints: SolveHints::default(),
            camera_id: None,
            measured_arcsec_per_px: None,
            learns_from_solve: true,
        };
        let text = neither.missing_scale_input();
        assert!(text.starts_with("no telescope focal length"), "got: {text}");
        assert!(text.contains("and no pixel pitch"), "got: {text}");
    }

    /// Binning is not baked into the memory: a 2x2 frame is hinted at twice
    /// the sampling the 1x1 solve measured.
    #[test]
    fn a_measured_scale_rescales_to_the_binning_of_the_frame() {
        let one_by_one = SolveScale {
            hints: SolveHints {
                focal_length_mm: None,
                pixel_size_um: Some((3.8, 3.8)),
                binning: (1, 1),
            },
            camera_id: Some("bin-test-camera".to_string()),
            measured_arcsec_per_px: None,
            learns_from_solve: true,
        };
        one_by_one.record_measured_scale(0.7877);
        let remembered = super::MEASURED_PLATE_SCALE
            .read()
            .expect("measured-scale RwLock")
            .get("bin-test-camera")
            .copied();

        let two_by_two = SolveScale {
            hints: SolveHints {
                binning: (2, 2),
                ..one_by_one.hints.clone()
            },
            measured_arcsec_per_px: remembered,
            ..one_by_one.clone()
        };
        let hinted = two_by_two.arcsec_per_px().expect("hinted at 2x2");
        assert!(
            (hinted - 1.5754).abs() < 1e-6,
            "a 2x2 frame samples at twice the 1x1 scale, got {hinted}"
        );
    }

    /// The operator's own focal length is authoritative: a measurement never
    /// overrides the computed scale.
    #[test]
    fn the_computed_scale_outranks_a_measured_one() {
        let scale = SolveScale {
            hints: SolveHints {
                focal_length_mm: Some(600.0),
                pixel_size_um: Some((3.76, 3.76)),
                binning: (1, 1),
            },
            camera_id: Some("computed-wins-camera".to_string()),
            measured_arcsec_per_px: Some(9.99),
            learns_from_solve: true,
        };
        let hinted = scale.arcsec_per_px().expect("computed from the optics");
        assert!(
            (hinted - 1.292_59).abs() < 1e-4,
            "600 mm at 3.76 um is 1.29\"/px; the stale 9.99 must not win, got {hinted}"
        );
    }

    /// A frame that is not the camera's own (a crop, a drizzled stack, an
    /// imported file) teaches the camera nothing, whatever it solves at.
    #[test]
    fn a_frame_that_is_not_the_cameras_own_teaches_nothing() {
        let imported = SolveScale {
            hints: SolveHints::default(),
            camera_id: Some("not-its-frame-camera".to_string()),
            measured_arcsec_per_px: None,
            learns_from_solve: false,
        };
        imported.record_measured_scale(0.39);
        assert!(!super::MEASURED_PLATE_SCALE
            .read()
            .expect("measured-scale RwLock")
            .contains_key("not-its-frame-camera"));
    }

    /// A failed solve measures nothing, and a solve with no camera resolved has
    /// nowhere to record a measurement.
    #[test]
    fn nothing_usable_is_remembered_from_nothing_usable() {
        let no_camera = SolveScale {
            hints: SolveHints::default(),
            camera_id: None,
            measured_arcsec_per_px: None,
            learns_from_solve: true,
        };
        no_camera.record_measured_scale(1.0);
        assert!(
            !super::MEASURED_PLATE_SCALE
                .read()
                .expect("measured-scale RwLock")
                .values()
                .any(|v| (*v - 1.0).abs() < f64::EPSILON),
            "a solve with no camera resolved must not write under some other key"
        );

        let camera = SolveScale {
            camera_id: Some("rejects-garbage-camera".to_string()),
            ..no_camera
        };
        for garbage in [0.0, -1.0, f64::NAN, f64::INFINITY] {
            camera.record_measured_scale(garbage);
        }
        assert_eq!(
            super::MEASURED_PLATE_SCALE
                .read()
                .expect("measured-scale RwLock")
                .get("rejects-garbage-camera"),
            None,
            "a non-finite or non-positive scale is not a measurement"
        );
    }

    /// The default must be *unbinned*, not zeroed: a derived `Default` would
    /// give binning (0, 0) and multiply every pitch to 0.0 um, which is a
    /// confidently wrong scale rather than an absent one.
    #[test]
    fn default_hints_are_unbinned_and_stamp_no_scale_cards() {
        let hints = SolveHints::default();
        assert_eq!(hints.binning, (1, 1));

        let header = hints.solve_frame_header(&frame()).fits_header();
        assert_eq!(header.get_float("FOCALLEN"), None);
        assert_eq!(header.get_float("XPIXSZ"), None);
    }
}
