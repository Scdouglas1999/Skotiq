use super::*;

/// The Imaging screen's capture must paint the sky the mount is on.
///
/// The guard for this file's half of the two-paths defect: a
/// `device_id.starts_with("sim_")` shortcut into a `rand::thread_rng()` star
/// painter on `POST /api/camera/expose` — what the Imaging screen calls —
/// while the sequencer's DeviceManager download renders the catalogue field.
/// Measured on the release build: two captures at an identical pointing share
/// zero of their 40 brightest stars, and ASTAP finds 151 stars and still
/// answers `No solution found!` at every FOV from 9.5 deg to 0.4 deg.
///
/// Deliberately asserted on `camera_start_exposure_configured_opt` — the
/// production call site — and not on the renderer, because the renderer was
/// never the broken part. Point this path back at a random generator and
/// the centre-star assertion fails: a random field has no reason to put a
/// star on the tangent point.
///
/// Needs no astap binary and no star database: it synthesises its own area
/// file and drives the real parser, index, projection and renderer.
#[tokio::test]
async fn the_manual_capture_path_renders_the_catalogue_sky() {
    use crate::api::devices::simulation::{get_sim_camera, get_sim_mount};

    let _serialized = crate::api::devices::simulation::sim_singleton_test_lock()
        .lock()
        .await;

    // A grid of catalogue stars centred on the pointing, spaced ~90 px at
    // the simulated rig's 0.776"/px so the detector resolves them apart.
    let ra_hours = 5.59_f64;
    let dec_deg = -5.39_f64;
    let ra_deg = ra_hours * 15.0;
    let step_deg =
        90.0 * crate::sim_capture::sim_plate_scale_arcsec_per_px(
            3.76,
            crate::sim_capture::SIM_DEFAULT_FOCAL_LENGTH_MM,
        ) / 3600.0;
    let mut stars = Vec::new();
    for row in -4i32..=4 {
        for col in -8i32..=8 {
            stars.push((
                ra_deg + f64::from(col) * step_deg / dec_deg.to_radians().cos(),
                dec_deg + f64::from(row) * step_deg,
                9.0 + f64::from((row + col).rem_euclid(5)),
            ));
        }
    }
    let catalog = tempfile::TempDir::new().unwrap();
    crate::sim_sky::astap_integration::write_synthetic_area(
        &catalog.path().join("d05_0001.1476"),
        &stars,
    );

    // Exactly what the Plate Solving settings screen writes. The store is
    // shared and process-lifetime on purpose — see
    // `sim_capture::shared_platesolver_store`.
    crate::sim_capture::shared_platesolver_store();
    let previous = crate::state::get_platesolver_preference().unwrap_or_default();
    crate::state::save_platesolver_preference(&crate::storage::PlateSolverPreference {
        catalog_path: catalog.path().to_string_lossy().to_string(),
        ..previous.clone()
    })
    .expect("save plate-solver preference");

    {
        // The simulated mount keeps coordinates of date; point it at the
        // grid's J2000 centre the way a slew would.
        let (mount_ra, mount_dec) = crate::device_manager::epoch::j2000_to_mount_frame(
            crate::device::DriverType::Simulator,
            ra_hours,
            dec_deg,
        );
        let mut mount = get_sim_mount().write().await;
        mount.status.connected = true;
        mount.status.right_ascension = mount_ra;
        mount.status.declination = mount_dec;
    }
    // So the field sits where the projection puts it rather than where an
    // earlier test's accumulated drift left it.
    crate::api::devices::simulation::reset_sim_guide_offset().await;
    get_sim_camera().write().await.status.connected = true;

    let device_id = "sim_manual_capture_sky".to_string();
    let capture = camera_start_exposure_configured_opt(
        device_id.clone(),
        1.0,
        Some(100),
        Some(10),
        1,
        1,
        None,
        nightshade_native::camera::FrameType::Light,
    )
    .await;

    let raw = get_last_raw_image_info(&device_id).await;

    // Put the singletons back before asserting, so a failure here does not
    // leave a catalogue sky armed for every other simulator test.
    get_sim_mount().write().await.status.connected = false;
    get_sim_camera().write().await.status.connected = false;
    let _ = crate::state::save_platesolver_preference(&previous);
    let _ = api_clear_device_image(device_id).await;

    capture.expect("simulated exposure should complete");
    let raw = raw
        .expect("raw image lookup should succeed")
        .expect("a raw frame should be stored");

    let data = nightshade_imaging::ImageData::from_u16(raw.width, raw.height, 1, &raw.data);
    let found = nightshade_imaging::detect_stars_with_stats(
        &data,
        &nightshade_imaging::StarDetectionConfig::default(),
    );
    assert!(
        found.stars.len() > 60,
        "the manual-capture frame carried {} stars; the catalogue grid holds {}, so the \
             sky view never reached this path",
        found.stars.len(),
        stars.len()
    );

    // Placed by the projection, not merely present: the grid's centre star
    // sits at the tangent point, which lands on the sensor's centre pixel at
    // any plate scale. A randomly scattered field fails this.
    let centre_x = f64::from(raw.width) / 2.0;
    let centre_y = f64::from(raw.height) / 2.0;
    let nearest = found
        .stars
        .iter()
        .map(|star| (star.x - centre_x).hypot(star.y - centre_y))
        .fold(f64::MAX, f64::min);
    assert!(
        nearest < 12.0,
        "nearest star to the frame centre is {nearest:.1} px away; the Imaging screen is \
             not rendering the field the mount is pointing at"
    );
}

/// HFR and eccentricity must be measured, not invented.
///
/// Reporting `Some(2.5 + random())` as HFR and `Some(0.15 + random())` as
/// eccentricity for a simulated frame makes the numbers move when nothing
/// about the optics has, and hides an autofocus or guiding regression. They
/// come from the same `detect_stars` the real-camera branch uses.
#[tokio::test]
async fn simulated_frame_stats_track_focus_instead_of_a_random_draw() {
    use crate::api::devices::simulation::{get_sim_camera, get_sim_focuser};

    let _serialized = crate::api::devices::simulation::sim_singleton_test_lock()
        .lock()
        .await;
    get_sim_camera().write().await.status.connected = true;

    async fn hfr_at_focus(position: i32, device_id: &str) -> Option<f64> {
        {
            let mut focuser = get_sim_focuser().write().await;
            focuser.status.connected = true;
            focuser.status.position = position;
        }
        camera_start_exposure_configured_opt(
            device_id.to_string(),
            1.0,
            Some(100),
            Some(10),
            1,
            1,
            None,
            nightshade_native::camera::FrameType::Light,
        )
        .await
        .expect("simulated exposure should complete");
        let frame = api_get_last_image(device_id.to_string())
            .await
            .expect("a frame should be stored");
        frame.stats.hfr
    }

    let device_id = "sim_focus_stats_probe";
    let sharp = hfr_at_focus(crate::sim_frame::SIM_TRUE_FOCUS, device_id).await;
    let defocused = hfr_at_focus(crate::sim_frame::SIM_TRUE_FOCUS + 150, device_id).await;

    get_sim_focuser().write().await.status.connected = false;
    get_sim_camera().write().await.status.connected = false;
    let _ = api_clear_device_image(device_id.to_string()).await;

    let sharp = sharp.expect("an in-focus frame should yield a measurable HFR");
    let defocused = defocused.expect("a defocused frame should yield a measurable HFR");
    assert!(
        defocused > sharp * 1.2,
        "HFR must grow with defocus: in-focus {sharp:.2} px vs defocused {defocused:.2} px. \
             A fabricated `2.5 + random()` tracks nothing and would fail here."
    );
}

/// The simulated camera must deliver the sensor it advertises.
///
/// The manual-capture path generated 4144x2822 while `get_camera_status`
/// reported SIM_W x SIM_H (1920x1080). Two surfaces of one app then
/// disagreed about one connected camera: the Imaging toolbar and the FITS
/// said 4144x2822, while the Framing sidebar sized its FOV box from the
/// advertised 1920x1080 and drew it 2.16x too narrow.
#[tokio::test]
async fn simulated_frame_matches_the_advertised_sensor() {
    let device_id = "sim_geometry_probe".to_string();

    camera_start_exposure_configured_opt(
        device_id.clone(),
        0.01,
        Some(100),
        Some(10),
        1,
        1,
        None,
        nightshade_native::camera::FrameType::Light,
    )
    .await
    .expect("simulated exposure should complete");

    let (advertised_w, advertised_h) = {
        let camera = get_sim_camera().read().await;
        (camera.status.sensor_width, camera.status.sensor_height)
    };
    let frame = api_get_last_image(device_id)
        .await
        .expect("a frame should be stored");

    assert_eq!(
        (frame.width, frame.height),
        (advertised_w, advertised_h),
        "the delivered frame must have the geometry the camera advertised"
    );
}

/// Aborting a simulated exposure must actually stop it.
///
/// The cancel path only set the sensor state to Idle, so the exposure
/// future slept on to full duration and then published
/// ExposureComplete{success:true} and stored the frame. A 30 s light
/// aborted at 24 s still "completed" 7 s later.
#[tokio::test]
async fn cancelling_a_simulated_exposure_stops_it_and_stores_nothing() {
    let device_id = "sim_cancel_probe".to_string();
    api_clear_device_image(device_id.clone())
        .await
        .expect("clearing an empty slot is a no-op");

    let cancel_id = device_id.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        api_camera_cancel_exposure(cancel_id)
            .await
            .expect("cancel should be accepted");
    });

    let started = std::time::Instant::now();
    let result = camera_start_exposure_configured_opt(
        device_id.clone(),
        30.0,
        Some(100),
        Some(10),
        1,
        1,
        None,
        nightshade_native::camera::FrameType::Light,
    )
    .await;
    let elapsed = started.elapsed();

    assert!(
        result.is_err(),
        "a cancelled exposure must not report success"
    );
    assert!(
        elapsed < std::time::Duration::from_secs(5),
        "the exposure kept integrating for {:?} of its 30 s after the abort",
        elapsed
    );
    assert!(
        api_get_last_image(device_id).await.is_err(),
        "an aborted exposure must not store a frame"
    );
}

/// The operator's actual requirement, end to end: a frame captured FROM THE
/// IMAGING SCREEN solves against the real ASTAP binary at the pointing the
/// mount reports.
///
/// `the_manual_capture_path_renders_the_catalogue_sky` above proves the
/// geometry with a synthetic catalogue and no external binary, so it can run
/// on CI. It does not prove the frame is SOLVABLE, and "solvable" is the
/// whole point of the defect: Slew & Center, framing, mosaic tiles,
/// meridian-flip recentre and polar alignment all call a solver, not a star
/// detector. The sequencer's download path has had that proof
/// (`a_downloaded_simulator_frame_solves_at_the_mounts_pointing`); this path
/// — the one the Imaging screen uses — did not, which is precisely how it
/// stayed broken while the other path looked fine.
///
/// Ignored by default because it needs `astap_cli` and a star database:
///
/// ```text
/// NIGHTSHADE_SIM_SKY_ASTAP_DIR=~/.local/share/nightshade-audit/astap/bin \
///   cargo test -p nightshade_bridge --lib manual_capture_frame_solves -- --ignored --nocapture
/// ```
#[tokio::test]
#[ignore = "needs astap_cli and a star database; see the doc comment to run it"]
async fn a_manual_capture_frame_solves_at_the_mounts_pointing() {
    use crate::api::devices::simulation::{get_sim_camera, get_sim_mount};
    use crate::sim_sky::astap_integration::{astap_dir, read_crval, write_fits, PIXEL_UM};

    let _serialized = crate::api::devices::simulation::sim_singleton_test_lock()
        .lock()
        .await;
    let dir = astap_dir();
    let binary = dir.join("astap_cli");
    assert!(
        binary.exists(),
        "no astap_cli in {dir:?}; set NIGHTSHADE_SIM_SKY_ASTAP_DIR"
    );

    // Exactly what the Plate Solving settings screen writes, pointed at the
    // same database ASTAP will match against.
    crate::sim_capture::shared_platesolver_store();
    let previous = crate::state::get_platesolver_preference().unwrap_or_default();
    crate::state::save_platesolver_preference(&crate::storage::PlateSolverPreference {
        astap_path: binary.to_string_lossy().to_string(),
        catalog_path: dir.to_string_lossy().to_string(),
        ..previous.clone()
    })
    .expect("save plate-solver preference");

    // M42, and a mount that says so.
    let ra_hours = 5.59_f64;
    let dec_deg = -5.39_f64;
    {
        // The simulated mount keeps coordinates of date; point it at the
        // grid's J2000 centre the way a slew would.
        let (mount_ra, mount_dec) = crate::device_manager::epoch::j2000_to_mount_frame(
            crate::device::DriverType::Simulator,
            ra_hours,
            dec_deg,
        );
        let mut mount = get_sim_mount().write().await;
        mount.status.connected = true;
        mount.status.right_ascension = mount_ra;
        mount.status.declination = mount_dec;
    }
    crate::api::devices::simulation::reset_sim_guide_offset().await;
    get_sim_camera().write().await.status.connected = true;

    let device_id = "sim_manual_capture_solve".to_string();
    let capture = camera_start_exposure_configured_opt(
        device_id.clone(),
        0.3,
        None,
        None,
        1,
        1,
        None,
        nightshade_native::camera::FrameType::Light,
    )
    .await;
    let raw = get_last_raw_image_info(&device_id).await;

    // Put the singletons back before asserting, so a failure here does not
    // leave a catalogue sky armed for every other simulator test.
    get_sim_mount().write().await.status.connected = false;
    get_sim_camera().write().await.status.connected = false;
    let _ = crate::state::save_platesolver_preference(&previous);
    let _ = api_clear_device_image(device_id).await;

    capture.expect("simulated exposure should complete");
    let raw = raw
        .expect("raw image lookup should succeed")
        .expect("a raw frame should be stored");

    let scratch = tempfile::TempDir::new().unwrap();
    let path = scratch.path().join("manual_capture.fits");
    write_fits(
        &path,
        &raw.data,
        ra_hours,
        dec_deg,
        crate::sim_capture::SIM_DEFAULT_FOCAL_LENGTH_MM,
    );
    let base = path.with_extension("");
    let scale = crate::sim_capture::sim_plate_scale_arcsec_per_px(
        PIXEL_UM,
        crate::sim_capture::SIM_DEFAULT_FOCAL_LENGTH_MM,
    );
    let fov_h_deg = scale * f64::from(raw.height) / 3600.0;
    let output = std::process::Command::new(&binary)
        .args([
            "-f".into(),
            path.to_string_lossy().to_string(),
            "-r".into(),
            "10".into(),
            "-fov".into(),
            format!("{fov_h_deg:.4}"),
            "-ra".into(),
            format!("{ra_hours:.5}"),
            "-spd".into(),
            format!("{:.5}", dec_deg + 90.0),
            "-d".into(),
            dir.to_string_lossy().to_string(),
            "-o".into(),
            base.to_string_lossy().to_string(),
            "-wcs".into(),
        ])
        .output()
        .expect("run astap_cli");

    let (solved_ra, solved_dec) = read_crval(&base).unwrap_or_else(|| {
        panic!(
            "the Imaging screen's captured frame did not solve:\n{}",
            String::from_utf8_lossy(&output.stdout).trim()
        )
    });
    let error_arcsec = ((solved_ra - ra_hours * 15.0) * dec_deg.to_radians().cos())
        .hypot(solved_dec - dec_deg)
        * 3600.0;
    println!("manual-capture frame solved, centre error {error_arcsec:.1}\"");
    assert!(
        error_arcsec < scale,
        "solved centre {error_arcsec:.1}\" from the mount's pointing, over one \
             {scale:.2}\" pixel"
    );
}
