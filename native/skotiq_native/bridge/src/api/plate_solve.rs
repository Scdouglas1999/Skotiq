//! Plate solving for the app: a solve of an image file, and the solver's
//! detection, verification and saved configuration. The solve itself is
//! [`crate::solver`].

use crate::error::SkotiqError;

/// Plate solve result
#[derive(Debug, Clone)]
pub struct PlateSolveResult {
    pub success: bool,
    pub ra: f64,           // degrees
    pub dec: f64,          // degrees
    pub pixel_scale: f64,  // arcsec/pixel
    pub rotation: f64,     // degrees, East of North
    pub field_width: f64,  // degrees
    pub field_height: f64, // degrees
    pub solve_time_secs: f64,
    pub error: Option<String>,
    pub cd1_1: f64, // raw CD matrix, deg/pixel
    pub cd1_2: f64,
    pub cd2_1: f64,
    pub cd2_2: f64,
    pub sip_a_order: u32, // SIP forward distortion, 0 when absent
    pub sip_b_order: u32,
    pub sip_a_coeffs: Vec<f64>, // row-major (i, j): index i * (order + 1) + j
    pub sip_b_coeffs: Vec<f64>,
    pub sip_ap_order: u32, // SIP inverse distortion, 0 when absent
    pub sip_bp_order: u32,
    pub sip_ap_coeffs: Vec<f64>,
    pub sip_bp_coeffs: Vec<f64>,
}

impl From<skotiq_imaging::PlateSolveResult> for PlateSolveResult {
    fn from(r: skotiq_imaging::PlateSolveResult) -> Self {
        Self {
            success: r.success,
            ra: r.ra,
            dec: r.dec,
            pixel_scale: r.pixel_scale,
            rotation: r.rotation,
            field_width: r.field_width,
            field_height: r.field_height,
            solve_time_secs: r.solve_time_secs,
            error: r.error,
            cd1_1: r.cd1_1,
            cd1_2: r.cd1_2,
            cd2_1: r.cd2_1,
            cd2_2: r.cd2_2,
            sip_a_order: r.a_order,
            sip_b_order: r.b_order,
            sip_a_coeffs: r.a_coeffs,
            sip_b_coeffs: r.b_coeffs,
            sip_ap_order: r.ap_order,
            sip_bp_order: r.bp_order,
            sip_ap_coeffs: r.ap_coeffs,
            sip_bp_coeffs: r.bp_coeffs,
        }
    }
}

/// Get the path to the installed plate solver
#[flutter_rust_bridge::frb(sync)]
pub fn api_get_plate_solver_path() -> Option<String> {
    skotiq_platesolve::get_solver_path().map(|p| p.to_string_lossy().to_string())
}

/// Blind solve of the image file at `file_path`, told the field scale.
pub async fn api_plate_solve_blind(
    file_path: String,
    timeout_secs: Option<u32>,
) -> Result<PlateSolveResult, SkotiqError> {
    solve_file(&file_path, None, timeout_secs).await
}

/// Solve of the image file at `file_path` within `search_radius` degrees of
/// RA `hint_ra`, Dec `hint_dec` (degrees), widening to blind if that fails.
pub async fn api_plate_solve_near(
    file_path: String,
    hint_ra: f64,
    hint_dec: f64,
    search_radius: f64,
    timeout_secs: Option<u32>,
) -> Result<PlateSolveResult, SkotiqError> {
    let position = crate::solver::SolvePosition {
        ra_degrees: hint_ra,
        dec_degrees: hint_dec,
        search_radius_deg: search_radius,
    };
    solve_file(&file_path, Some(position), timeout_secs).await
}

async fn solve_file(
    file_path: &str,
    position: Option<crate::solver::SolvePosition>,
    timeout_secs: Option<u32>,
) -> Result<PlateSolveResult, SkotiqError> {
    let scale = crate::solver::SolveScale::for_frame_file(std::path::Path::new(file_path)).await;
    crate::solver::solve(
        file_path,
        crate::solver::SolveRequest {
            position,
            frame_scale: None,
            scale: &scale,
            timeout_secs,
            downsample: None,
        },
    )
    .await
    .map(PlateSolveResult::from)
}

// Plate solver UX (detection / verification / config)

/// Detection snapshot returned to the settings UI. Contains everything
/// needed to render the "ASTAP detected at /path/to/astap.exe (catalog: V17
/// to mag 17)" status banner without further FFI round-trips.
#[derive(Debug, Clone)]
pub struct PlateSolverDetection {
    /// Detected ASTAP executable path. `None` when ASTAP is not installed.
    pub astap_path: Option<String>,
    /// Detected `solve-field` path. `None` when astrometry.net is not
    /// installed.
    pub astrometry_path: Option<String>,
    /// Detected ASTAP star catalog. `None` when ASTAP was detected but no
    /// catalog could be located (the user must point us at one).
    pub catalog_name: Option<String>,
    /// Approximate magnitude limit the detected catalog covers (e.g. 17.0
    /// for V17). `None` when the catalog flavour isn't recognised.
    pub catalog_magnitude_limit: Option<f32>,
    /// Directory containing the detected catalog.
    pub catalog_path: Option<String>,
}

/// Detailed information about a verified solver binary. See
/// `api_platesolve_verify`.
#[derive(Debug, Clone)]
pub struct PlateSolverInfo {
    /// Absolute path of the verified binary.
    pub path: String,
    /// `"ASTAP"`, `"Astrometry.net"`, or `"Unknown"`.
    pub flavour: String,
    /// First non-empty line of the binary's `--help` output, useful for
    /// surfacing the build version in the settings UI.
    pub version_line: String,
}

/// Persisted plate-solver UX configuration. Mirrors `storage::PlateSolverPreference`
/// 1:1; lives in this module so flutter_rust_bridge can generate Dart
/// bindings without exporting the storage internals.
#[derive(Debug, Clone)]
pub struct PlateSolverConfigPayload {
    pub astap_path: String,
    pub astrometry_path: String,
    pub catalog_path: String,
    pub solver_choice: String,
}

impl PlateSolverConfigPayload {
    fn into_pref(self) -> crate::storage::PlateSolverPreference {
        crate::storage::PlateSolverPreference {
            astap_path: self.astap_path,
            astrometry_path: self.astrometry_path,
            catalog_path: self.catalog_path,
            solver_choice: self.solver_choice,
        }
    }
}

impl From<crate::storage::PlateSolverPreference> for PlateSolverConfigPayload {
    fn from(pref: crate::storage::PlateSolverPreference) -> Self {
        Self {
            astap_path: pref.astap_path,
            astrometry_path: pref.astrometry_path,
            catalog_path: pref.catalog_path,
            solver_choice: pref.solver_choice,
        }
    }
}

/// Detect installed plate solvers and catalogs. Honours the user-configured
/// override paths from the persisted plate-solver preference, if any. Does
/// not run the binaries — that's `api_platesolve_verify`.
#[flutter_rust_bridge::frb(sync)]
pub fn api_platesolve_detect() -> Result<PlateSolverDetection, SkotiqError> {
    use std::path::Path;

    // Why: first-run / no-saved-prefs is the dominant case — return defaults
    // so detection still scans standard install paths. A storage IO error
    // here is non-fatal because the only state read is overlay-on-defaults;
    // the user can still set explicit paths in the Plate Solving settings.
    let pref = crate::state::get_platesolver_preference()
        .unwrap_or_else(|_| crate::storage::PlateSolverPreference::default());

    let configured_astap = if pref.astap_path.is_empty() {
        None
    } else {
        Some(pref.astap_path.clone())
    };
    let configured_astrometry = if pref.astrometry_path.is_empty() {
        None
    } else {
        Some(pref.astrometry_path.clone())
    };
    let configured_catalog = if pref.catalog_path.is_empty() {
        None
    } else {
        Some(pref.catalog_path.clone())
    };

    // Probing involves filesystem reads which are fast but blocking. The
    // function is sync — callers can wrap it if they need it off the UI
    // isolate.
    skotiq_platesolve::invalidate_solver_availability_cache();

    let astap_path =
        skotiq_platesolve::find_astap_with_override(configured_astap.as_deref().map(Path::new));
    let astrometry_path = skotiq_platesolve::find_astrometry_with_override(
        configured_astrometry.as_deref().map(Path::new),
    );

    let catalog = skotiq_platesolve::detect_astap_catalog(
        astap_path.as_deref(),
        configured_catalog.as_deref().map(Path::new),
    );

    Ok(PlateSolverDetection {
        astap_path: astap_path.map(|p| p.to_string_lossy().to_string()),
        astrometry_path: astrometry_path.map(|p| p.to_string_lossy().to_string()),
        catalog_name: catalog.as_ref().and_then(|c| {
            if c.name.is_empty() {
                None
            } else {
                Some(c.name.clone())
            }
        }),
        catalog_magnitude_limit: catalog.as_ref().and_then(|c| c.magnitude_limit),
        catalog_path: catalog
            .as_ref()
            .map(|c| c.path.to_string_lossy().to_string()),
    })
}

/// Run the supplied solver binary with `--help` to confirm it's healthy.
/// Returns a `PlateSolverInfo` with the detected flavour and version banner,
/// or a `SkotiqError` if the binary is missing / fails to spawn / exits
/// with non-zero status and empty output.
pub fn api_platesolve_verify(executable_path: String) -> Result<PlateSolverInfo, SkotiqError> {
    use std::path::Path;
    let path = Path::new(&executable_path);
    match skotiq_platesolve::verify_solver(path) {
        Ok(info) => Ok(PlateSolverInfo {
            path: info.path.to_string_lossy().to_string(),
            flavour: info.flavour,
            version_line: info.version_line,
        }),
        Err(e) => Err(SkotiqError::OperationFailed(e.to_string())),
    }
}

/// Read the persisted plate-solver configuration. Falls back to defaults if
/// the storage was never written.
#[flutter_rust_bridge::frb(sync)]
pub fn api_platesolve_get_config() -> Result<PlateSolverConfigPayload, SkotiqError> {
    let pref = crate::state::get_platesolver_preference().map_err(SkotiqError::OperationFailed)?;
    Ok(pref.into())
}

/// Persist a new plate-solver configuration. Immediately propagates the new
/// paths into the imaging crate's process-global so subsequent solves (blind
/// or near, from any call site including the sequencer) use the updated paths
/// without requiring a restart. Also invalidates the solver availability
/// cache so the next `api_is_plate_solver_available()` call re-probes the
/// filesystem with the new paths.
#[flutter_rust_bridge::frb(sync)]
pub fn api_platesolve_set_config(config: PlateSolverConfigPayload) -> Result<(), SkotiqError> {
    // Live before it is saved, so the paths the operator just set are honored
    // this session even if the storage write fails.
    let pref = config.into_pref();
    crate::solver::apply_solver_preference(&pref);
    crate::state::save_platesolver_preference(&pref).map_err(SkotiqError::OperationFailed)?;
    skotiq_platesolve::invalidate_solver_availability_cache();
    Ok(())
}
