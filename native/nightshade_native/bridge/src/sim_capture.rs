//! The one place a simulated camera frame is produced.
//!
//! # Why this module exists
//!
//! There were two simulated-capture paths and only one rendered the sky:
//!
//! * the sequencer / DeviceManager download
//!   (`device_manager::ops::camera`) built a [`crate::sim_frame::SimFrameRequest`]
//!   carrying a [`SimSkyView`] and rendered the real catalogue field, while
//!   * the Imaging screen's manual capture (`api::imaging`) took a
//!     `device_id.starts_with("sim_")` shortcut into a `rand::thread_rng()`
//!     star painter that scattered stars at random positions.
//!
//! The consequence was measured, not theorised: two consecutive
//! `POST /api/camera/expose` captures at an identical mount pointing shared
//! ZERO of their 40 brightest stars, and ASTAP (D05 installed, correct hint)
//! detected 151 stars in the result and still reported `No solution found!`
//! at every FOV from 9.5 deg down to 0.4 deg. Anything that plate-solves —
//! Slew & Center, the framing wizard, mosaic tiles, meridian-flip recentre,
//! polar alignment — was therefore unexercisable offline even though the
//! renderer itself worked.
//!
//! Both callers now enter here, so a frame the sequencer can solve is the same
//! frame the Imaging screen gets. `sim_capture_has_no_rival_star_generator` in
//! this module fails the build if a third path is ever added.

use crate::sim_frame::{
    sim_frame_dimensions, sim_sky_field_radius_deg, synthesize_sim_frame, SimFrameRequest,
    SimSkyView, SIM_SKY_STAR_LIMIT,
};
use nightshade_native::camera::FrameType;

/// Matches `storage`'s own default, so a simulator run with no profile renders
/// the same field the default 1000 mm profile would.
pub(crate) const SIM_DEFAULT_FOCAL_LENGTH_MM: f64 = 1000.0;

/// Arcseconds subtended by one millimetre at one metre of focal length — the
/// 206265 in `scale = 206265 * pixel_um / focal_mm`.
const ARCSEC_PER_RADIAN: f64 = 206_264.806_247_096_36;

/// Unbinned plate scale, in arcseconds per pixel.
///
/// The one number the whole simulated sky hangs off: get it wrong and every
/// frame is rendered at a field of view the solver's hint contradicts, which
/// reads as "ASTAP cannot solve the simulator" rather than as an arithmetic bug.
pub(crate) fn sim_plate_scale_arcsec_per_px(pixel_size_um: f64, focal_length_mm: f64) -> f64 {
    ARCSEC_PER_RADIAN * (pixel_size_um / 1000.0) / focal_length_mm
}

/// The sky the simulated camera is pointing at, or `None` to keep painting the
/// pseudo-random field.
///
/// `None` whenever the simulator cannot honestly say what it is looking at or
/// what it would be matched against:
///
/// * no plate-solver catalogue configured, or the directory holds no `.1476`
///   files — rendering a sky the solver has no database for produces a frame
///   that cannot be solved, which is worse than not pretending; and
/// * no simulated mount connected — a camera-only rig has no pointing, and
///   inventing one would silently move every focus/HFR measurement the sim's own
///   test suite takes onto a different star field.
pub(crate) async fn sim_sky_view(
    pixel_size_um: f64,
    sensor_w: usize,
    sensor_h: usize,
) -> Option<SimSkyView> {
    if !pixel_size_um.is_finite() || pixel_size_um <= 0.0 {
        return None;
    }
    let (centre_ra_deg, centre_dec_deg) = {
        let mount = crate::api::devices::simulation::get_sim_mount()
            .read()
            .await;
        if !mount.status.connected {
            return None;
        }
        // The mount keeps coordinates of date (see `epoch::SimMountFrame`);
        // the catalogue, like the sky a real camera sees, is J2000. A mount
        // reading 22.8070h of date is looking at the stars catalogued at
        // 22.7892h, so the field is rendered there — which is also what makes
        // a plate solve of this frame disagree with the mount's read-back by
        // exactly the precession offset, as it does on the rig.
        let (ra_hours, dec_deg) = crate::device_manager::epoch::mount_frame_to_j2000(
            crate::device::DriverType::Simulator,
            mount.status.right_ascension,
            mount.status.declination,
        );
        (ra_hours * 15.0, dec_deg)
    };
    if !centre_ra_deg.is_finite() || !centre_dec_deg.is_finite() {
        return None;
    }

    // Reads the SAME preference the solver reads, so the simulated sky and the
    // catalogue ASTAP matches against are the same data by construction.
    let index = crate::sim_sky::configured_index()?;

    let rotation_deg = {
        let rotator = crate::api::devices::simulation::get_sim_rotator()
            .read()
            .await;
        if rotator.status.connected {
            rotator.status.position
        } else {
            0.0
        }
    };
    let focal_length_mm = crate::get_state()
        .get_profile()
        .await
        .map(|profile| profile.telescope_focal_length)
        .filter(|focal| focal.is_finite() && *focal > 0.0)
        .unwrap_or(SIM_DEFAULT_FOCAL_LENGTH_MM);

    let arcsec_per_px = sim_plate_scale_arcsec_per_px(pixel_size_um, focal_length_mm);
    let radius_deg = sim_sky_field_radius_deg(sensor_w, sensor_h, arcsec_per_px);
    let stars = index.field(
        centre_ra_deg,
        centre_dec_deg,
        radius_deg,
        SIM_SKY_STAR_LIMIT,
    );
    if stars.is_empty() {
        return None;
    }
    Some(SimSkyView {
        centre_ra_deg,
        centre_dec_deg,
        rotation_deg,
        arcsec_per_px,
        stars,
    })
}

/// What a caller must state to get a simulated frame.
///
/// Everything else — pointing, rotation, focus, guide offset, the noise seed —
/// is read from the live simulator singletons inside [`render_sim_frame`], so
/// two callers cannot disagree about the sky by supplying different halves of
/// it.
pub(crate) struct SimCaptureRequest {
    pub exposure_secs: f64,
    /// Sensor geometry as the camera ADVERTISED it, unbinned.
    pub sensor_width: u32,
    pub sensor_height: u32,
    pub pixel_size_um: f64,
    pub gain: i32,
    pub offset: i32,
    pub bin_x: u32,
    pub bin_y: u32,
    pub subframe: Option<(u32, u32, u32, u32)>,
    pub frame_type: FrameType,
    pub max_adu: u16,
}

/// A rendered simulated frame: 16-bit pixels plus the geometry they came out at
/// (binning and subframing both change it, so a caller must not re-derive it).
pub(crate) struct SimCaptureFrame {
    pub data: Vec<u16>,
    pub width: u32,
    pub height: u32,
}

/// Render one simulated frame of the sky the rig is currently pointing at.
///
/// THE simulated-capture entry point. Reads focuser defocus, guide/tracking
/// offset and mount pointing from the simulator singletons so every caller sees
/// the same sky, then hands off to the verified renderer in
/// [`crate::sim_frame`].
pub(crate) async fn render_sim_frame(request: SimCaptureRequest) -> SimCaptureFrame {
    // Star PSF tracks focuser defocus, so an autofocus run measured against
    // this frame is measuring something real.
    let focus_position = {
        let focuser = crate::api::devices::simulation::get_sim_focuser()
            .read()
            .await;
        if focuser.status.connected {
            // A cooling tube moves best focus outward (see
            // `NIGHTSHADE_SIM_NIGHT_COOLING_C_PER_HOUR`); a focuser left where
            // it was is that far out of focus.
            Some(
                focuser.status.position
                    - crate::api::devices::simulation::sim_thermal_focus_shift_steps(),
            )
        } else {
            None
        }
    };
    // NIGHTSHADE_SIM_REPLAY answers lights from a recorded night instead.
    if let (Some(replay), FrameType::Light) = (crate::sim_replay::armed(), request.frame_type) {
        let state = crate::sim_replay::RigState {
            exposure_s: request.exposure_secs,
            focuser_position: focus_position,
            pointing_deg: sim_pointing_deg().await,
            guiding: sim_rig_is_guiding().await,
        };
        return crate::sim_replay::capture(replay, &request, &state);
    }
    // Star position tracks the simulated mount, so guide pulses and tracking
    // drift are visible to whatever is measuring the frame.
    let (offset_x, offset_y) = crate::api::devices::simulation::sim_guide_offset_px().await;
    let sensor_w = request.sensor_width.max(1) as usize;
    let sensor_h = request.sensor_height.max(1) as usize;
    // Paint the sky the mount is actually on when the plate solver's own star
    // database is available.
    let sky = sim_sky_view(request.pixel_size_um, sensor_w, sensor_h).await;
    let frame_request = SimFrameRequest {
        width: sensor_w,
        height: sensor_h,
        exposure_secs: request.exposure_secs,
        gain: request.gain,
        offset: request.offset,
        frame_type: request.frame_type,
        focus_position,
        offset_x,
        offset_y,
        bin_x: request.bin_x.max(1),
        bin_y: request.bin_y.max(1),
        subframe: request.subframe,
        max_adu: request.max_adu,
        seed: crate::api::devices::simulation::next_sim_frame_seed(),
        sky,
    };
    let (width, height) = sim_frame_dimensions(&frame_request);
    let data = synthesize_sim_frame(&frame_request);
    SimCaptureFrame {
        data,
        width,
        height,
    }
}

/// Where the simulated mount points, in degrees, when it is connected.
async fn sim_pointing_deg() -> Option<(f64, f64)> {
    let mount = crate::api::devices::simulation::get_sim_mount()
        .read()
        .await;
    mount.status.connected.then(|| {
        (
            mount.status.right_ascension * 15.0,
            mount.status.declination,
        )
    })
}

/// Whether the rig's active guider reports guiding. No guider is not guiding.
async fn sim_rig_is_guiding() -> bool {
    let Some(guider_id) = crate::api::phd2::get_active_guider_id_for_ops().await else {
        return false;
    };
    crate::api::phd2::api_guider_get_status(guider_id)
        .await
        .is_ok_and(|status| status.state == "Guiding")
}

/// A plate-solver settings directory that outlives every test in the binary.
///
/// `state::init_platesolver_storage` is one-shot per process: the FIRST caller
/// fixes the directory for everyone. A test that passed it a local `TempDir`
/// therefore deleted the settings directory out from under every test that ran
/// later, the moment its own `TempDir` dropped — which is exactly how adding a
/// second sky test made `a_downloaded_frame_carries_the_catalogue_field` fail
/// with "Failed to write platesolver.json: No such file or directory" while
/// still passing alone. Leaking one directory for the process removes the
/// ordering dependency instead of hiding it behind test order.
#[cfg(test)]
pub(crate) fn shared_platesolver_store() -> &'static Path {
    use std::sync::OnceLock;
    static STORE: OnceLock<tempfile::TempDir> = OnceLock::new();
    let dir = STORE.get_or_init(|| tempfile::TempDir::new().expect("create platesolver store"));
    let _ = crate::state::init_platesolver_storage(dir.path().to_path_buf());
    dir.path()
}

#[cfg(test)]
use std::path::Path;

#[cfg(test)]
mod guard_tests {
    use std::path::{Path, PathBuf};

    /// The renderer and its catalogue/index code are allowed randomness:
    /// `sim_frame` draws seeded shot/read noise, `sim_sky` is the star source.
    const SANCTIONED: &[&str] = &[
        "bridge/src/sim_frame/mod.rs",
        "bridge/src/sim_sky.rs",
        "bridge/src/sim_capture.rs",
    ];
    /// Generated FFI glue is not hand-written capture code.
    const GENERATED: &[&str] = &["bridge/src/frb_generated.rs"];
    /// `NullDeviceOps` fabricates HFR and star positions, but it is a test
    /// double a release artifact cannot install. It has two entry points and
    /// both are closed: `api_sequencer_set_simulation_mode` refuses with
    /// NotSupported unless `cfg!(debug_assertions)`, and
    /// `ExecutionContext::new_for_test` is `#[cfg(test)]` so it does not exist
    /// in a release build. The first of those IS reachable from the network —
    /// `POST /api/sequencer/simulation` is a registered headless route
    /// (`apps/desktop/lib/headless_api/routes/sequencer_routes.dart:70`) — so
    /// the `cfg!(debug_assertions)` refusal is the whole of the gate, not a
    /// second line of defence behind an unexposed call. A shipped bundle
    /// carries a release-compiled bridge, so that route answers 400
    /// `simulation_mode_unavailable` instead of installing the double. `ExecutionContext::new` takes the device
    /// handle as an argument precisely so there is no third way in by default.
    /// `release_gate_still_guards_null_device_ops` below fails if the runtime
    /// gate stops being true, so this exemption cannot rot into a live path
    /// unnoticed.
    const RELEASE_GATED_TEST_DOUBLE: &[&str] = &["sequencer/src/device_ops.rs"];

    fn workspace_root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("bridge crate has a parent workspace dir")
            .to_path_buf()
    }

    /// Exemptions are keyed on the workspace-RELATIVE path, never the file
    /// name.
    ///
    /// Matching on the basename meant any file called `sim_frame.rs`,
    /// `sim_sky.rs`, `sim_capture.rs` or `device_ops.rs` — in any crate, any
    /// directory — inherited the exemption. A new `bridge/src/device_ops.rs`
    /// scattering random stars would then have been waved through by the very
    /// test written to catch it. `exemptions_do_not_travel_by_file_name` below
    /// fails if this goes back to comparing names.
    fn exemption_for(path: &Path) -> Option<&'static str> {
        let root = workspace_root();
        // The allowlist is written with `/`; Windows renders the same path with
        // `\`, so comparing raw exempts nothing there and the guard reports its
        // own detection strings as offenders.
        let relative = path
            .strip_prefix(&root)
            .ok()?
            .to_string_lossy()
            .replace('\\', "/");
        SANCTIONED
            .iter()
            .chain(GENERATED)
            .chain(RELEASE_GATED_TEST_DOUBLE)
            .find(|allowed| **allowed == relative)
            .copied()
    }

    /// Every `<crate>/src` in the native workspace.
    ///
    /// Deliberately not just this crate: the third random-star painter this
    /// guard exists to catch was in a SIBLING crate (`nightshade_imaging`'s
    /// `SimulatedCamera`), dead but public and one `use` away from becoming a
    /// live capture path again.
    fn workspace_src_roots() -> Vec<PathBuf> {
        let workspace = workspace_root();
        let mut roots = Vec::new();
        for entry in std::fs::read_dir(&workspace).expect("read workspace dir") {
            let src = entry.expect("dir entry").path().join("src");
            if src.is_dir() {
                roots.push(src);
            }
        }
        roots.sort();
        assert!(
            roots.len() >= 2,
            "expected several crates under {workspace:?}, found {roots:?}"
        );
        roots
    }

    fn rust_sources(dir: &Path, out: &mut Vec<PathBuf>) {
        for entry in std::fs::read_dir(dir).expect("read src dir") {
            let path = entry.expect("dir entry").path();
            if path.is_dir() {
                rust_sources(&path, out);
            } else if path.extension().and_then(|e| e.to_str()) == Some("rs") {
                out.push(path);
            }
        }
    }

    /// Fail the build if a THIRD simulated-capture path appears.
    ///
    /// The original defect was not that the random-star painter existed — it was
    /// that a second capture path quietly kept using it after the real-sky
    /// renderer landed, and nothing said so. Severing the call site the audit
    /// found proves that site was load-bearing, not that it was the only one.
    /// So this asserts the property directly: outside the sanctioned simulator
    /// modules, no bridge source may reach for a random number generator to
    /// place stars.
    ///
    /// If you are adding a legitimate new use of randomness, put the frame
    /// synthesis in `sim_frame`/`sim_sky` and call `sim_capture::render_sim_frame`
    /// rather than widening this allowlist.
    #[test]
    fn sim_capture_has_no_rival_star_generator() {
        let roots = workspace_src_roots();
        let mut files = Vec::new();
        for root in &roots {
            rust_sources(root, &mut files);
        }
        assert!(!files.is_empty(), "found no rust sources under {roots:?}");

        let mut offenders: Vec<String> = Vec::new();
        for path in files {
            if exemption_for(&path).is_some() {
                continue;
            }
            let text = match std::fs::read_to_string(&path) {
                Ok(text) => text,
                Err(_) => continue,
            };
            for (lineno, line) in text.lines().enumerate() {
                let code = line.trim_start();
                // Comments describing the history are fine; calls are not.
                if code.starts_with("//") || code.starts_with("*") || code.starts_with("///") {
                    continue;
                }
                let calls_rng = code.contains("thread_rng()")
                    || code.contains("gen_range(")
                    || code.contains("rand::random")
                    || code.contains("generate_simulated_image");
                if calls_rng {
                    offenders.push(format!(
                        "{}:{}: {}",
                        path.display(),
                        lineno + 1,
                        code.trim()
                    ));
                }
            }
        }

        assert!(
            offenders.is_empty(),
            "a simulated-capture path outside sim_frame/sim_sky/sim_capture is generating \
             its own random star field. Route it through \
             `crate::sim_capture::render_sim_frame` instead so the frame matches the sky the \
             plate solver is matching against.\n  {}",
            offenders.join("\n  ")
        );
    }

    /// An exemption must name one file, not a file NAME.
    ///
    /// The guard above is only as strong as its allowlist. Matching exemptions
    /// on the basename makes `sim_frame.rs`, `sim_sky.rs`, `sim_capture.rs` and
    /// `device_ops.rs` exempt in EVERY crate and directory — so a new
    /// `bridge/src/device_ops.rs` painting random stars is skipped by the one
    /// test written to catch exactly that. Verified against the real guard: a
    /// probe file containing `rand::thread_rng()` / `gen_range(` placed at
    /// `bridge/src/api/…` is reported by file:line, while the same probe at
    /// `bridge/src/api/nested/sim_frame.rs` is silently waved through.
    ///
    /// Both halves are asserted here: every allowlisted path must exist (so a
    /// rename cannot quietly widen the guard into a no-op) and a same-named
    /// file elsewhere must NOT inherit the exemption.
    #[test]
    fn exemptions_do_not_travel_by_file_name() {
        let root = workspace_root();
        let allowed: Vec<&str> = SANCTIONED
            .iter()
            .chain(GENERATED)
            .chain(RELEASE_GATED_TEST_DOUBLE)
            .copied()
            .collect();
        for relative in &allowed {
            let path = root.join(relative);
            assert!(
                path.is_file(),
                "the guard exempts {relative}, which no longer exists — the exemption is now \
                 dead weight and the file it was meant to cover is unguarded"
            );
            assert_eq!(
                exemption_for(&path),
                Some(*relative),
                "{relative} must be exempt at its own path"
            );

            let name = Path::new(relative)
                .file_name()
                .expect("allowlist entries are files");
            let impostor = root.join("bridge/src/api/nested").join(name);
            assert_eq!(
                exemption_for(&impostor),
                None,
                "{impostor:?} inherited {relative}'s exemption purely by file name; a third \
                 random-star painter could hide there"
            );
        }
    }

    /// The exemption granted to `NullDeviceOps` above is only sound while a
    /// release build physically cannot install it. The switch must keep
    /// refusing outside `debug_assertions`; if someone drops the gate, the
    /// sequencer could fit an autofocus V-curve to `rng.gen_range(1.5..3.0)`
    /// on a real night, so this fails loudly rather than letting the allowlist
    /// quietly become a lie.
    #[test]
    fn release_gate_still_guards_null_device_ops() {
        let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        // A slice, not an inline array: the guard is meant to grow as more
        // entrypoints install NullDeviceOps.
        const GUARDED: &[(&str, &str)] = &[(
            "api/sequencer/runtime_config.rs",
            "api_sequencer_set_simulation_mode",
        )];
        for (file, func) in GUARDED {
            let text = std::fs::read_to_string(src.join(file))
                .unwrap_or_else(|e| panic!("read {file}: {e}"));
            let start = text
                .find(func)
                .unwrap_or_else(|| panic!("{func} not found in {file}"));
            let body = &text[start..];
            let installs = body
                .find("NullDeviceOps")
                .unwrap_or_else(|| panic!("{func} no longer installs NullDeviceOps"));
            let gate = body
                .find("if enabled && !cfg!(debug_assertions)")
                .unwrap_or_else(|| panic!("{func} lost its release gate on simulation mode"));
            assert!(
                gate < installs,
                "{func} installs NullDeviceOps before checking the release gate"
            );
        }
    }
}
