//! Real Plate Solving Integration
//!
//! Provides actual integration with plate solving software:
//! - ASTAP (Astrometric STAcking Program)
//! - Local Astrometry.net
//!
//! These are real implementations that call external solvers.
//!
//! # `as`-cast policy
//!
//! This module's numeric casts are all **SIP-coefficient index widening**
//! (`u32 as usize` over an order that `sip_layout` has already bounded), which
//! is lossless on every >=32-bit target. Sites with their own `Why:` comment
//! override the module-level reasoning.
//!
//! # `unwrap_or` policy
//!
//! Each `unwrap_or` site below maps to a specific external-solver edge case:
//!
//! * `output.status.code().unwrap_or(-1)` — on POSIX a subprocess killed by
//!   a signal has no exit code; `-1` is the documented sentinel surfaced to
//!   the FFI caller's `SolveResult.status` (treated as "solver crashed").
//! * `crota.unwrap_or(0.0)` — `CROTA2` is optional in the FITS WCS standard;
//!   zero rotation is the default North-Up orientation assumed when the
//!   solver omits the keyword.
//! * `output_dir.parent().unwrap_or_else(|| Path::new("."))` — root-path
//!   case for the temp/work directory; current-dir is the safe fallback.

mod platesolve_paths;

pub use platesolve_paths::CatalogInfo;
use platesolve_paths::{
    astap_candidates, astrometry_candidates, catalog_dir_candidates, first_existing,
    identify_catalog, AstapPathInputs, AstrometryPathInputs, CatalogSearchInputs, OsFamily, RealFs,
};

use std::fs;
use std::io::Read;
use std::num::ParseFloatError;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use thiserror::Error;
use wait_timeout::ChildExt;

/// Structured errors emitted while parsing solver-produced WCS / INI files.
///
/// A solve must surface every parse failure so downstream science code never
/// treats a malformed header as a successful zero-coordinate solution.
#[derive(Debug, Error)]
pub enum PlateSolveError {
    #[error(
        "failed to parse WCS keyword `{keyword}` value `{raw_value}` as f64 (file: {path}): {source}"
    )]
    WcsParse {
        keyword: String,
        raw_value: String,
        path: String,
        #[source]
        source: ParseFloatError,
    },
    #[error("WCS file `{path}` did not contain required keyword `{keyword}`")]
    WcsMissingKeyword { keyword: String, path: String },
    #[error("ASTAP INI file `{path}` reports plate solve failed (PLTSOLVD != T)")]
    SolveFailed { path: String },
    #[error("failed to read solver output `{path}`: {source}")]
    ReadOutput {
        path: String,
        #[source]
        source: std::io::Error,
    },
}

/// Plate solve result
#[derive(Debug, Clone, Default)]
pub struct PlateSolveResult {
    /// Solved RA in degrees
    pub ra: f64,
    /// Solved Dec in degrees
    pub dec: f64,
    /// Image scale in arcsec/pixel
    pub pixel_scale: f64,
    /// Rotation angle in degrees (East of North)
    pub rotation: f64,
    /// Field width in degrees
    pub field_width: f64,
    /// Field height in degrees
    pub field_height: f64,
    /// Was the solve successful?
    pub success: bool,
    /// Error message if failed
    pub error: Option<String>,
    /// Time taken to solve in seconds
    pub solve_time_secs: f64,
    /// Raw CD matrix (deg/pixel) as read from the WCS — the full anisotropic
    /// transform. `pixel_scale`/`rotation` above are the isotropic collapse
    /// kept for backward compatibility. Zero when no WCS was parsed.
    pub cd1_1: f64,
    pub cd1_2: f64,
    pub cd2_1: f64,
    pub cd2_2: f64,
    /// SIP forward distortion order (`A_ORDER`/`B_ORDER`). Zero when absent.
    pub a_order: u32,
    pub b_order: u32,
    /// SIP forward coefficients in row-major `(i, j)` order: the slot for term
    /// `A_i_j` is at index `i * (order + 1) + j` (likewise `B_i_j`). Empty when
    /// no SIP keywords were present.
    pub a_coeffs: Vec<f64>,
    pub b_coeffs: Vec<f64>,
    /// SIP inverse distortion order (`AP_ORDER`/`BP_ORDER`). Zero when absent.
    pub ap_order: u32,
    pub bp_order: u32,
    /// SIP inverse coefficients, same row-major `(i, j)` layout as the forward
    /// terms. Empty when the inverse keywords were not present.
    pub ap_coeffs: Vec<f64>,
    pub bp_coeffs: Vec<f64>,
}

/// Plate solver configuration
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum PlateSolverChoice {
    #[default]
    Auto,
    Astap,
    Astrometry,
}

impl PlateSolverChoice {
    fn from_stored(value: Option<&str>) -> Self {
        match value {
            Some("astap") => Self::Astap,
            Some("astrometry") => Self::Astrometry,
            _ => Self::Auto,
        }
    }
}

#[derive(Debug, Clone)]
pub struct PlateSolverConfig {
    /// Path to ASTAP executable
    pub astap_path: Option<PathBuf>,
    /// Path to local astrometry.net solve-field
    pub astrometry_path: Option<PathBuf>,
    /// Directory containing ASTAP star catalog (.290 / .1476 files).
    /// Passed to ASTAP as `-d <dir>`. When `None` ASTAP must find the
    /// catalog in its own install directory; if it can't, it will fail
    /// with "no star database found".
    pub catalog_path: Option<PathBuf>,
    /// Search radius in degrees (0 = blind solve)
    pub search_radius: f64,
    /// Downsample factor for faster solving
    pub downsample: u32,
    /// Maximum time for solving in seconds
    pub timeout_secs: u32,
    /// User-selected solver. Auto tries ASTAP, then astrometry.net.
    pub solver_choice: PlateSolverChoice,
}

impl Default for PlateSolverConfig {
    fn default() -> Self {
        // Consult the process-global preference (set by `set_solver_preference`)
        // so every call site — blind_solve, solve_near, the sequencer, the
        // imaging auto-solve — honours whatever the user configured in Settings
        // → Plate Solving without any caller needing to pass the config
        // explicitly.
        let (configured_catalog, solver_choice) = {
            let pref = ACTIVE_SOLVER_PREF.read().expect("solver-pref RwLock");
            (pref.catalog_path.clone(), pref.solver_choice)
        };

        let discovered = discovered_solvers();

        Self {
            astap_path: discovered.astap,
            astrometry_path: discovered.astrometry,
            catalog_path: configured_catalog,
            search_radius: 10.0,
            downsample: 2,
            timeout_secs: 60,
            solver_choice,
        }
    }
}

/// Process-global solver preference set by `set_solver_preference()`.
///
/// Why a global: every call site that reaches `PlateSolverConfig::default()`
/// (`blind_solve`, `solve_near`, the sequencer centering, the imaging
/// auto-solve) lives deep in the call stack where there is no natural place to
/// thread a config parameter. A process-global is the established pattern for
/// this kind of cross-cutting preference (see `DISCOVERED_SOLVERS` below, which
/// caches what this preference resolves to). The `RwLock` permits concurrent
/// reads (the common case) and serialises the rare write.
#[derive(Default)]
struct SolverPref {
    astap_path: Option<PathBuf>,
    astrometry_path: Option<PathBuf>,
    catalog_path: Option<PathBuf>,
    solver_choice: PlateSolverChoice,
}

static ACTIVE_SOLVER_PREF: std::sync::RwLock<SolverPref> = std::sync::RwLock::new(SolverPref {
    astap_path: None,
    astrometry_path: None,
    catalog_path: None,
    solver_choice: PlateSolverChoice::Auto,
});

/// Update the process-global solver preference from the persisted user
/// settings. Must be called:
///   1. At startup, after loading `platesolver.json`.
///   2. Immediately after `api_platesolve_set_config` saves a new preference.
///
/// Empty strings in the input are treated as "no override" (auto-detect).
/// `catalog_path` is set directly — if the user left it blank the field is
/// `None` and no `-d` flag is passed to ASTAP (ASTAP then looks next to its
/// own binary, which is the correct behaviour when the catalog is co-located).
pub fn set_solver_preference(
    astap_path: Option<&str>,
    astrometry_path: Option<&str>,
    catalog_path: Option<&str>,
    solver_choice: Option<&str>,
) {
    let to_path =
        |s: Option<&str>| -> Option<PathBuf> { s.filter(|p| !p.is_empty()).map(PathBuf::from) };
    {
        let mut pref = ACTIVE_SOLVER_PREF.write().expect("solver-pref RwLock");
        pref.astap_path = to_path(astap_path);
        pref.astrometry_path = to_path(astrometry_path);
        pref.catalog_path = to_path(catalog_path);
        pref.solver_choice = PlateSolverChoice::from_stored(solver_choice);
    }
    // The pref write guard is released first: `discovered_solvers` takes
    // DISCOVERED_SOLVERS then ACTIVE_SOLVER_PREF, so invalidating while still
    // holding the pref lock would invert the order and can deadlock.
    invalidate_solver_availability_cache();
}

/// Find ASTAP installation by probing every well-known install path *plus*
/// PATH. Returns the first hit. `configured` lets settings override the
/// search order — when supplied and present, it always wins.
///
/// The candidate list lives in `platesolve_paths::astap_candidates` so the
/// per-OS enumeration can be unit-tested without filesystem access.
pub fn find_astap_with_override(configured: Option<&Path>) -> Option<PathBuf> {
    let local_app_data = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    let home = home_dir();

    let inputs = AstapPathInputs {
        os: OsFamily::host(),
        configured,
        local_app_data: local_app_data.as_deref(),
        home: home.as_deref(),
    };

    let candidates = astap_candidates(&inputs);
    if let Some(hit) = first_existing(&RealFs, &candidates) {
        return Some(hit);
    }

    which_on_path("astap")
        .or_else(|| which_on_path("astap_cli"))
        .map(PathBuf::from)
}

/// Find local astrometry.net installation. See `find_astap_with_override`
/// for the override semantics.
pub fn find_astrometry_with_override(configured: Option<&Path>) -> Option<PathBuf> {
    let inputs = AstrometryPathInputs {
        os: OsFamily::host(),
        configured,
    };

    let candidates = astrometry_candidates(&inputs);
    if let Some(hit) = first_existing(&RealFs, &candidates) {
        return Some(hit);
    }

    which_on_path("solve-field").map(PathBuf::from)
}

/// The resolved solver locations for the current `ACTIVE_SOLVER_PREF`.
#[derive(Clone)]
struct DiscoveredSolvers {
    astap: Option<PathBuf>,
    astrometry: Option<PathBuf>,
}

/// Cached result of the ASTAP / astrometry.net filesystem probe.
///
/// Why cache: a miss stats a per-OS candidate list and, when nothing matches,
/// shells out to `which`/`where` — up to three subprocess spawns on a machine
/// with no solver installed. `PlateSolverConfig::default()` runs on every
/// solve, and `is_solver_available()` / `get_solver_path()` are polled by the
/// settings UI, the scheduler and sequencer pre-flight, so an uncached probe
/// is paid hundreds of times a night. The answer is process-stable: an
/// installer running while Skotiq is open is rare, and the only in-process
/// way to change the inputs is `set_solver_preference`, which invalidates.
/// `invalidate_solver_availability_cache()` forces a re-probe on demand.
static DISCOVERED_SOLVERS: std::sync::Mutex<Option<DiscoveredSolvers>> =
    std::sync::Mutex::new(None);

/// Resolve both solver paths, probing the filesystem only on a cache miss.
///
/// The probe runs while the cache mutex is held so concurrent solves wait for
/// one probe instead of each launching their own.
fn discovered_solvers() -> DiscoveredSolvers {
    // A poisoned cache holds a fully-written `Option`; the guarded region only
    // clones `PathBuf`s, so there is no torn state to recover from and a
    // permanent "no plate solving until restart" panic is the worse outcome.
    let mut guard = DISCOVERED_SOLVERS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(cached) = guard.as_ref() {
        return cached.clone();
    }

    let (configured_astap, configured_astrometry) = {
        let pref = ACTIVE_SOLVER_PREF.read().expect("solver-pref RwLock");
        (pref.astap_path.clone(), pref.astrometry_path.clone())
    };
    let discovered = DiscoveredSolvers {
        astap: find_astap_with_override(configured_astap.as_deref()),
        astrometry: find_astrometry_with_override(configured_astrometry.as_deref()),
    };
    *guard = Some(discovered.clone());
    discovered
}

/// Resolve the user's home directory from the platform-appropriate env var.
fn home_dir() -> Option<PathBuf> {
    if cfg!(target_os = "windows") {
        std::env::var_os("USERPROFILE").map(PathBuf::from)
    } else {
        std::env::var_os("HOME").map(PathBuf::from)
    }
}

/// Cross-platform `which`/`where` lookup. Shells out so we get exactly the
/// same resolution semantics as the user's interactive shell. Returns the
/// first matching path or `None` if the command isn't on PATH.
fn which_on_path(binary: &str) -> Option<String> {
    let (cmd, query) = if cfg!(target_os = "windows") {
        ("where", format!("{}.exe", binary))
    } else {
        ("which", binary.to_string())
    };

    let output = Command::new(cmd).arg(&query).output().ok()?;
    if !output.status.success() {
        // On Windows, also try without the .exe extension in case it's a
        // CLI tool installed without the suffix.
        if cfg!(target_os = "windows") {
            let fallback = Command::new("where").arg(binary).output().ok()?;
            if fallback.status.success() {
                let path = String::from_utf8(fallback.stdout).ok()?;
                return path.lines().next().map(|s| s.trim().to_string());
            }
        }
        return None;
    }
    let path = String::from_utf8(output.stdout).ok()?;
    let first = path.lines().next()?.trim();
    if first.is_empty() {
        None
    } else {
        Some(first.to_string())
    }
}

/// Which executable and catalog directory a caller-less catalog search should
/// probe around.
///
/// Extracted so the rule is a named thing with a test rather than a line
/// inside [`detect_astap_catalog`] — the repo's habit for exactly this kind of
/// decision (see `platesolve_paths::astap_candidates`).
///
/// `configured_exe` is what the operator set in Settings → Plate Solving;
/// `discovered_exe` is what the module's own resolver found on this machine.
/// Either serves, and the configured one wins — but `None` for BOTH is the
/// only state in which the search may conclude an exe is unavailable. Handing
/// back `None` while a discovered exe existed is the whole defect: the exe's
/// own directory, which is where ASTAP catalogs normally live, never entered
/// the candidate list.
fn catalog_search_fallback(
    configured_exe: Option<PathBuf>,
    discovered_exe: Option<PathBuf>,
    configured_catalog: Option<PathBuf>,
) -> (Option<PathBuf>, Option<PathBuf>) {
    (configured_exe.or(discovered_exe), configured_catalog)
}

/// Detect an ASTAP star catalog around a known executable path. The catalog
/// (.290/.h17 files) is required for ASTAP to actually solve; many users
/// install it separately on a fast drive.
///
/// Returns the *first* recognised catalog, walking:
///   1. user-configured catalog directory (if any),
///   2. directory containing the ASTAP executable,
///   3. `~/.astap/`,
///   4. platform-specific install locations (`%LOCALAPPDATA%\astap`, etc.).
///
/// The actual filename → catalog-name mapping lives in
/// `platesolve_paths::identify_catalog` so it can be exhaustively tested
/// without staging real catalog files.
pub fn detect_astap_catalog(
    exe_path: Option<&Path>,
    configured: Option<&Path>,
) -> Option<CatalogInfo> {
    let local_app_data = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    let home = home_dir();

    // Fall back to the operator's configured Plate Solving paths when the
    // caller supplies none. Every other entry point into this module already
    // consults `ACTIVE_SOLVER_PREF` for exactly this reason ("without any
    // caller needing to pass the config explicitly"); this one did not, so it
    // only ever searched the default install locations.
    //
    // The visible consequence: on any rig whose ASTAP lives somewhere else,
    // the sequencer's pre-flight check reported "no ASTAP star database found
    // ... target centering in this sequence will fail" as a run-level error,
    // on runs where the catalogs were present and ASTAP was solving to 0.5".
    // A setup warning that fires while the thing it warns about is working is
    // worse than no warning: the next real one gets ignored.
    //
    // Reading the preference was not enough, and the same warning fired again
    // on the owner's rig on 2026-09-15: ASTAP sat at
    // `C:\Program Files\astap\astap.exe` with a `d80_*.1476` catalog beside it
    // and solved that night's frames to 0.17" of an independent run, while
    // every sequence logged "no ASTAP star database found ... target centering
    // in this sequence will fail". `ACTIVE_SOLVER_PREF.astap_path` was empty —
    // nothing had been configured by hand, because nothing needed to be — so
    // the fallback produced no exe, the exe's own directory never entered the
    // candidate list, and `C:\Program Files\astap` is not in
    // `catalog_dir_candidates`' well-known set either.
    //
    // So resolve the executable the way the REST of the module resolves it,
    // through the same cached `discovered_solvers()` that `PlateSolverConfig`
    // and `verify_solver` use, before concluding anything is missing. That is
    // what `api_platesolve_detect` has always done by hand — and why it
    // reported this rig's catalog correctly while the preflight did not. The
    // detector and the solver now search from the same executable, so the
    // detector cannot contradict a solver that is working.
    let fallback_exe;
    let fallback_catalog;
    let (exe_path, configured) = if exe_path.is_none() && configured.is_none() {
        // The pref read guard is a statement temporary and is therefore
        // released before `discovered_solvers()` runs on the next line.
        // `discovered_solvers` takes DISCOVERED_SOLVERS and then
        // ACTIVE_SOLVER_PREF, so holding the pref lock across the call would
        // invert that order — the same hazard `set_solver_preference`
        // documents.
        let (pref_exe, pref_catalog) = {
            let pref = ACTIVE_SOLVER_PREF.read().expect("solver-pref RwLock");
            (pref.astap_path.clone(), pref.catalog_path.clone())
        };
        let resolved = catalog_search_fallback(pref_exe, discovered_solvers().astap, pref_catalog);
        fallback_exe = resolved.0;
        fallback_catalog = resolved.1;
        (fallback_exe.as_deref(), fallback_catalog.as_deref())
    } else {
        (exe_path, configured)
    };

    let inputs = CatalogSearchInputs {
        os: OsFamily::host(),
        exe_path,
        configured,
        local_app_data: local_app_data.as_deref(),
        home: home.as_deref(),
    };

    for dir in catalog_dir_candidates(&inputs) {
        if !dir.is_dir() {
            continue;
        }
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        let names: Vec<String> = entries
            .flatten()
            .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
            .collect();
        if let Some(info) = identify_catalog(&dir, names) {
            return Some(info);
        }
    }
    None
}

/// Result of running an installed solver's `--help` (or equivalent) to
/// confirm the binary is healthy. Returned by `verify_solver`.
#[derive(Debug, Clone)]
pub struct SolverInfo {
    /// Absolute path the verifier ran against.
    pub path: PathBuf,
    /// Solver flavour (`"ASTAP"`, `"Astrometry.net"`, or `"Unknown"`).
    pub flavour: String,
    /// First non-empty line of the solver's `--help` / version output —
    /// useful for surfacing in the settings UI so the user can confirm the
    /// expected build.
    pub version_line: String,
}

/// Structured errors emitted by `verify_solver`.
#[derive(Debug, Error)]
pub enum SolverVerifyError {
    #[error("solver executable `{0}` does not exist")]
    Missing(PathBuf),
    #[error("failed to verify solver `{path}`: {message}")]
    Execution { path: PathBuf, message: String },
    #[error("solver `{path}` exited with status {status} on `--help`. stderr: {stderr}")]
    NonZeroExit {
        path: PathBuf,
        status: i32,
        stderr: String,
    },
}

/// Exec the solver with `--help` to confirm the binary actually works.
///
/// Why bother: a user can drop a stale or incompatible binary into the
/// configured path. Running it once at settings-save time catches that
/// instead of letting the failure surface inside a sequence.
///
/// GUI builds may open a window instead of exiting on `--help`, so the probe
/// has a deadline and terminates its child process if it does not finish.
pub fn verify_solver(path: &Path) -> Result<SolverInfo, SolverVerifyError> {
    verify_solver_with_timeout(path, 5)
}

fn verify_solver_with_timeout(
    path: &Path,
    timeout_secs: u32,
) -> Result<SolverInfo, SolverVerifyError> {
    if !path.exists() {
        return Err(SolverVerifyError::Missing(path.to_path_buf()));
    }

    let output = run_solver_command(
        Command::new(path).arg("--help"),
        timeout_secs,
        "plate-solver verification",
    )
    .map_err(|message| SolverVerifyError::Execution {
        path: path.to_path_buf(),
        message,
    })?;

    // Why allow non-zero: some builds of ASTAP exit 1 on `--help` after
    // writing the usage banner. Require *some* output before we treat the
    // result as healthy.
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let banner: Option<String> = stdout
        .lines()
        .chain(stderr.lines())
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(str::to_string);

    let banner = match banner {
        Some(b) => b,
        None => {
            // No output at all on either stream — that's almost certainly a
            // broken binary, even if it exited zero. Surface as a non-zero
            // exit so the UI shows the underlying status.
            return Err(SolverVerifyError::NonZeroExit {
                path: path.to_path_buf(),
                status: output.status.code().unwrap_or(-1),
                stderr: stderr.to_string(),
            });
        }
    };

    let lower = banner.to_ascii_lowercase();
    let flavour = if lower.contains("astap") {
        "ASTAP".to_string()
    } else if lower.contains("astrometry") || lower.contains("solve-field") {
        "Astrometry.net".to_string()
    } else {
        "Unknown".to_string()
    };

    Ok(SolverInfo {
        path: path.to_path_buf(),
        flavour,
        version_line: banner,
    })
}

/// Frame height in pixels, read straight off the primary FITS header so sizing
/// the ASTAP `-fov` hint never decodes pixel data.
fn fits_naxis2(path: &Path) -> Option<f64> {
    fits_header_floats(path, &["NAXIS2"])
        .first()
        .copied()
        .flatten()
}

/// Read numeric cards off a FITS primary header without decoding pixel data.
///
/// Returns one slot per requested keyword, in the order asked for.
fn fits_header_floats(path: &Path, keys: &[&str]) -> Vec<Option<f64>> {
    let mut found = vec![None; keys.len()];
    let Ok(mut file) = std::fs::File::open(path) else {
        return found;
    };
    let mut block = [0u8; 2880];
    // 64 blocks bounds the scan at 180 KiB of header, far beyond any real
    // primary header, so a corrupt file cannot spin this loop forever.
    for _ in 0..64 {
        if file.read_exact(&mut block).is_err() {
            return found;
        }
        for card in block.chunks(80) {
            let Ok(card) = std::str::from_utf8(card) else {
                return found;
            };
            let Some(name) = card.get(..8).map(str::trim) else {
                continue;
            };
            if name == "END" {
                return found;
            }
            if let Some(slot) = keys.iter().position(|k| *k == name) {
                found[slot] = card
                    .split('=')
                    .nth(1)
                    .and_then(|v| v.split('/').next())
                    .and_then(|v| v.trim().parse::<f64>().ok());
                if found.iter().all(Option::is_some) {
                    return found;
                }
            }
        }
    }
    found
}

/// The plate scale a frame declares about itself, in arcsec per pixel.
///
/// `FOCALLEN` (mm) and `XPIXSZ` (um, already scaled by binning — the same
/// convention this app's own FITS writer uses) are what a solver turns into a
/// field size. Reading them off the frame beats reading them off the active
/// profile: an imported frame from another rig carries its own optics, and a
/// confidently wrong scale hint is worse than no hint at all.
///
/// `None` when either card is missing or non-positive — a driver that reports
/// 0.0 is saying "I don't know", not "zero microns".
pub fn fits_scale_arcsec_per_px(path: &Path) -> Option<f64> {
    let cards = fits_header_floats(path, &["FOCALLEN", "XPIXSZ"]);
    let focal = cards[0].filter(|v| v.is_finite() && *v > 0.0)?;
    let pitch = cards[1].filter(|v| v.is_finite() && *v > 0.0)?;
    Some(206.264_806 * pitch / focal)
}

/// Build the exact argument vector an ASTAP solve runs with.
///
/// Flag reference: <https://www.hnsky.org/astap.htm#command_line>
///
/// * `-f <file>` — input FITS file (required)
/// * `-ra <hours>` — hint RA in hours
/// * `-spd <deg>` — hint south-pole distance = Dec + 90°
/// * `-r <deg>` — search radius in degrees (only meaningful with `-ra`/`-spd`)
/// * `-fov <deg>` — field HEIGHT in degrees, the scale hint
/// * `-z <factor>` — downsample factor (0 = ASTAP auto, 1 = none, 2 = half)
/// * `-d <dir>` — star catalog directory, required whenever the catalog is not
///   co-located with the ASTAP binary
/// * `-wcs` — write the solution to a sibling `.wcs` FITS file. `-update` is
///   deliberately avoided: it writes only `.ini` and mutates the operator's
///   capture.
///
/// This is the only argument vector ASTAP ever receives — desktop, headless API
/// and sequencer all solve through it — and it lives outside
/// `AstapSolver::solve` so a test with no ASTAP install, no catalog and no frame
/// can assert what a given set of hints produces.
///
/// `hint_scale` is arcsec/pixel; ASTAP wants degrees of field height, so it
/// needs the frame height in pixels — `naxis2`, read straight off the primary
/// FITS header by [`fits_naxis2`], so sizing a hint never decodes pixel data.
pub(crate) fn build_astap_args(
    config: &PlateSolverConfig,
    input: &Path,
    hint_ra: Option<f64>,
    hint_dec: Option<f64>,
    hint_scale: Option<f64>,
    naxis2: Option<f64>,
) -> Vec<std::ffi::OsString> {
    use std::ffi::OsString;

    let mut args: Vec<OsString> = Vec::new();
    let mut push = |flag: &str, value: OsString| {
        args.push(OsString::from(flag));
        args.push(value);
    };

    push("-f", input.as_os_str().to_os_string());

    // Position hint — only on a near solve.
    if let (Some(ra), Some(dec)) = (hint_ra, hint_dec) {
        push("-ra", format!("{:.6}", ra / 15.0).into()); // hours
        push("-spd", format!("{:.6}", dec + 90.0).into()); // south-pole distance
                                                           // A search radius only means anything alongside a position.
        if config.search_radius > 0.0 {
            push("-r", format!("{:.2}", config.search_radius).into());
        }
    }

    // Field-scale hint.
    if let Some(scale) = hint_scale.filter(|s| *s > 0.0 && s.is_finite()) {
        match naxis2 {
            Some(height) if height > 0.0 => {
                let fov_deg = scale * height / 3600.0;
                if fov_deg.is_finite() && fov_deg > 0.0 {
                    // The one line that separates a hinted solve from a blind
                    // scale sweep in the session log.
                    tracing::info!(
                        "ASTAP field-scale hint: {:.2}\"/px over {:.0} px = -fov {:.4} deg",
                        scale,
                        height,
                        fov_deg
                    );
                    push("-fov", format!("{:.4}", fov_deg).into());
                }
            }
            _ => tracing::debug!(
                "Plate-solve scale hint provided but NAXIS2 unreadable; skipping ASTAP -fov hint"
            ),
        }
    }

    // Downsample: 0 means "let ASTAP choose". Any other value is the
    // operator's decision and is sent verbatim — including `-z 1`, which is
    // how a caller says "this frame is already binned, do NOT throw half of
    // each axis away again". Suppressing 1 here would silently hand such a
    // frame back to ASTAP's auto ladder.
    if config.downsample >= 1 {
        push("-z", format!("{}", config.downsample).into());
    }

    // Catalog directory: without this ASTAP reports "no star database found"
    // and PLTSOLVD=F whenever the catalog is not in its install directory.
    if let Some(cat_dir) = &config.catalog_path {
        push("-d", cat_dir.as_os_str().to_os_string());
    }

    // IMPORTANT: ASTAP exits 0 even on a failed solve. The result lives in
    // PLTSOLVD inside the .ini file. Do NOT gate on exit status.
    args.push(OsString::from("-wcs"));

    args
}

/// A private working directory for one solver invocation.
///
/// External solvers name their output after the file they were handed and write
/// it into that file's folder: ASTAP produces `<image>.ini` and `<image>.wcs`,
/// astrometry.net produces `<image>.axy`, `.corr`, `.rdls`, `.solved`, `.new`
/// and `.wcs`. Pointing them at the operator's capture litters the light folder
/// with sidecars, and a solve that is cut short leaves them behind for good.
///
/// So the solver is handed a hard link to the image inside a directory we own,
/// and the whole directory is removed when the solve returns. A hard link costs
/// nothing and never copies the frame; when one cannot be made (the image's
/// filesystem differs from the temp filesystem *and* its own folder is not
/// writable) the solve runs in place and the guard removes only the artifacts
/// that appeared during this solve.
struct SolveScratch {
    /// Directory created for this solve, removed wholesale on drop.
    dir: Option<PathBuf>,
    /// The path handed to the solver.
    input: PathBuf,
    /// In-place fallback bookkeeping: the folder to sweep, the base name that
    /// marks an artifact of this solve, and the entries that were already
    /// there (which are the operator's, not ours).
    sweep: Option<(PathBuf, String, Vec<std::ffi::OsString>)>,
}

static SCRATCH_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

impl SolveScratch {
    fn new(image_path: &Path) -> Self {
        let file_name = image_path.file_name();
        let parent = image_path.parent();

        // A bare relative name ("frame.fits") parents to the empty path, which
        // is not a directory anything can be created in.
        let parent = parent.map(|parent| {
            if parent.as_os_str().is_empty() {
                Path::new(".")
            } else {
                parent
            }
        });

        if let (Some(file_name), Some(parent)) = (file_name, parent) {
            let unique = format!(
                "skotiq-solve-{}-{}",
                std::process::id(),
                SCRATCH_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            );
            // The temp directory first; the image's own folder second, because
            // a hard link there is guaranteed to be on the same filesystem.
            // A dot-prefixed name keeps it out of the operator's way for the
            // seconds it exists.
            let candidates = [
                std::env::temp_dir().join(&unique),
                parent.join(format!(".{unique}")),
            ];
            for candidate in candidates {
                if fs::create_dir_all(&candidate).is_err() {
                    continue;
                }
                let linked = candidate.join(file_name);
                if fs::hard_link(image_path, &linked).is_ok() {
                    return Self {
                        dir: Some(candidate),
                        input: linked,
                        sweep: None,
                    };
                }
                let _ = fs::remove_dir_all(&candidate);
            }
        }

        // Fallback: solve the file where it lies and reclaim what the solver
        // adds beside it.
        let sweep = match (parent, image_path.file_stem()) {
            (Some(parent), Some(stem)) => match fs::read_dir(parent) {
                Ok(entries) => {
                    let existing = entries
                        .filter_map(|entry| entry.ok())
                        .map(|entry| entry.file_name())
                        .collect::<Vec<_>>();
                    Some((
                        parent.to_path_buf(),
                        stem.to_string_lossy().into_owned(),
                        existing,
                    ))
                }
                // Without a pre-solve snapshot the post-solve diff cannot tell
                // debris from files that were already there — skip the sweep
                // rather than risk deleting a pre-existing sidecar.
                Err(_) => None,
            },
            _ => None,
        };
        tracing::debug!(
            "Plate solve could not stage {:?} in a private directory; solving in place",
            image_path
        );
        Self {
            dir: None,
            input: image_path.to_path_buf(),
            sweep,
        }
    }

    /// The path to hand the solver.
    fn input(&self) -> &Path {
        &self.input
    }

    /// The directory the solver should write its output into.
    fn work_dir(&self) -> &Path {
        self.input.parent().unwrap_or_else(|| Path::new("."))
    }

    /// Where an artifact with the given extension will land.
    fn artifact(&self, extension: &str) -> PathBuf {
        self.input.with_extension(extension)
    }
}

impl Drop for SolveScratch {
    fn drop(&mut self) {
        if let Some(dir) = &self.dir {
            if let Err(error) = fs::remove_dir_all(dir) {
                tracing::warn!("Could not remove plate-solve scratch {:?}: {}", dir, error);
            }
            return;
        }
        if let Some((dir, stem, existing)) = &self.sweep {
            reclaim_new_artifacts(dir, stem, existing);
        }
    }
}

/// The extensions a solver actually writes beside the frame it was handed.
/// ASTAP emits `.ini` and `.wcs`; `solve-field` emits `.axy`, `.corr`,
/// `.match`, `.new`, `.rdls`, `.solved`, `.wcs` and the index cross-match
/// `.xyls`. Anything else sharing the base name belongs to the operator.
const SOLVER_ARTIFACT_EXTENSIONS: [&str; 9] = [
    "axy", "corr", "ini", "match", "new", "rdls", "solved", "wcs", "xyls",
];

/// Is `name` an artifact this solve produced for the frame named `stem`?
///
/// The rule is BASE NAME plus known extension, never a string prefix. A bare
/// `starts_with(stem)` has no separator or extension boundary, so solving
/// `M31.fits` matched — and deleted — `M31_L_0008.fits`, `M31_session.log` and
/// `M31_dark.ini`. That is not hypothetical: the in-place fallback only runs
/// when `fs::hard_link` is unsupported, i.e. on exFAT / FAT32 capture drives
/// and SMB shares, where the camera goes right on writing new lights into the
/// folder being swept.
///
/// `solve-field` also names its index cross-match `<stem>-indx.xyls`, which is
/// the one suffixed form a solver produces, so it is admitted explicitly
/// rather than by loosening the base-name test.
fn is_solve_artifact(name: &std::ffi::OsStr, stem: &str) -> bool {
    let path = Path::new(name);
    let Some(extension) = path.extension().map(|e| e.to_string_lossy().to_lowercase()) else {
        return false;
    };
    if !SOLVER_ARTIFACT_EXTENSIONS.contains(&extension.as_str()) {
        return false;
    }
    let Some(base) = path.file_stem().map(|s| s.to_string_lossy().into_owned()) else {
        return false;
    };
    base == stem || base == format!("{stem}-indx")
}

/// Remove the files a solve added to `dir` for the frame named `stem`, leaving
/// everything that was already there (`existing`) alone. Used only by the
/// in-place fallback: the operator's own sidecars are not ours to delete, and
/// neither is the frame itself, which is in `existing` by construction.
fn reclaim_new_artifacts(dir: &Path, stem: &str, existing: &[std::ffi::OsString]) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.filter_map(|entry| entry.ok()) {
        let name = entry.file_name();
        if existing.contains(&name) {
            continue;
        }
        if !is_solve_artifact(&name, stem) {
            continue;
        }
        if !entry
            .file_type()
            .map(|kind| kind.is_file())
            .unwrap_or(false)
        {
            continue;
        }
        let _ = fs::remove_file(entry.path());
    }
}

/// Plate solver using ASTAP
pub struct AstapSolver {
    config: PlateSolverConfig,
}

impl AstapSolver {
    pub fn new(config: PlateSolverConfig) -> Self {
        Self { config }
    }

    pub fn with_default_config() -> Option<Self> {
        let config = PlateSolverConfig::default();
        if config.astap_path.is_some() {
            Some(Self { config })
        } else {
            None
        }
    }

    /// Check if ASTAP is available
    pub fn is_available(&self) -> bool {
        self.config.astap_path.is_some()
    }

    /// Get ASTAP path
    pub fn astap_path(&self) -> Option<&Path> {
        self.config.astap_path.as_deref()
    }

    /// Solve an image with optional hint coordinates
    ///
    /// # Arguments
    /// * `image_path` - Path to FITS file to solve
    /// * `hint_ra` - Optional hint RA in degrees
    /// * `hint_dec` - Optional hint Dec in degrees
    /// * `hint_scale` - Optional hint for image scale in arcsec/pixel
    pub fn solve(
        &self,
        image_path: &Path,
        hint_ra: Option<f64>,
        hint_dec: Option<f64>,
        hint_scale: Option<f64>,
    ) -> PlateSolveResult {
        let start = std::time::Instant::now();

        let astap_path = match &self.config.astap_path {
            Some(p) => p,
            None => {
                return PlateSolveResult {
                    success: false,
                    error: Some("ASTAP not found".to_string()),
                    solve_time_secs: 0.0,
                    ..Default::default()
                }
            }
        };

        // ASTAP writes `.ini` / `.wcs` against the base name of the file it is
        // given, so it is given a link inside a directory we own instead of
        // the operator's capture. See `SolveScratch`.
        let scratch = SolveScratch::new(image_path);

        let mut cmd = Command::new(astap_path);
        cmd.args(build_astap_args(
            &self.config,
            scratch.input(),
            hint_ra,
            hint_dec,
            hint_scale,
            fits_naxis2(image_path),
        ));

        tracing::info!("Running ASTAP: {:?}", cmd);

        // Enforce timeout using spawn + wait_timeout. Command::output()
        // blocks forever; a stuck ASTAP process (e.g. hung on a network
        // catalog lookup) would stall the sequencer indefinitely.
        let timeout = std::time::Duration::from_secs(u64::from(self.config.timeout_secs));
        let mut child = match cmd.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn() {
            Ok(c) => c,
            Err(e) => {
                return PlateSolveResult {
                    success: false,
                    error: Some(format!("Failed to launch ASTAP at {:?}: {}", astap_path, e)),
                    solve_time_secs: start.elapsed().as_secs_f64(),
                    ..Default::default()
                }
            }
        };

        let child_id = child.id();
        let timeout_secs = self.config.timeout_secs;
        // Drain both pipes concurrently so a chatty solver cannot block on a
        // full OS pipe while this thread retains the Child handle needed to
        // terminate and reap a timed-out solver.
        let mut stdout = child.stdout.take();
        let stdout_reader = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(pipe) = stdout.as_mut() {
                let _ = pipe.read_to_end(&mut bytes);
            }
            bytes
        });
        let mut stderr = child.stderr.take();
        let stderr_reader = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(pipe) = stderr.as_mut() {
                let _ = pipe.read_to_end(&mut bytes);
            }
            bytes
        });

        let status = match child.wait_timeout(timeout) {
            Ok(Some(status)) => status,
            Ok(None) => {
                tracing::error!(
                    "ASTAP (pid {}) timed out after {} seconds; terminating it",
                    child_id,
                    timeout_secs
                );
                let kill_error = child.kill().err();
                let reap_error = child.wait().err();
                // Do not join the pipe readers on timeout: a solver-spawned
                // descendant may still hold a copied pipe open. The detached
                // readers will exit at EOF without delaying the terminal
                // timeout result after the owned solver process is reaped.
                drop(stdout_reader);
                drop(stderr_reader);
                let cleanup_detail = match (kill_error, reap_error) {
                    (None, None) => String::new(),
                    (kill, reap) => format!(
                        " (cleanup: kill={}, reap={})",
                        kill.map_or_else(|| "ok".to_string(), |e| e.to_string()),
                        reap.map_or_else(|| "ok".to_string(), |e| e.to_string())
                    ),
                };
                return PlateSolveResult {
                    success: false,
                    error: Some(format!(
                        "ASTAP timed out after {} seconds{}",
                        timeout_secs, cleanup_detail
                    )),
                    solve_time_secs: start.elapsed().as_secs_f64(),
                    ..Default::default()
                };
            }
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                drop(stdout_reader);
                drop(stderr_reader);
                return PlateSolveResult {
                    success: false,
                    error: Some(format!("ASTAP wait failed: {}", e)),
                    solve_time_secs: start.elapsed().as_secs_f64(),
                    ..Default::default()
                };
            }
        };

        let stdout_bytes = stdout_reader.join().unwrap_or_default();
        let stderr_bytes = stderr_reader.join().unwrap_or_default();

        let solve_time = start.elapsed().as_secs_f64();

        // Capture ASTAP stdout + stderr for use in failure messages.
        // IMPORTANT: ASTAP exits 0 even when a solve fails. A non-zero exit
        // indicates a launch / argument error (e.g. bad flag, missing file),
        // which is worth surfacing separately. A zero exit with PLTSOLVD=F
        // in the .ini is the normal "not enough stars" failure path.
        let stdout_text = String::from_utf8_lossy(&stdout_bytes).to_string();
        let stderr_text = String::from_utf8_lossy(&stderr_bytes).to_string();
        let exit_code = status.code().unwrap_or(-1);

        if !status.success() {
            // Non-zero exit = argument/launch error, not a solve failure.
            // Surface ASTAP's output verbatim so the user can diagnose.
            let detail = if !stderr_text.trim().is_empty() {
                stderr_text.trim().to_string()
            } else if !stdout_text.trim().is_empty() {
                stdout_text.trim().to_string()
            } else {
                format!("(no output, exit code {})", exit_code)
            };
            tracing::error!(
                "ASTAP exited with non-zero status {}: {}",
                exit_code,
                detail
            );
            return PlateSolveResult {
                success: false,
                error: Some(format!(
                    "ASTAP exited with status {}: {}",
                    exit_code, detail
                )),
                solve_time_secs: solve_time,
                ..Default::default()
            };
        }

        // Parse ASTAP output artifacts. With -wcs, ASTAP writes:
        //   <image>.wcs  — FITS WCS header (CRVAL1/2, CD-matrix)
        //   <image>.ini  — key=value result including PLTSOLVD=T/F
        //
        // The .ini is the authoritative success/failure indicator.
        // The .wcs contains the actual WCS coordinates we need.
        // Parse in this order:
        //   1. Try .ini first to check PLTSOLVD and get an error reason.
        //   2. If PLTSOLVD=T, parse .wcs for the full CD-matrix solution.
        //   3. Fall back to .ini coordinates if .wcs is missing.

        let ini_path = scratch.artifact("ini");
        let wcs_path = scratch.artifact("wcs");

        // Check .ini for PLTSOLVD flag — gives us the ASTAP-side result
        // and any error information before attempting to parse coordinates.
        if ini_path.exists() {
            // Read ini to check PLTSOLVD and extract any error message
            match fs::read_to_string(&ini_path) {
                Ok(ini_content) => {
                    let solved = ini_content
                        .lines()
                        .any(|l| l.trim().eq_ignore_ascii_case("PLTSOLVD=T"));

                    if !solved {
                        // Extract ASTAP's error reason from the ini file and
                        // from the stdout/stderr for a diagnostic message.
                        let ini_reason = ini_content
                            .lines()
                            .find(|l| {
                                let u = l.to_ascii_uppercase();
                                u.starts_with("ERROR") || u.starts_with("REASON")
                            })
                            .unwrap_or("PLTSOLVD=F")
                            .trim()
                            .to_string();

                        let extra = [stdout_text.trim(), stderr_text.trim()]
                            .iter()
                            .filter(|s| !s.is_empty())
                            .cloned()
                            .collect::<Vec<_>>()
                            .join(" | ");

                        let msg = if extra.is_empty() {
                            format!("ASTAP could not solve: {}", ini_reason)
                        } else {
                            format!("ASTAP could not solve: {} | {}", ini_reason, extra)
                        };

                        tracing::warn!("{}", msg);
                        // `scratch` removes the artifacts as it drops.
                        return PlateSolveResult {
                            success: false,
                            error: Some(msg),
                            solve_time_secs: solve_time,
                            ..Default::default()
                        };
                    }
                }
                Err(e) => {
                    tracing::warn!("Could not read ASTAP .ini at {:?}: {}", ini_path, e);
                    // Fall through and attempt .wcs anyway
                }
            }
        }

        // PLTSOLVD=T (or no .ini yet — proceed optimistically).
        // Parse the .wcs file for the full CD-matrix solution.
        if wcs_path.exists() {
            let result = match self.parse_wcs_file(&wcs_path, solve_time) {
                Ok(r) => r,
                Err(err) => {
                    let msg = format!(
                        "ASTAP reported success but .wcs parse failed: {} | stdout: {} | stderr: {}",
                        err,
                        stdout_text.trim(),
                        stderr_text.trim()
                    );
                    tracing::error!("{}", msg);
                    PlateSolveResult {
                        success: false,
                        error: Some(msg),
                        solve_time_secs: solve_time,
                        ..Default::default()
                    }
                }
            };
            return result;
        }

        // No .wcs — fall back to .ini coordinates (produced by -update;
        // also present with -wcs for some ASTAP versions).
        if ini_path.exists() {
            return self.parse_astap_ini(&ini_path, solve_time);
        }

        // No output artifacts at all — ASTAP produced neither .wcs nor .ini.
        // This typically means ASTAP was given a non-FITS file or the image
        // path contains characters ASTAP can't handle.
        let msg = format!(
            "ASTAP produced no output artifacts (.wcs / .ini missing). \
             stdout: {} | stderr: {}",
            stdout_text.trim(),
            stderr_text.trim()
        );
        tracing::error!("{}", msg);
        PlateSolveResult {
            success: false,
            error: Some(msg),
            solve_time_secs: solve_time,
            ..Default::default()
        }
    }

    /// Parse ASTAP .ini result file
    fn parse_astap_ini(&self, ini_path: &Path, solve_time: f64) -> PlateSolveResult {
        match parse_astap_ini_inner(ini_path, solve_time) {
            Ok(result) => result,
            Err(err) => PlateSolveResult {
                success: false,
                error: Some(err.to_string()),
                solve_time_secs: solve_time,
                ..Default::default()
            },
        }
    }

    /// Parse WCS file emitted by ASTAP/astrometry.net.
    ///
    /// Required keywords: CRVAL1, CRVAL2, CD1_1, CD1_2, CD2_1, CD2_2.
    /// Any malformed value or missing required keyword propagates as
    /// `PlateSolveError`; the caller is responsible for converting to a
    /// failed `PlateSolveResult`. Silent fallbacks (RA=0/Dec=0) are forbidden.
    fn parse_wcs_file(
        &self,
        wcs_path: &Path,
        solve_time: f64,
    ) -> Result<PlateSolveResult, PlateSolveError> {
        parse_wcs_file_inner(wcs_path, solve_time)
    }
}

/// Length of one FITS header card, fixed by the standard.
const FITS_CARD_LEN: usize = 80;

/// Split a FITS header into its 80-character cards.
///
/// A `.wcs` file is a raw FITS header: fixed-width cards packed end to end
/// with **no line terminators at all**. Iterating it with `str::lines()`
/// therefore yields the whole header as one enormous "line", so only the very
/// first card (`SIMPLE`) is ever inspected and every keyword after it —
/// `CRVAL1`, the CD matrix, `NAXIS1/2` — is invisible. ASTAP would solve, the
/// parse would then report the solution as missing `CRVAL1`, and the caller
/// counted a successful solve as a failed one: `Plate Solve & Center` failed
/// every attempt and took the run down with it.
///
/// Newlines are still honoured first, because some solvers (and this module's
/// own test fixtures) do write one card per line; only segments longer than a
/// single card are split further.
fn fits_header_cards(content: &str) -> Vec<&str> {
    let mut cards = Vec::new();
    for segment in content.lines() {
        if segment.len() <= FITS_CARD_LEN {
            cards.push(segment);
            continue;
        }
        let bytes = segment.as_bytes();
        let mut start = 0;
        while start < bytes.len() {
            let end = (start + FITS_CARD_LEN).min(bytes.len());
            // A FITS header is ASCII, so every card boundary is a char
            // boundary. Anything else is not a header we can card-split;
            // hand back what is left in one piece rather than panicking on a
            // mid-character slice.
            match std::str::from_utf8(&bytes[start..end]) {
                Ok(card) => cards.push(card),
                Err(_) => {
                    cards.push(&segment[start..]);
                    break;
                }
            }
            start = end;
        }
    }
    cards
}

/// Free-function form of WCS parsing so the test module can exercise it
/// without instantiating an `AstapSolver` (which requires a real ASTAP
/// install on PATH).
fn parse_wcs_file_inner(
    wcs_path: &Path,
    solve_time: f64,
) -> Result<PlateSolveResult, PlateSolveError> {
    let path_display = wcs_path.display().to_string();
    let content = fs::read_to_string(wcs_path).map_err(|source| PlateSolveError::ReadOutput {
        path: path_display.clone(),
        source,
    })?;

    let mut ra: Option<f64> = None;
    let mut dec: Option<f64> = None;
    let mut cd1_1: Option<f64> = None;
    let mut cd1_2: Option<f64> = None;
    let mut cd2_1: Option<f64> = None;
    let mut cd2_2: Option<f64> = None;
    // Image dimensions in pixels. ASTAP writes NAXIS1/NAXIS2 to its .wcs;
    // astrometry.net writes IMAGEW/IMAGEH. Needed to recover the field size so
    // the reference pixel (CRPIX) lands on the image centre — without it the WCS
    // is anchored to the corner, offsetting every pixel<->sky map by half a field.
    let mut naxis1: Option<f64> = None;
    let mut naxis2: Option<f64> = None;
    let mut a_order: Option<u32> = None;
    let mut b_order: Option<u32> = None;
    let mut ap_order: Option<u32> = None;
    let mut bp_order: Option<u32> = None;
    let mut a_terms: Vec<(u32, u32, f64)> = Vec::new();
    let mut b_terms: Vec<(u32, u32, f64)> = Vec::new();
    let mut ap_terms: Vec<(u32, u32, f64)> = Vec::new();
    let mut bp_terms: Vec<(u32, u32, f64)> = Vec::new();

    for line in fits_header_cards(&content) {
        if line.len() < 10 {
            continue;
        }

        let keyword = line[..8].trim();
        if !line[8..].starts_with('=') {
            continue;
        }

        let value_part = line[10..].trim();
        let value_str = if let Some(idx) = value_part.find('/') {
            &value_part[..idx]
        } else {
            value_part
        }
        .trim();

        let parse = |slot: &mut Option<f64>| -> Result<(), PlateSolveError> {
            let parsed = value_str
                .parse::<f64>()
                .map_err(|source| PlateSolveError::WcsParse {
                    keyword: keyword.to_string(),
                    raw_value: value_str.to_string(),
                    path: path_display.clone(),
                    source,
                })?;
            *slot = Some(parsed);
            Ok(())
        };
        let parse_order = |slot: &mut Option<u32>| -> Result<(), PlateSolveError> {
            let parsed = value_str
                .parse::<f64>()
                .map_err(|source| PlateSolveError::WcsParse {
                    keyword: keyword.to_string(),
                    raw_value: value_str.to_string(),
                    path: path_display.clone(),
                    source,
                })?;
            *slot = Some(parsed as u32);
            Ok(())
        };
        let parse_term = |terms: &mut Vec<(u32, u32, f64)>,
                          body: &str|
         -> Result<(), PlateSolveError> {
            let Some((i, j)) = sip_indices(body) else {
                return Ok(());
            };
            let coeff = value_str
                .parse::<f64>()
                .map_err(|source| PlateSolveError::WcsParse {
                    keyword: keyword.to_string(),
                    raw_value: value_str.to_string(),
                    path: path_display.clone(),
                    source,
                })?;
            terms.push((i, j, coeff));
            Ok(())
        };

        match keyword {
            "CRVAL1" => parse(&mut ra)?,
            "CRVAL2" => parse(&mut dec)?,
            "CD1_1" => parse(&mut cd1_1)?,
            "CD1_2" => parse(&mut cd1_2)?,
            "CD2_1" => parse(&mut cd2_1)?,
            "CD2_2" => parse(&mut cd2_2)?,
            "NAXIS1" | "IMAGEW" => parse(&mut naxis1)?,
            "NAXIS2" | "IMAGEH" => parse(&mut naxis2)?,
            "A_ORDER" => parse_order(&mut a_order)?,
            "B_ORDER" => parse_order(&mut b_order)?,
            "AP_ORDER" => parse_order(&mut ap_order)?,
            "BP_ORDER" => parse_order(&mut bp_order)?,
            k if k.starts_with("AP_") => parse_term(&mut ap_terms, &k[3..])?,
            k if k.starts_with("BP_") => parse_term(&mut bp_terms, &k[3..])?,
            k if k.starts_with("A_") => parse_term(&mut a_terms, &k[2..])?,
            k if k.starts_with("B_") => parse_term(&mut b_terms, &k[2..])?,
            _ => {}
        }
    }

    let require = |slot: Option<f64>, name: &str| -> Result<f64, PlateSolveError> {
        slot.ok_or_else(|| PlateSolveError::WcsMissingKeyword {
            keyword: name.to_string(),
            path: path_display.clone(),
        })
    };
    let ra = require(ra, "CRVAL1")?;
    let dec = require(dec, "CRVAL2")?;
    let cd1_1 = require(cd1_1, "CD1_1")?;
    let cd1_2 = require(cd1_2, "CD1_2")?;
    let cd2_1 = require(cd2_1, "CD2_1")?;
    let cd2_2 = require(cd2_2, "CD2_2")?;

    let pixel_scale = ((cd1_1 * cd1_1 + cd2_1 * cd2_1).sqrt() * 3600.0
        + (cd1_2 * cd1_2 + cd2_2 * cd2_2).sqrt() * 3600.0)
        / 2.0;
    // Field rotation, inverse of the CD-from-rotation convention used when the
    // CD matrix must be reconstructed (SipWcs/WcsInfo::from_plate_solve):
    //   cd1_1 = -scale·cos(rot), cd2_1 = scale·sin(rot)
    // so rot = atan2(cd2_1, -cd1_1). Using atan2(cd2_1, cd1_1) here reports a
    // north-up frame as 180°, disagreeing with the generator and corrupting any
    // fallback CD rebuilt from the scalar rotation.
    //
    // That convention assumes the sky's own parity (east left of north,
    // det(CD) < 0). A frame through one mirror — the owner's Newtonian — has
    // det(CD) > 0, and the same formula then reads 180° minus the angle: his
    // 2026-09-14 NGC 7380 solve parsed here as -158.58° while ASTAP's own
    // CROTA2 for it, and this module's `.ini` parse of the same solve, say
    // -21.41°. ASTAP defines CROTA "E of N if not flipped", which for a
    // mirrored frame is atan2(cd2_1, cd1_1).
    let mirrored = cd1_1 * cd2_2 - cd1_2 * cd2_1 > 0.0;
    let rotation = if mirrored {
        cd2_1.atan2(cd1_1)
    } else {
        cd2_1.atan2(-cd1_1)
    }
    .to_degrees();

    // Field extent in degrees, derived from the image dimensions and pixel
    // scale. Downstream WCS construction divides field_* back by the pixel
    // scale to place CRPIX at the image centre, so a zero here would anchor the
    // reference pixel to the corner. Leave zero only if the solver emitted no
    // dimension keywords at all (older output) — behaviour then matches before.
    let field_width = naxis1.map_or(0.0, |n| n * pixel_scale / 3600.0);
    let field_height = naxis2.map_or(0.0, |n| n * pixel_scale / 3600.0);

    let a_order = a_order.unwrap_or(0);
    let b_order = b_order.unwrap_or(0);
    let ap_order = ap_order.unwrap_or(0);
    let bp_order = bp_order.unwrap_or(0);
    let a_coeffs = sip_layout(a_order, &a_terms);
    let b_coeffs = sip_layout(b_order, &b_terms);
    let ap_coeffs = sip_layout(ap_order, &ap_terms);
    let bp_coeffs = sip_layout(bp_order, &bp_terms);

    Ok(PlateSolveResult {
        ra,
        dec,
        pixel_scale,
        rotation,
        field_width,
        field_height,
        success: true,
        error: None,
        solve_time_secs: solve_time,
        cd1_1,
        cd1_2,
        cd2_1,
        cd2_2,
        a_order,
        b_order,
        a_coeffs,
        b_coeffs,
        ap_order,
        bp_order,
        ap_coeffs,
        bp_coeffs,
    })
}

/// Split a SIP coefficient keyword body (`"2_0"` from `A_2_0`) into its
/// `(i, j)` polynomial indices. Returns `None` for diagnostic siblings like
/// `A_DMAX` so the caller can skip them.
fn sip_indices(body: &str) -> Option<(u32, u32)> {
    let (i, j) = body.split_once('_')?;
    Some((i.parse().ok()?, j.parse().ok()?))
}

/// Pack `(i, j, coeff)` SIP terms into the row-major layout documented on
/// `PlateSolveResult`: index `i * (order + 1) + j`. Missing terms stay 0.0.
/// Returns an empty vec when `order == 0` and no terms were present.
fn sip_layout(order: u32, terms: &[(u32, u32, f64)]) -> Vec<f64> {
    if order == 0 && terms.is_empty() {
        return Vec::new();
    }
    let stride = (order + 1) as usize;
    let mut coeffs = vec![0.0; stride * stride];
    for &(i, j, c) in terms {
        if (i as usize) < stride && (j as usize) < stride {
            coeffs[i as usize * stride + j as usize] = c;
        }
    }
    coeffs
}

/// Free-function form of ASTAP `.ini` parsing so the test module can exercise
/// it without an ASTAP install. Mirrors `parse_wcs_file_inner` semantics:
/// malformed numeric values or `PLTSOLVD != T` propagate as errors instead of
/// silently producing a zero-coordinate "successful" solve.
fn parse_astap_ini_inner(
    ini_path: &Path,
    solve_time: f64,
) -> Result<PlateSolveResult, PlateSolveError> {
    let path_display = ini_path.display().to_string();
    let content = fs::read_to_string(ini_path).map_err(|source| PlateSolveError::ReadOutput {
        path: path_display.clone(),
        source,
    })?;

    let mut ra: Option<f64> = None;
    let mut dec: Option<f64> = None;
    let mut crota: Option<f64> = None;
    let mut cdelt1: Option<f64> = None;
    let mut cdelt2: Option<f64> = None;
    let mut solved = false;

    for line in content.lines() {
        let line = line.trim();
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim().to_uppercase();
        let value = value.trim();

        let parse = |slot: &mut Option<f64>, keyword: &str| -> Result<(), PlateSolveError> {
            let parsed = value
                .parse::<f64>()
                .map_err(|source| PlateSolveError::WcsParse {
                    keyword: keyword.to_string(),
                    raw_value: value.to_string(),
                    path: path_display.clone(),
                    source,
                })?;
            *slot = Some(parsed);
            Ok(())
        };

        match key.as_str() {
            "CRVAL1" => parse(&mut ra, "CRVAL1")?,
            "CRVAL2" => parse(&mut dec, "CRVAL2")?,
            "CROTA1" | "CROTA2" => parse(&mut crota, &key)?,
            "CDELT1" => parse(&mut cdelt1, "CDELT1")?,
            "CDELT2" => parse(&mut cdelt2, "CDELT2")?,
            "PLTSOLVD" => solved = value == "T",
            _ => {}
        }
    }

    if !solved {
        return Err(PlateSolveError::SolveFailed { path: path_display });
    }

    let require = |slot: Option<f64>, name: &str| -> Result<f64, PlateSolveError> {
        slot.ok_or_else(|| PlateSolveError::WcsMissingKeyword {
            keyword: name.to_string(),
            path: path_display.clone(),
        })
    };
    let ra = require(ra, "CRVAL1")?;
    let dec = require(dec, "CRVAL2")?;
    let cdelt1 = require(cdelt1, "CDELT1")?;
    let cdelt2 = require(cdelt2, "CDELT2")?;
    // Why: CROTA1/CROTA2 are *optional* in the FITS WCS standard (Greisen &
    // Calabretta 2002 §2.1.2). ASTAP omits them for north-up frames. When
    // absent, the standard-mandated default is 0.0 — this is a documented
    // WCS convention, not a silent error fallback. A *malformed* CROTA value
    // (parse failure) still propagates as `PlateSolveError::WcsParse` via
    // the `parse(&mut crota, &key)?` call above.
    let crota = crota.unwrap_or(0.0);

    let pixel_scale = (cdelt1.abs() * 3600.0 + cdelt2.abs() * 3600.0) / 2.0;

    Ok(PlateSolveResult {
        ra,
        dec,
        pixel_scale,
        rotation: crota,
        field_width: 0.0,
        field_height: 0.0,
        success: true,
        error: None,
        solve_time_secs: solve_time,
        ..Default::default()
    })
}

/// Blind plate solve (no hint)
pub fn blind_solve(image_path: &Path) -> PlateSolveResult {
    let start = std::time::Instant::now();
    solve_with_external_config(
        image_path,
        None,
        None,
        None,
        PlateSolverConfig::default(),
        start,
    )
}

/// Blind plate solve with a caller-selected subprocess timeout.
///
/// `downsample` is the ASTAP `-z` factor: `None` keeps the configured default,
/// `Some(1)` solves the frame at full resolution, `Some(2)` halves each axis.
/// A caller that already binned the frame in hardware passes `Some(1)` —
/// binning and downsampling compound, and a 4x4 frame halved again has lost
/// the stars the solve needs.
///
/// "Blind" is about POSITION, not scale: `hint_scale` (arcsec/pixel of the
/// frame as taken, i.e. binned) still reaches ASTAP as `-fov` and is what
/// keeps a narrow field off the blind scale ladder. It is a required
/// parameter rather than an optional builder step on purpose — a caller that
/// knows the rig's scale and forgets to pass it is the exact failure this
/// signature makes impossible to write.
pub fn blind_solve_with_timeout(
    image_path: &Path,
    timeout_secs: u32,
    hint_scale: Option<f64>,
    downsample: Option<u32>,
) -> PlateSolveResult {
    let start = std::time::Instant::now();
    let mut config = PlateSolverConfig {
        timeout_secs,
        ..PlateSolverConfig::default()
    };
    if let Some(factor) = downsample {
        config.downsample = factor;
    }
    solve_with_external_config(image_path, None, None, hint_scale, config, start)
}

/// Plate solve with hint coordinates
pub fn solve_near(
    image_path: &Path,
    hint_ra: f64,
    hint_dec: f64,
    search_radius: f64,
) -> PlateSolveResult {
    let start = std::time::Instant::now();
    let config = PlateSolverConfig {
        search_radius,
        ..PlateSolverConfig::default()
    };

    solve_with_external_config(
        image_path,
        Some(hint_ra),
        Some(hint_dec),
        None,
        config,
        start,
    )
}

/// Plate solve near coordinates with a caller-selected subprocess timeout.
///
/// `hint_scale` is arcsec/pixel of the frame as taken (binned). Position and
/// scale are independent hints: passing a position does not tell ASTAP how
/// wide the field is, and a near solve with no scale still walks the blind
/// field-of-view ladder. `downsample` is the ASTAP `-z` factor; `None` keeps
/// the configured default. It does not change `-fov`, which is the angular
/// size of the field and is the same field however many pixels ASTAP reads
/// it at.
pub fn solve_near_with_timeout(
    image_path: &Path,
    hint_ra: f64,
    hint_dec: f64,
    search_radius: f64,
    timeout_secs: u32,
    hint_scale: Option<f64>,
    downsample: Option<u32>,
) -> PlateSolveResult {
    let start = std::time::Instant::now();
    let mut config = PlateSolverConfig {
        search_radius,
        timeout_secs,
        ..PlateSolverConfig::default()
    };
    if let Some(factor) = downsample {
        config.downsample = factor;
    }

    solve_with_external_config(
        image_path,
        Some(hint_ra),
        Some(hint_dec),
        hint_scale,
        config,
        start,
    )
}

fn solve_with_external_config(
    image_path: &Path,
    hint_ra: Option<f64>,
    hint_dec: Option<f64>,
    hint_scale: Option<f64>,
    config: PlateSolverConfig,
    start: std::time::Instant,
) -> PlateSolveResult {
    match config.solver_choice {
        PlateSolverChoice::Astap => {
            if config.astap_path.is_none() {
                return PlateSolveResult {
                    success: false,
                    error: Some("ASTAP is selected but is not available".to_string()),
                    solve_time_secs: start.elapsed().as_secs_f64(),
                    ..Default::default()
                };
            }
            AstapSolver::new(config).solve(image_path, hint_ra, hint_dec, hint_scale)
        }
        PlateSolverChoice::Astrometry => {
            let Some(astrometry_path) = config.astrometry_path.as_deref() else {
                return PlateSolveResult {
                    success: false,
                    error: Some(
                        "Astrometry.net is selected but solve-field is not available".to_string(),
                    ),
                    solve_time_secs: start.elapsed().as_secs_f64(),
                    ..Default::default()
                };
            };
            solve_with_astrometry(
                astrometry_path,
                image_path,
                hint_ra,
                hint_dec,
                config.search_radius,
                config.timeout_secs,
                start,
            )
        }
        PlateSolverChoice::Auto => {
            if config.astap_path.is_some() {
                let astap_result = AstapSolver::new(config.clone())
                    .solve(image_path, hint_ra, hint_dec, hint_scale);
                if astap_result.success || config.astrometry_path.is_none() {
                    return astap_result;
                }

                tracing::warn!(
                    "ASTAP failed ({}); falling back to astrometry.net",
                    astap_result.error.as_deref().unwrap_or("unknown error")
                );
                let mut astrometry_result = solve_with_astrometry(
                    config
                        .astrometry_path
                        .as_deref()
                        .expect("astrometry path checked above"),
                    image_path,
                    hint_ra,
                    hint_dec,
                    config.search_radius,
                    config.timeout_secs,
                    start,
                );
                if !astrometry_result.success {
                    astrometry_result.error = Some(format!(
                        "ASTAP failed: {}. Astrometry.net failed: {}",
                        astap_result.error.as_deref().unwrap_or("unknown error"),
                        astrometry_result
                            .error
                            .as_deref()
                            .unwrap_or("unknown error")
                    ));
                }
                return astrometry_result;
            }

            if let Some(astrometry_path) = config.astrometry_path.as_deref() {
                return solve_with_astrometry(
                    astrometry_path,
                    image_path,
                    hint_ra,
                    hint_dec,
                    config.search_radius,
                    config.timeout_secs,
                    start,
                );
            }

            external_solver_unavailable(start)
        }
    }
}

struct SolverCommandOutput {
    status: std::process::ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

fn run_solver_command(
    cmd: &mut Command,
    timeout_secs: u32,
    label: &str,
) -> Result<SolverCommandOutput, String> {
    let mut child = cmd
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("Failed to launch {label}: {error}"))?;
    let child_id = child.id();
    let mut stdout = child.stdout.take();
    let stdout_reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        if let Some(pipe) = stdout.as_mut() {
            let _ = pipe.read_to_end(&mut bytes);
        }
        bytes
    });
    let mut stderr = child.stderr.take();
    let stderr_reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        if let Some(pipe) = stderr.as_mut() {
            let _ = pipe.read_to_end(&mut bytes);
        }
        bytes
    });

    let timeout = std::time::Duration::from_secs(u64::from(timeout_secs));
    let status = match child.wait_timeout(timeout) {
        Ok(Some(status)) => status,
        Ok(None) => {
            tracing::error!(
                "{} (pid {}) timed out after {} seconds; terminating it",
                label,
                child_id,
                timeout_secs
            );
            let kill_error = child.kill().err();
            let reap_error = child.wait().err();
            drop(stdout_reader);
            drop(stderr_reader);
            let cleanup = match (kill_error, reap_error) {
                (None, None) => String::new(),
                (kill, reap) => format!(
                    " (cleanup: kill={}, reap={})",
                    kill.map_or_else(|| "ok".to_string(), |e| e.to_string()),
                    reap.map_or_else(|| "ok".to_string(), |e| e.to_string())
                ),
            };
            return Err(format!(
                "{label} timed out after {timeout_secs} seconds{cleanup}"
            ));
        }
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            drop(stdout_reader);
            drop(stderr_reader);
            return Err(format!("Failed waiting for {label}: {error}"));
        }
    };

    Ok(SolverCommandOutput {
        status,
        stdout: stdout_reader.join().unwrap_or_default(),
        stderr: stderr_reader.join().unwrap_or_default(),
    })
}

fn solve_with_astrometry(
    astrometry_path: &Path,
    image_path: &Path,
    hint_ra: Option<f64>,
    hint_dec: Option<f64>,
    search_radius: f64,
    timeout_secs: u32,
    start: std::time::Instant,
) -> PlateSolveResult {
    // `solve-field` writes its whole product set (.axy, .corr, .rdls,
    // .solved, .new, .wcs) into `--dir`, named after the input frame. Give it
    // a directory we own so none of it lands beside the operator's capture.
    // See `SolveScratch`.
    let scratch = SolveScratch::new(image_path);
    let output_dir = scratch.work_dir().to_path_buf();
    let image_path = scratch.input();
    let wcs_path = scratch.artifact("wcs");
    if wcs_path.exists() {
        if let Err(error) = fs::remove_file(&wcs_path) {
            return PlateSolveResult {
                success: false,
                error: Some(format!(
                    "Failed to remove stale astrometry.net WCS output {:?}: {}",
                    wcs_path, error
                )),
                solve_time_secs: start.elapsed().as_secs_f64(),
                ..Default::default()
            };
        }
    }

    let mut cmd = Command::new(astrometry_path);
    cmd.arg("--overwrite")
        .arg("--no-plots")
        .arg("--dir")
        .arg(output_dir)
        .arg(image_path);

    if let (Some(ra), Some(dec)) = (hint_ra, hint_dec) {
        cmd.arg("--ra")
            .arg(format!("{}", ra))
            .arg("--dec")
            .arg(format!("{}", dec));
        if search_radius > 0.0 {
            cmd.arg("--radius").arg(format!("{}", search_radius));
        }
    }

    tracing::info!("Running astrometry.net solve-field: {:?}", cmd);

    let output = match run_solver_command(&mut cmd, timeout_secs, "astrometry.net solve-field") {
        Ok(output) => output,
        Err(error) => {
            return PlateSolveResult {
                success: false,
                error: Some(error),
                solve_time_secs: start.elapsed().as_secs_f64(),
                ..Default::default()
            }
        }
    };

    let solve_time = start.elapsed().as_secs_f64();
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let detail = if !stderr.trim().is_empty() {
            stderr.trim()
        } else if !stdout.trim().is_empty() {
            stdout.trim()
        } else {
            "no solver output"
        };
        return PlateSolveResult {
            success: false,
            error: Some(format!("astrometry.net solve-field failed: {}", detail)),
            solve_time_secs: solve_time,
            ..Default::default()
        };
    }

    match parse_wcs_file_inner(&wcs_path, solve_time) {
        Ok(result) => result,
        Err(error) => PlateSolveResult {
            success: false,
            error: Some(error.to_string()),
            solve_time_secs: solve_time,
            ..Default::default()
        },
    }
}

fn external_solver_unavailable(start: std::time::Instant) -> PlateSolveResult {
    PlateSolveResult {
        success: false,
        error: Some(
            "No supported external plate solver is configured. Install ASTAP and make astap_cli available on PATH or configure its executable path before solving."
                .to_string(),
        ),
        solve_time_secs: start.elapsed().as_secs_f64(),
        ..Default::default()
    }
}

/// Check if any plate solver (ASTAP or local astrometry.net) is reachable on
/// disk. Returns `false` if neither is found at any well-known install path
/// or via PATH lookup. Result is cached after first call; see
/// `DISCOVERED_SOLVERS` doc for rationale.
pub fn is_solver_available() -> bool {
    let discovered = discovered_solvers();
    discovered.astap.is_some() || discovered.astrometry.is_some()
}

/// Drop the cached solver-discovery answer so the next call re-probes the
/// filesystem. Called whenever the user updates the solver path via the
/// settings UI.
pub fn invalidate_solver_availability_cache() {
    *DISCOVERED_SOLVERS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
}

/// Get path to installed solver
pub fn get_solver_path() -> Option<PathBuf> {
    let discovered = discovered_solvers();
    discovered.astap.or(discovered.astrometry)
}

#[cfg(test)]
mod tests {
    use super::{
        external_solver_unavailable, parse_astap_ini_inner, parse_wcs_file_inner, PlateSolveError,
    };
    use std::io::Write;
    use std::path::PathBuf;

    /// Build a single FITS-style WCS card line, padded to the column layout
    /// `parse_wcs_file_inner` expects: keyword in cols 0..8, `=` at col 8,
    /// value starting at col 10.
    fn wcs_card(keyword: &str, value: &str) -> String {
        let mut line = String::with_capacity(80);
        line.push_str(&format!("{:<8}", keyword));
        line.push('=');
        line.push(' ');
        line.push_str(value);
        line.push('\n');
        line
    }

    fn write_temp(name: &str, contents: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let id = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path =
            std::env::temp_dir().join(format!("skotiq-{}-{}-{}.txt", name, std::process::id(), id));
        let mut f = std::fs::File::create(&path).expect("create temp file");
        f.write_all(contents.as_bytes()).expect("write temp file");
        path
    }

    #[test]
    fn unavailable_external_solver_fails_with_operator_guidance() {
        let result = external_solver_unavailable(std::time::Instant::now());
        assert!(!result.success);
        let error = result.error.expect("error guidance");
        assert!(error.contains("Install ASTAP"));
        assert!(error.contains("astap_cli"));
    }

    #[test]
    fn parse_wcs_file_succeeds_on_well_formed_input() {
        let mut content = String::new();
        content.push_str(&wcs_card("CRVAL1", "150.123"));
        content.push_str(&wcs_card("CRVAL2", "20.456"));
        content.push_str(&wcs_card("CD1_1", "-0.000358"));
        content.push_str(&wcs_card("CD1_2", "0.000001"));
        content.push_str(&wcs_card("CD2_1", "0.000001"));
        content.push_str(&wcs_card("CD2_2", "0.000358"));
        let path = write_temp("wcs-good", &content);

        let result = parse_wcs_file_inner(&path, 0.42).expect("well-formed WCS must parse");
        assert!(result.success);
        assert!((result.ra - 150.123).abs() < 1e-9);
        assert!((result.dec - 20.456).abs() < 1e-9);
        assert!(result.pixel_scale > 0.0);

        let _ = std::fs::remove_file(path);
    }

    /// One 80-character FITS card, padded, with no line terminator — the way
    /// ASTAP actually writes `.wcs`.
    fn padded_card(keyword: &str, value: &str) -> String {
        let body = format!("{keyword:<8}= {value}");
        format!("{body:<80}")
    }

    /// A real ASTAP `.wcs` is a stream of fixed 80-character cards with **no
    /// newlines**, and the camera's own metadata pushes the WCS keywords well
    /// past the first card. Parsing it with `str::lines()` sees only `SIMPLE`
    /// and reports the solve as missing `CRVAL1`, so every `Plate Solve &
    /// Center` attempt fails against a solution ASTAP has already found — and
    /// the failure takes the whole run with it.
    #[test]
    fn parse_wcs_file_reads_a_newline_free_card_stream() {
        let mut content = padded_card("SIMPLE", "                   T");
        // Instrument metadata ASTAP copies from the source frame, enough of it
        // to push the solution past the first 2880-byte header block.
        for index in 0..40 {
            content.push_str(&padded_card(&format!("NSPAD{index:03}"), "0"));
        }
        content.push_str(&padded_card("CRVAL1", "150.123 / RA of reference pixel"));
        content.push_str(&padded_card("CRVAL2", "20.456 / DEC of reference pixel"));
        content.push_str(&padded_card("CD1_1", "-0.000358"));
        content.push_str(&padded_card("CD1_2", "0.000001"));
        content.push_str(&padded_card("CD2_1", "0.000001"));
        content.push_str(&padded_card("CD2_2", "0.000358"));
        content.push_str(&padded_card("NAXIS1", "1920"));
        content.push_str(&padded_card("NAXIS2", "1080"));
        assert!(!content.contains('\n'), "fixture must have no newlines");

        let path = write_temp("wcs-card-stream", &content);
        let result =
            parse_wcs_file_inner(&path, 0.3).expect("a card-stream .wcs must parse like any other");

        assert!(result.success);
        assert!((result.ra - 150.123).abs() < 1e-9, "ra was {}", result.ra);
        assert!((result.dec - 20.456).abs() < 1e-9, "dec was {}", result.dec);
        assert!(result.pixel_scale > 0.0);

        let _ = std::fs::remove_file(path);
    }

    /// NAXIS drives the field size so the reconstructed
    /// WCS anchors CRPIX on the image centre (not the corner at 0.5), and a
    /// north-up CD matrix parses back as rotation 0°, not 180°.
    #[test]
    fn parse_wcs_populates_field_size_and_centres_crpix() {
        let mut content = String::new();
        content.push_str(&wcs_card("CRVAL1", "150.0"));
        content.push_str(&wcs_card("CRVAL2", "20.0"));
        // 1 arcsec/px, north-up east-left (standard sky orientation).
        content.push_str(&wcs_card("CD1_1", "-0.0002777778"));
        content.push_str(&wcs_card("CD1_2", "0.0"));
        content.push_str(&wcs_card("CD2_1", "0.0"));
        content.push_str(&wcs_card("CD2_2", "0.0002777778"));
        content.push_str(&wcs_card("NAXIS1", "1000"));
        content.push_str(&wcs_card("NAXIS2", "800"));
        let path = write_temp("wcs-naxis", &content);

        let r = parse_wcs_file_inner(&path, 0.0).expect("WCS must parse");
        let _ = std::fs::remove_file(&path);

        assert!(
            (r.pixel_scale - 1.0).abs() < 1e-3,
            "scale {}",
            r.pixel_scale
        );
        // field size in degrees = NAXIS * (arcsec/px) / 3600.
        assert!(
            (r.field_width - 1000.0 / 3600.0).abs() < 1e-4,
            "field_width {}",
            r.field_width
        );
        assert!(
            (r.field_height - 800.0 / 3600.0).abs() < 1e-4,
            "field_height {}",
            r.field_height
        );
        // A north-up solve parses to rotation 0.
        assert!(r.rotation.abs() < 1e-6, "rotation {}", r.rotation);

        // Reconstructed reference pixel is the 1-based image centre, not (0.5,0.5).
        let wcs = crate::wcs_sip::SipWcs::from_plate_solve(&r).expect("invertible WCS");
        assert!((wcs.crpix1 - 500.5).abs() < 1e-6, "crpix1 {}", wcs.crpix1);
        assert!((wcs.crpix2 - 400.5).abs() < 1e-6, "crpix2 {}", wcs.crpix2);
    }

    /// Parse round-trip (NOT an on-sky accuracy claim): a WCS carrying the full
    /// anisotropic CD matrix plus a 2nd-order SIP forward/inverse distortion
    /// must read back the four CD terms verbatim and pack the SIP coefficients
    /// into the documented row-major `i * (order + 1) + j` layout.
    #[test]
    fn parse_wcs_file_reads_cd_matrix_and_sip_terms() {
        let mut content = String::new();
        content.push_str(&wcs_card("CRVAL1", "150.0"));
        content.push_str(&wcs_card("CRVAL2", "20.0"));
        content.push_str(&wcs_card("CD1_1", "-0.000351"));
        content.push_str(&wcs_card("CD1_2", "0.000017"));
        content.push_str(&wcs_card("CD2_1", "0.000019"));
        content.push_str(&wcs_card("CD2_2", "0.000349"));
        content.push_str(&wcs_card("A_ORDER", "2"));
        content.push_str(&wcs_card("A_0_2", "1.1e-6"));
        content.push_str(&wcs_card("A_1_1", "-2.2e-6"));
        content.push_str(&wcs_card("A_2_0", "3.3e-6"));
        content.push_str(&wcs_card("B_ORDER", "2"));
        content.push_str(&wcs_card("B_0_2", "4.4e-6"));
        content.push_str(&wcs_card("B_2_0", "5.5e-6"));
        content.push_str(&wcs_card("AP_ORDER", "1"));
        content.push_str(&wcs_card("AP_1_0", "6.6e-6"));
        content.push_str(&wcs_card("BP_ORDER", "1"));
        content.push_str(&wcs_card("BP_0_1", "7.7e-6"));
        let path = write_temp("wcs-cd-sip", &content);

        let result = parse_wcs_file_inner(&path, 0.0).expect("CD + SIP WCS must parse");
        assert_eq!(result.cd1_1, -0.000351);
        assert_eq!(result.cd1_2, 0.000017);
        assert_eq!(result.cd2_1, 0.000019);
        assert_eq!(result.cd2_2, 0.000349);

        assert_eq!(result.a_order, 2);
        assert_eq!(result.b_order, 2);
        assert_eq!(result.a_coeffs.len(), 9);
        assert_eq!(result.b_coeffs.len(), 9);
        // Row-major (i, j) with order 2 => stride 3: A_0_2 -> 2, A_1_1 -> 4, A_2_0 -> 6.
        assert_eq!(result.a_coeffs[2], 1.1e-6);
        assert_eq!(result.a_coeffs[4], -2.2e-6);
        assert_eq!(result.a_coeffs[6], 3.3e-6);
        assert_eq!(result.b_coeffs[2], 4.4e-6);
        assert_eq!(result.b_coeffs[6], 5.5e-6);
        assert_eq!(result.b_coeffs[4], 0.0);

        assert_eq!(result.ap_order, 1);
        assert_eq!(result.bp_order, 1);
        assert_eq!(result.ap_coeffs.len(), 4);
        assert_eq!(result.ap_coeffs[2], 6.6e-6);
        assert_eq!(result.bp_coeffs[1], 7.7e-6);

        let _ = std::fs::remove_file(path);
    }

    /// SIP is optional: a CD-only WCS must leave the coefficient vectors empty
    /// (NOT zero-filled) and the orders at zero.
    #[test]
    fn parse_wcs_file_leaves_sip_empty_when_absent() {
        let mut content = String::new();
        content.push_str(&wcs_card("CRVAL1", "150.0"));
        content.push_str(&wcs_card("CRVAL2", "20.0"));
        content.push_str(&wcs_card("CD1_1", "-0.000358"));
        content.push_str(&wcs_card("CD1_2", "0.000001"));
        content.push_str(&wcs_card("CD2_1", "0.000001"));
        content.push_str(&wcs_card("CD2_2", "0.000358"));
        let path = write_temp("wcs-no-sip", &content);

        let result = parse_wcs_file_inner(&path, 0.0).expect("CD-only WCS must parse");
        assert_eq!(result.a_order, 0);
        assert!(result.a_coeffs.is_empty());
        assert!(result.b_coeffs.is_empty());
        assert!(result.ap_coeffs.is_empty());
        assert!(result.bp_coeffs.is_empty());

        let _ = std::fs::remove_file(path);
    }

    /// A malformed CRVAL1 must NOT silently produce a "successful" solve at
    /// RA=0/Dec=0. The parser must return `PlateSolveError::WcsParse`.
    #[test]
    fn parse_wcs_file_rejects_malformed_crval1() {
        let mut content = String::new();
        content.push_str(&wcs_card("CRVAL1", "not-a-number"));
        content.push_str(&wcs_card("CRVAL2", "20.456"));
        content.push_str(&wcs_card("CD1_1", "-0.000358"));
        content.push_str(&wcs_card("CD1_2", "0.000001"));
        content.push_str(&wcs_card("CD2_1", "0.000001"));
        content.push_str(&wcs_card("CD2_2", "0.000358"));
        let path = write_temp("wcs-bad-crval1", &content);

        let err = parse_wcs_file_inner(&path, 0.0)
            .expect_err("malformed CRVAL1 must NOT produce a zero-coordinate solve");
        match err {
            PlateSolveError::WcsParse {
                keyword, raw_value, ..
            } => {
                assert_eq!(keyword, "CRVAL1");
                assert_eq!(raw_value, "not-a-number");
            }
            other => panic!("expected WcsParse, got {other:?}"),
        }

        let _ = std::fs::remove_file(path);
    }

    /// A malformed CD-matrix value must also propagate.
    #[test]
    fn parse_wcs_file_rejects_malformed_cd_matrix() {
        let mut content = String::new();
        content.push_str(&wcs_card("CRVAL1", "150.0"));
        content.push_str(&wcs_card("CRVAL2", "20.0"));
        content.push_str(&wcs_card("CD1_1", "0.001"));
        content.push_str(&wcs_card("CD1_2", "0.0"));
        content.push_str(&wcs_card("CD2_1", "garbage"));
        content.push_str(&wcs_card("CD2_2", "0.001"));
        let path = write_temp("wcs-bad-cd21", &content);

        let err = parse_wcs_file_inner(&path, 0.0).expect_err("malformed CD2_1 must error");
        match err {
            PlateSolveError::WcsParse {
                keyword, raw_value, ..
            } => {
                assert_eq!(keyword, "CD2_1");
                assert_eq!(raw_value, "garbage");
            }
            other => panic!("expected WcsParse, got {other:?}"),
        }

        let _ = std::fs::remove_file(path);
    }

    /// A missing required keyword must error rather than yielding zeros.
    #[test]
    fn parse_wcs_file_rejects_missing_required_keyword() {
        // Omit CRVAL2 entirely.
        let mut content = String::new();
        content.push_str(&wcs_card("CRVAL1", "150.0"));
        content.push_str(&wcs_card("CD1_1", "0.001"));
        content.push_str(&wcs_card("CD1_2", "0.0"));
        content.push_str(&wcs_card("CD2_1", "0.0"));
        content.push_str(&wcs_card("CD2_2", "0.001"));
        let path = write_temp("wcs-missing-crval2", &content);

        let err = parse_wcs_file_inner(&path, 0.0).expect_err("missing CRVAL2 must error");
        match err {
            PlateSolveError::WcsMissingKeyword { keyword, .. } => {
                assert_eq!(keyword, "CRVAL2");
            }
            other => panic!("expected WcsMissingKeyword, got {other:?}"),
        }

        let _ = std::fs::remove_file(path);
    }

    /// The ASTAP `.ini` parser must not silently zero-out a malformed CRVAL.
    #[test]
    fn parse_astap_ini_rejects_malformed_crval2() {
        let content = "PLTSOLVD=T\nCRVAL1=150.0\nCRVAL2=not-a-number\nCDELT1=-0.000358\nCDELT2=0.000358\nCROTA1=12.34\n";
        let path = write_temp("ini-bad-crval2", content);

        let err = parse_astap_ini_inner(&path, 0.0).expect_err("malformed CRVAL2 must error");
        match err {
            PlateSolveError::WcsParse {
                keyword, raw_value, ..
            } => {
                assert_eq!(keyword, "CRVAL2");
                assert_eq!(raw_value, "not-a-number");
            }
            other => panic!("expected WcsParse, got {other:?}"),
        }

        let _ = std::fs::remove_file(path);
    }

    /// `PLTSOLVD != T` must surface as a `SolveFailed` error, not as a
    /// "successful" zero-coordinate result.
    #[test]
    fn parse_astap_ini_rejects_unsolved_flag() {
        let content = "PLTSOLVD=F\nCRVAL1=150.0\nCRVAL2=20.0\nCDELT1=-0.000358\nCDELT2=0.000358\n";
        let path = write_temp("ini-not-solved", content);

        let err = parse_astap_ini_inner(&path, 0.0).expect_err("PLTSOLVD=F must error");
        assert!(matches!(err, PlateSolveError::SolveFailed { .. }));

        let _ = std::fs::remove_file(path);
    }

    /// Catalog detection must walk an exe-relative dir and surface the catalog
    /// flavour + magnitude limit from filename markers.
    #[test]
    fn detect_astap_catalog_finds_v17_next_to_exe() {
        let temp = std::env::temp_dir().join(format!(
            "skotiq-platesolve-cat-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&temp).expect("create temp dir");
        // Stage a fake catalog file with the V17 marker plus an ASTAP exe.
        let exe = temp.join(if cfg!(target_os = "windows") {
            "astap.exe"
        } else {
            "astap"
        });
        std::fs::write(&exe, b"#!fake").expect("write fake exe");
        std::fs::write(temp.join("V17_0101.290"), b"fake catalog index")
            .expect("write fake catalog");
        std::fs::write(temp.join("V17_0102.290"), b"fake catalog index")
            .expect("write fake catalog");

        let info = super::detect_astap_catalog(Some(&exe), None).expect("must find V17 catalog");
        assert_eq!(info.name, "V17");
        assert_eq!(info.magnitude_limit, Some(17.0));
        assert_eq!(info.path, temp);

        let _ = std::fs::remove_dir_all(&temp);
    }

    /// The catalog search must probe around an exe the MODULE discovered, not
    /// only one the operator configured.
    ///
    /// The owner's rig on 2026-09-15: ASTAP at `C:\Program Files\astap\astap.exe`
    /// with a `d80_*.1476` catalog beside it, solving that night's frames to
    /// 0.17" — and nothing configured by hand, because nothing needed to be.
    /// With `ACTIVE_SOLVER_PREF.astap_path` empty the search was handed no exe
    /// at all, never looked in the exe's own directory (and
    /// `C:\Program Files\astap` is not in `catalog_dir_candidates`' well-known
    /// set either), and reported the catalog missing to every run.
    #[test]
    fn catalog_search_falls_back_to_the_discovered_exe() {
        let configured = PathBuf::from("/configured/astap");
        let discovered = PathBuf::from("/usr/bin/astap");

        assert_eq!(
            super::catalog_search_fallback(None, Some(discovered.clone()), None),
            (Some(discovered.clone()), None),
            "a discovered-but-unconfigured exe is the exe the search must probe around"
        );
        assert_eq!(
            super::catalog_search_fallback(Some(configured.clone()), Some(discovered), None).0,
            Some(configured),
            "what the operator configured still wins"
        );
        assert_eq!(
            super::catalog_search_fallback(None, None, None),
            (None, None),
            "no exe anywhere is the only state that may conclude one is unavailable"
        );
    }

    /// The composition the fallback exists for: a catalog sitting beside an exe
    /// nobody configured is found.
    #[test]
    fn a_catalog_beside_a_discovered_exe_is_found() {
        let temp = std::env::temp_dir().join(format!(
            "skotiq-platesolve-cat-disc-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&temp).expect("create temp dir");
        let exe = temp.join(if cfg!(target_os = "windows") {
            "astap.exe"
        } else {
            "astap"
        });
        std::fs::write(&exe, b"#!fake").expect("write fake exe");
        // Lower-case tag and the `.1476` extension the owner's D80 install
        // uses, so this is the catalog the preflight said did not exist.
        std::fs::write(temp.join("d80_0001.1476"), b"fake").expect("write fake catalog");

        // Nothing configured; the exe is only what the module discovered.
        let (resolved_exe, resolved_catalog) =
            super::catalog_search_fallback(None, Some(exe), None);
        let info =
            super::detect_astap_catalog(resolved_exe.as_deref(), resolved_catalog.as_deref())
                .expect("a catalog beside a discovered exe must be found");
        assert_eq!(info.name, "D80");
        assert_eq!(info.path, temp);

        let _ = std::fs::remove_dir_all(&temp);
    }

    /// A configured catalog directory must take precedence.
    #[test]
    fn detect_astap_catalog_honours_configured_override() {
        let temp = std::env::temp_dir().join(format!(
            "skotiq-platesolve-cat-cfg-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&temp).expect("create temp dir");
        std::fs::write(temp.join("D80_0001.1476"), b"fake").expect("write fake catalog");

        let info = super::detect_astap_catalog(None, Some(&temp))
            .expect("configured override must locate catalog");
        assert_eq!(info.name, "D80");
        assert_eq!(info.magnitude_limit, Some(12.0));

        let _ = std::fs::remove_dir_all(&temp);
    }

    /// `verify_solver` on a missing path must produce a structured `Missing`
    /// error rather than panicking or claiming success.
    #[test]
    fn verify_solver_reports_missing_path() {
        let bogus =
            std::env::temp_dir().join(format!("skotiq-no-such-solver-{}.bin", std::process::id()));
        let err = super::verify_solver(&bogus).expect_err("missing path must error");
        match err {
            super::SolverVerifyError::Missing(p) => assert_eq!(p, bogus),
            other => panic!("expected Missing, got {other:?}"),
        }
    }

    #[cfg(unix)]
    #[test]
    fn verify_solver_times_out_and_reaps_a_hung_probe() {
        let dir = std::env::temp_dir().join(format!(
            "skotiq-verify-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("solver");
        let pid_file = dir.join("pid");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\necho $$ > '{}'\nexec sleep 30\n",
                pid_file.display()
            ),
        )
        .unwrap();
        make_executable(&script);
        let started = std::time::Instant::now();
        let error = super::verify_solver_with_timeout(&script, 1).unwrap_err();
        assert!(error.to_string().contains("timed out"), "{error}");
        assert!(started.elapsed() < std::time::Duration::from_secs(3));
        let pid = std::fs::read_to_string(pid_file).unwrap();
        assert!(!std::process::Command::new("kill")
            .args(["-0", pid.trim()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success());
        std::fs::write(&script, "#!/bin/sh\nprintf 'ASTAP test CLI\\n'\n").unwrap();
        let info = super::verify_solver_with_timeout(&script, 1).unwrap();
        assert_eq!(info.flavour, "ASTAP");
        assert_eq!(info.version_line, "ASTAP test CLI");
        std::fs::remove_dir_all(dir).unwrap();
    }

    // Global solver-preference wiring and the catalog -d flag

    /// `ACTIVE_SOLVER_PREF` and the discovery cache are process-global, so the
    /// tests that mutate them must not run concurrently with each other.
    static PREF_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn lock_solver_pref() -> std::sync::MutexGuard<'static, ()> {
        PREF_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Setting the global solver preference via `set_solver_preference` must
    /// make `PlateSolverConfig::default()` resolve the configured ASTAP path
    /// rather than falling through to the system candidate list.
    ///
    /// `blind_solve` and `solve_near` both build their config through
    /// `PlateSolverConfig::default()`, so a custom install path set in
    /// Settings → Plate Solving reaches the solve only if the default config
    /// consults the persisted preference before the candidate list.
    #[test]
    fn set_solver_preference_makes_default_config_resolve_configured_path() {
        use super::{set_solver_preference, PlateSolverConfig};

        let _pref_guard = lock_solver_pref();

        // Use a unique non-existent path so the candidate list cannot
        // accidentally match a real ASTAP install on the test machine.
        let fake_astap = std::env::temp_dir().join(format!(
            "fake-astap-{}-{}.exe",
            std::process::id(),
            "pref-test"
        ));
        // Write a zero-byte file so `Path::exists()` returns true.
        std::fs::write(&fake_astap, b"").expect("write fake astap");

        let fake_catalog = std::env::temp_dir().join(format!(
            "fake-catalog-{}-{}",
            std::process::id(),
            "pref-test"
        ));
        std::fs::create_dir_all(&fake_catalog).expect("create fake catalog dir");

        set_solver_preference(
            Some(fake_astap.to_str().unwrap()),
            None,
            Some(fake_catalog.to_str().unwrap()),
            Some("astap"),
        );

        let config = PlateSolverConfig::default();
        assert_eq!(
            config.astap_path.as_deref(),
            Some(fake_astap.as_path()),
            "PlateSolverConfig::default() must resolve the configured ASTAP path"
        );
        assert_eq!(
            config.catalog_path.as_deref(),
            Some(fake_catalog.as_path()),
            "PlateSolverConfig::default() must include the configured catalog path"
        );
        assert_eq!(config.solver_choice, super::PlateSolverChoice::Astap);

        // Reset global to avoid polluting other tests.
        set_solver_preference(None, None, None, None);
        let _ = std::fs::remove_file(&fake_astap);
        let _ = std::fs::remove_dir_all(&fake_catalog);
    }

    /// Solver discovery is probed once and then served from the cache;
    /// without it every `PlateSolverConfig::default()` re-stats the whole
    /// candidate list and shells out to `which`/`where`, twice per solve.
    ///
    /// Observable proof of the cache: delete the file the probe found. An
    /// uncached resolver reports `None` on the next call; a cached one keeps
    /// returning the path until it is invalidated.
    #[test]
    fn solver_discovery_is_cached_until_invalidated() {
        use super::{
            get_solver_path, invalidate_solver_availability_cache, is_solver_available,
            set_solver_preference, PlateSolverConfig,
        };

        let _pref_guard = lock_solver_pref();

        let fake_astap = std::env::temp_dir().join(format!(
            "fake-astap-cache-{}-{}.exe",
            std::process::id(),
            "discovery-test"
        ));
        std::fs::write(&fake_astap, b"").expect("write fake astap");

        // Setting the preference must invalidate, so this resolves the new path.
        set_solver_preference(
            Some(fake_astap.to_str().unwrap()),
            None,
            None,
            Some("astap"),
        );
        assert_eq!(
            PlateSolverConfig::default().astap_path.as_deref(),
            Some(fake_astap.as_path()),
            "set_solver_preference must invalidate the discovery cache"
        );
        assert!(is_solver_available());
        assert_eq!(get_solver_path().as_deref(), Some(fake_astap.as_path()));

        // The filesystem changes underneath us; the cached answer must stand.
        std::fs::remove_file(&fake_astap).expect("remove fake astap");
        assert_eq!(
            PlateSolverConfig::default().astap_path.as_deref(),
            Some(fake_astap.as_path()),
            "second default() re-probed the filesystem instead of using the cache"
        );
        assert_eq!(get_solver_path().as_deref(), Some(fake_astap.as_path()));

        // Explicit invalidation re-probes and now finds nothing at that path.
        invalidate_solver_availability_cache();
        assert_ne!(
            PlateSolverConfig::default().astap_path.as_deref(),
            Some(fake_astap.as_path()),
            "invalidate_solver_availability_cache must force a re-probe"
        );

        set_solver_preference(None, None, None, None);
    }

    /// After `set_solver_preference` is called with an empty string for all
    /// fields (Settings cleared / reset to auto), `PlateSolverConfig::default()`
    /// must not retain the old configured path.
    #[test]
    fn clear_solver_preference_reverts_to_auto_detect() {
        use super::{set_solver_preference, PlateSolverConfig};

        let _pref_guard = lock_solver_pref();

        // Set something, then clear it.
        set_solver_preference(
            Some("/tmp/fake-astap-clear-test"),
            None,
            None,
            Some("astap"),
        );
        // Clear by passing empty / None
        set_solver_preference(None, None, None, None);

        let config = PlateSolverConfig::default();
        assert_eq!(config.solver_choice, super::PlateSolverChoice::Auto);
        // The path `/tmp/fake-astap-clear-test` does not exist, so after
        // clearing, the config should NOT have that path (the candidate list
        // won't find it either since it's a made-up path).
        assert!(
            config
                .astap_path
                .as_deref()
                .map(|p| p.to_str().unwrap_or(""))
                .unwrap_or("")
                != "/tmp/fake-astap-clear-test",
            "cleared preference must not persist the old configured path"
        );
    }

    /// `PlateSolverConfig` must include `catalog_path` and, when the ASTAP
    /// solve command is built, the catalog directory must appear as `-d <dir>`.
    /// This test verifies the struct field is propagated — the actual command
    /// build is not testable without a real binary, but the presence of the
    /// field in the config is the necessary condition.
    #[test]
    fn platesolver_config_has_catalog_path_field() {
        use super::PlateSolverConfig;
        use std::path::PathBuf;

        let cat_dir = PathBuf::from(r"C:\astap\catalogs");
        let config = PlateSolverConfig {
            astap_path: None,
            astrometry_path: None,
            catalog_path: Some(cat_dir.clone()),
            search_radius: 5.0,
            downsample: 2,
            timeout_secs: 60,
            solver_choice: super::PlateSolverChoice::Auto,
        };
        assert_eq!(config.catalog_path.as_deref(), Some(cat_dir.as_path()));
    }

    /// The standard Windows ASTAP install path must appear in the candidate
    /// list produced by `astap_candidates` for the Windows OS family.
    /// Without it a plain `C:\Program Files\astap\astap.exe` install is
    /// invisible to auto-detect.
    #[test]
    fn astap_candidates_windows_includes_standard_program_files_path() {
        use super::platesolve_paths::{astap_candidates, AstapPathInputs, OsFamily};
        use std::path::PathBuf;

        let candidates = astap_candidates(&AstapPathInputs {
            os: OsFamily::Windows,
            configured: None,
            local_app_data: None,
            home: None,
        });

        assert!(
            candidates.contains(&PathBuf::from(r"C:\Program Files\astap\astap.exe")),
            "standard Windows ASTAP path must be in the candidate list"
        );
        assert!(
            candidates.contains(&PathBuf::from(r"C:\Program Files\astap\astap_cli.exe")),
            "standard Windows ASTAP CLI path must be in the candidate list"
        );
        let cli = candidates
            .iter()
            .position(|p| p == &PathBuf::from(r"C:\Program Files\astap\astap_cli.exe"))
            .unwrap();
        let gui = candidates
            .iter()
            .position(|p| p == &PathBuf::from(r"C:\Program Files\astap\astap.exe"))
            .unwrap();
        assert!(
            cli < gui,
            "prefer the CLI when both executables are installed"
        );
    }

    /// A solved ASTAP .ini with PLTSOLVD=T must parse successfully and
    /// surface CRVAL1/CRVAL2/CDELT1/CDELT2/CROTA correctly.
    #[test]
    fn parse_astap_ini_succeeds_on_solved_frame() {
        let content = concat!(
            "PLTSOLVD=T\n",
            "CRVAL1=150.250\n",
            "CRVAL2=20.500\n",
            "CDELT1=-0.000358\n",
            "CDELT2=0.000358\n",
            "CROTA2=15.3\n",
        );
        let path = write_temp("ini-solved", content);
        let result =
            super::parse_astap_ini_inner(&path, 1.23).expect("solved ASTAP .ini must parse");
        assert!(result.success);
        assert!((result.ra - 150.250).abs() < 1e-6, "RA mismatch");
        assert!((result.dec - 20.500).abs() < 1e-6, "Dec mismatch");
        assert!((result.rotation - 15.3).abs() < 1e-6, "rotation mismatch");
        assert!(result.pixel_scale > 0.0, "pixel scale must be positive");
        assert!((result.solve_time_secs - 1.23).abs() < 1e-9);
        let _ = std::fs::remove_file(path);
    }

    /// Names left in the folder the caller asked us to solve, excluding the
    /// image itself. Any entry here is solver debris in the user's capture
    /// folder.
    #[cfg(unix)]
    fn debris_beside(capture_dir: &std::path::Path, image: &std::path::Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(capture_dir)
            .expect("read capture dir")
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|path| path != image)
            .filter_map(|path| {
                path.file_name()
                    .map(|name| name.to_string_lossy().into_owned())
            })
            .collect();
        names.sort();
        names
    }

    /// Serialises the tests that write an executable fixture and then run it.
    /// A `fork` on another test's thread inherits the still-open write
    /// descriptor, and exec'ing the script inside that window fails with
    /// ETXTBSY ("Text file busy") — a race in the harness, not the solver.
    #[cfg(unix)]
    fn lock_script_fixtures() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    #[cfg(unix)]
    fn make_executable(path: &std::path::Path) {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = std::fs::metadata(path)
            .expect("solver metadata")
            .permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(path, permissions).expect("make solver executable");
    }

    /// A `.wcs` body ASTAP/astrometry.net would have written for a solved
    /// frame, in the newline-free 80-column card form both really emit.
    #[cfg(unix)]
    fn solved_wcs_body() -> String {
        let mut content = padded_card("SIMPLE", "                   T");
        content.push_str(&padded_card("CRVAL1", "150.123"));
        content.push_str(&padded_card("CRVAL2", "20.456"));
        content.push_str(&padded_card("CD1_1", "-0.000358"));
        content.push_str(&padded_card("CD1_2", "0.000001"));
        content.push_str(&padded_card("CD2_1", "0.000001"));
        content.push_str(&padded_card("CD2_2", "0.000358"));
        content.push_str(&padded_card("NAXIS1", "1920"));
        content.push_str(&padded_card("NAXIS2", "1080"));
        content
    }

    /// SCI-48: ASTAP writes `<image>.ini` / `<image>.wcs` next to the file it
    /// was pointed at. When the solve is cut short — the solver hangs and we
    /// kill it — those artifacts stayed behind in the operator's capture
    /// folder, where the next session sees `M31_L_0007.ini` sitting beside
    /// `M31_L_0007.fits`.
    #[cfg(unix)]
    #[test]
    fn astap_leaves_no_debris_in_the_capture_folder() {
        use super::{AstapSolver, PlateSolverChoice, PlateSolverConfig};
        let _fixtures = lock_script_fixtures();

        let nonce = format!("{}-astap-debris", std::process::id());
        let dir = std::env::temp_dir().join(format!("skotiq-solver-{nonce}"));
        let _ = std::fs::remove_dir_all(&dir);
        let capture = dir.join("captures");
        std::fs::create_dir_all(&capture).expect("create capture dir");
        let image = capture.join("M31_L_0007.fits");
        std::fs::write(&image, b"fixture").expect("write fake image");

        // Emulates ASTAP: writes its result files against the input file's
        // base name, then hangs so the runner has to terminate it.
        let script = dir.join("astap-hang.sh");
        std::fs::write(
            &script,
            "#!/bin/sh\ninput=\"\"\nwhile [ \"$#\" -gt 0 ]; do\n  if [ \"$1\" = \"-f\" ]; then\n\
             input=\"$2\"; shift 2; else shift; fi\ndone\nbase=${input%.*}\n\
             printf 'PLTSOLVD=T\\n' > \"$base.ini\"\nprintf 'x' > \"$base.wcs\"\nsleep 3\n",
        )
        .expect("write hanging ASTAP fixture");
        make_executable(&script);

        let result = AstapSolver::new(PlateSolverConfig {
            astap_path: Some(script),
            astrometry_path: None,
            catalog_path: None,
            search_radius: 5.0,
            downsample: 0,
            timeout_secs: 1,
            solver_choice: PlateSolverChoice::Astap,
        })
        .solve(&image, None, None, None);

        assert!(!result.success, "the hung solver must not report success");
        assert_eq!(
            debris_beside(&capture, &image),
            Vec::<String>::new(),
            "the solver left files in the operator's capture folder"
        );

        let _ = std::fs::remove_dir_all(dir);
    }

    /// SCI-48: astrometry.net's `solve-field` writes a whole product set —
    /// `.axy`, `.corr`, `.solved`, `.new`, `.wcs` — into whatever directory
    /// it is given. It was given the capture folder, and nothing removed any
    /// of it, including on the successful path.
    #[cfg(unix)]
    #[test]
    fn astrometry_leaves_no_debris_in_the_capture_folder() {
        use super::{solve_with_external_config, PlateSolverChoice, PlateSolverConfig};
        let _fixtures = lock_script_fixtures();

        let nonce = format!("{}-astrometry-debris", std::process::id());
        let dir = std::env::temp_dir().join(format!("skotiq-solver-{nonce}"));
        let _ = std::fs::remove_dir_all(&dir);
        let capture = dir.join("captures");
        std::fs::create_dir_all(&capture).expect("create capture dir");
        let image = capture.join("M31_L_0007.fits");
        std::fs::write(&image, b"fixture").expect("write fake image");
        let wcs_fixture = dir.join("solution.wcs");
        std::fs::write(&wcs_fixture, solved_wcs_body()).expect("write wcs fixture");

        let script = dir.join("solve-field.sh");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\nout=.\ninput=\"\"\nwhile [ \"$#\" -gt 0 ]; do\n  case \"$1\" in\n\
                 --dir) out=\"$2\"; shift 2;;\n    --ra|--dec|--radius) shift 2;;\n\
                 --overwrite|--no-plots) shift;;\n    *) input=\"$1\"; shift;;\n  esac\ndone\n\
                 stem=$(basename \"$input\"); stem=${{stem%.*}}\n\
                 cp '{}' \"$out/$stem.wcs\"\nfor ext in axy corr rdls solved new; do\n\
                 printf 'x' > \"$out/$stem.$ext\"\ndone\n",
                wcs_fixture.display()
            ),
        )
        .expect("write fake solve-field");
        make_executable(&script);

        let result = solve_with_external_config(
            &image,
            None,
            None,
            None,
            PlateSolverConfig {
                astap_path: None,
                astrometry_path: Some(script),
                catalog_path: None,
                search_radius: 5.0,
                downsample: 0,
                timeout_secs: 10,
                solver_choice: PlateSolverChoice::Astrometry,
            },
            std::time::Instant::now(),
        );

        assert!(result.success, "solve failed: {:?}", result.error);
        assert!((result.ra - 150.123).abs() < 1e-9, "ra was {}", result.ra);
        assert_eq!(
            debris_beside(&capture, &image),
            Vec::<String>::new(),
            "solve-field left its product set in the operator's capture folder"
        );

        let _ = std::fs::remove_dir_all(dir);
    }

    /// A `.wcs` the operator already had (an earlier export, a sidecar they
    /// keep) is not ours to delete — the cleanup must only reclaim what this
    /// solve created.
    #[cfg(unix)]
    #[test]
    fn cleanup_keeps_files_that_were_there_before_the_solve() {
        use super::{AstapSolver, PlateSolverChoice, PlateSolverConfig};
        let _fixtures = lock_script_fixtures();

        let nonce = format!("{}-preexisting", std::process::id());
        let dir = std::env::temp_dir().join(format!("skotiq-solver-{nonce}"));
        let _ = std::fs::remove_dir_all(&dir);
        let capture = dir.join("captures");
        std::fs::create_dir_all(&capture).expect("create capture dir");
        let image = capture.join("M31_L_0007.fits");
        std::fs::write(&image, b"fixture").expect("write fake image");
        let keepsake = capture.join("M31_L_0007.txt");
        std::fs::write(&keepsake, b"operator notes").expect("write operator file");

        let script = dir.join("astap-noop.sh");
        std::fs::write(&script, "#!/bin/sh\nexit 0\n").expect("write no-op ASTAP fixture");
        make_executable(&script);

        let _ = AstapSolver::new(PlateSolverConfig {
            astap_path: Some(script),
            astrometry_path: None,
            catalog_path: None,
            search_radius: 5.0,
            downsample: 0,
            timeout_secs: 5,
            solver_choice: PlateSolverChoice::Astap,
        })
        .solve(&image, None, None, None);

        assert!(
            keepsake.exists(),
            "the solve deleted a file it did not create"
        );
        assert!(image.exists(), "the solve deleted the operator's capture");

        let _ = std::fs::remove_dir_all(dir);
    }

    /// The in-place fallback (no private directory could be staged) reclaims
    /// exactly what the solve created: same base name, new since the solve
    /// started, and a file rather than a directory.
    #[test]
    fn in_place_fallback_reclaims_only_this_solve_s_artifacts() {
        use super::reclaim_new_artifacts;

        let dir = std::env::temp_dir().join(format!(
            "skotiq-reclaim-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("create fixture dir");
        let image = dir.join("M31_L_0007.fits");
        let operator_sidecar = dir.join("M31_L_0007.xisf");
        let unrelated = dir.join("M42_L_0001.ini");
        for path in [&image, &operator_sidecar, &unrelated] {
            std::fs::write(path, b"pre-existing").expect("write pre-existing file");
        }
        let existing: Vec<std::ffi::OsString> = std::fs::read_dir(&dir)
            .expect("snapshot fixture dir")
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name())
            .collect();

        // What the solve then produced.
        let ini = dir.join("M31_L_0007.ini");
        let wcs = dir.join("M31_L_0007.wcs");
        for path in [&ini, &wcs] {
            std::fs::write(path, b"solver output").expect("write solver artifact");
        }

        reclaim_new_artifacts(&dir, "M31_L_0007", &existing);

        assert!(!ini.exists(), ".ini artifact was left behind");
        assert!(!wcs.exists(), ".wcs artifact was left behind");
        assert!(image.exists(), "the capture itself was deleted");
        assert!(
            operator_sidecar.exists(),
            "a pre-existing sidecar was deleted"
        );
        assert!(unrelated.exists(), "another frame's file was deleted");

        let _ = std::fs::remove_dir_all(dir);
    }

    /// The sparing rule is a BASE NAME rule, not a string prefix.
    ///
    /// A bare `starts_with(stem)` deletes any new file whose name merely
    /// begins with the solved frame's stem — and the in-place fallback only
    /// fires on exFAT / FAT32 capture drives and SMB shares, where the camera
    /// is still writing new lights into that same folder while the solve runs.
    /// Solving `M31.fits` there reclaimed `M31_L_0008.fits` (a light that had
    /// just landed) and `M31_session.log` along with the real debris.
    #[test]
    fn reclaim_spares_files_that_merely_share_the_stem_as_a_prefix() {
        use super::reclaim_new_artifacts;

        let dir = std::env::temp_dir().join(format!(
            "skotiq-reclaim-prefix-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("create fixture dir");
        let image = dir.join("M31.fits");
        std::fs::write(&image, b"pre-existing").expect("write the frame being solved");
        let existing: Vec<std::ffi::OsString> = std::fs::read_dir(&dir)
            .expect("snapshot fixture dir")
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name())
            .collect();

        // Real debris from this solve.
        let ini = dir.join("M31.ini");
        let wcs = dir.join("M31.wcs");
        // Not debris: written during the solve, sharing only the prefix.
        let new_light = dir.join("M31_L_0008.fits");
        let session_log = dir.join("M31_session.log");
        let operator_dark = dir.join("M31_dark.ini");
        for path in [&ini, &wcs, &new_light, &session_log, &operator_dark] {
            std::fs::write(path, b"x").expect("write fixture file");
        }

        reclaim_new_artifacts(&dir, "M31", &existing);

        assert!(!ini.exists(), ".ini debris was left behind");
        assert!(!wcs.exists(), ".wcs debris was left behind");
        assert!(image.exists(), "the capture itself was deleted");
        assert!(
            new_light.exists(),
            "a light the camera wrote during the solve was deleted"
        );
        assert!(session_log.exists(), "the session log was deleted");
        assert!(
            operator_dark.exists(),
            "another frame's sidecar was deleted on a prefix match"
        );

        let _ = std::fs::remove_dir_all(dir);
    }

    /// An unknown extension on an exact base-name match is still not ours.
    /// Only the extensions solvers actually emit are reclaimed.
    #[test]
    fn reclaim_only_touches_known_solver_extensions() {
        use super::reclaim_new_artifacts;

        let dir = std::env::temp_dir().join(format!(
            "skotiq-reclaim-ext-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("create fixture dir");
        let existing: Vec<std::ffi::OsString> = Vec::new();

        let axy = dir.join("M31_L_0007.axy");
        let corr = dir.join("M31_L_0007.corr");
        let rdls = dir.join("M31_L_0007.rdls");
        let solved = dir.join("M31_L_0007.solved");
        let renamed = dir.join("M31_L_0007.new");
        let notes = dir.join("M31_L_0007.txt");
        let sidecar_xisf = dir.join("M31_L_0007.xisf");
        for path in [&axy, &corr, &rdls, &solved, &renamed, &notes, &sidecar_xisf] {
            std::fs::write(path, b"x").expect("write fixture file");
        }

        reclaim_new_artifacts(&dir, "M31_L_0007", &existing);

        for path in [&axy, &corr, &rdls, &solved, &renamed] {
            assert!(!path.exists(), "solve-field debris {:?} was left", path);
        }
        assert!(notes.exists(), "an operator note was deleted");
        assert!(sidecar_xisf.exists(), "an image sidecar was deleted");

        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn explicit_astrometry_choice_does_not_run_available_astap() {
        use super::{solve_with_external_config, PlateSolverChoice, PlateSolverConfig};
        use std::os::unix::fs::PermissionsExt;
        let _fixtures = lock_script_fixtures();

        let nonce = format!("{}-choice", std::process::id());
        let dir = std::env::temp_dir().join(format!("skotiq-solver-{nonce}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create solver-choice fixture dir");
        let astap = dir.join("astap.sh");
        let astrometry = dir.join("solve-field.sh");
        let astap_marker = dir.join("astap-ran");
        let astrometry_marker = dir.join("astrometry-ran");
        let image = dir.join("frame.fits");
        std::fs::write(&image, b"fixture").expect("write fake image");
        std::fs::write(
            &astap,
            format!(
                "#!/bin/sh\nprintf ran > '{}'\nexit 1\n",
                astap_marker.display()
            ),
        )
        .expect("write fake ASTAP");
        std::fs::write(
            &astrometry,
            format!(
                "#!/bin/sh\nprintf ran > '{}'\nexit 1\n",
                astrometry_marker.display()
            ),
        )
        .expect("write fake astrometry");
        for executable in [&astap, &astrometry] {
            let mut permissions = std::fs::metadata(executable)
                .expect("solver metadata")
                .permissions();
            permissions.set_mode(0o755);
            std::fs::set_permissions(executable, permissions).expect("make solver executable");
        }

        let result = solve_with_external_config(
            &image,
            Some(150.0),
            Some(42.0),
            None,
            PlateSolverConfig {
                astap_path: Some(astap.clone()),
                astrometry_path: Some(astrometry.clone()),
                catalog_path: None,
                search_radius: 5.0,
                downsample: 0,
                timeout_secs: 5,
                solver_choice: PlateSolverChoice::Astrometry,
            },
            std::time::Instant::now(),
        );

        assert!(!result.success);
        assert!(
            astrometry_marker.exists(),
            "selected astrometry did not run"
        );
        assert!(
            !astap_marker.exists(),
            "ASTAP ran despite explicit astrometry selection"
        );

        std::fs::remove_file(&astrometry_marker).expect("reset astrometry marker");
        let auto_result = solve_with_external_config(
            &image,
            Some(150.0),
            Some(42.0),
            None,
            PlateSolverConfig {
                astap_path: Some(astap),
                astrometry_path: Some(astrometry.clone()),
                catalog_path: None,
                search_radius: 5.0,
                downsample: 0,
                timeout_secs: 5,
                solver_choice: PlateSolverChoice::Auto,
            },
            std::time::Instant::now(),
        );
        assert!(!auto_result.success);
        assert!(astap_marker.exists(), "Auto did not try ASTAP first");
        assert!(
            astrometry_marker.exists(),
            "Auto did not fall back to astrometry after ASTAP failed"
        );
        let combined = auto_result.error.unwrap_or_default();
        assert!(combined.contains("ASTAP failed"));
        assert!(combined.contains("Astrometry.net failed"));

        let late_marker = dir.join("astrometry-late-output");
        std::fs::write(
            &astrometry,
            format!(
                "#!/bin/sh\nsleep 2\nprintf late > '{}'\n",
                late_marker.display()
            ),
        )
        .expect("write hanging astrometry fixture");
        let timeout_result = solve_with_external_config(
            &image,
            Some(150.0),
            Some(42.0),
            None,
            PlateSolverConfig {
                astap_path: None,
                astrometry_path: Some(astrometry),
                catalog_path: None,
                search_radius: 5.0,
                downsample: 0,
                timeout_secs: 1,
                solver_choice: PlateSolverChoice::Astrometry,
            },
            std::time::Instant::now(),
        );
        assert!(!timeout_result.success);
        assert!(timeout_result
            .error
            .as_deref()
            .unwrap_or_default()
            .contains("timed out"));
        std::thread::sleep(std::time::Duration::from_millis(1_500));
        assert!(
            !late_marker.exists(),
            "timed-out astrometry.net continued running"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn timed_out_astap_is_terminated_before_it_can_write_late_output() {
        use super::{AstapSolver, PlateSolverConfig};
        let _fixtures = lock_script_fixtures();
        use std::os::unix::fs::PermissionsExt;

        let nonce = format!(
            "{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock after epoch")
                .as_nanos()
        );
        let dir = std::env::temp_dir().join(format!("skotiq-solver-timeout-{nonce}"));
        std::fs::create_dir_all(&dir).expect("create timeout fixture dir");
        let script = dir.join("fake-astap.sh");
        let image = dir.join("frame.fits");
        let marker = dir.join("late-output");
        std::fs::write(&image, b"fixture").expect("write fake image");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\nsleep 2\nprintf stale > '{}'\n",
                marker.display()
            ),
        )
        .expect("write fake ASTAP");
        let mut permissions = std::fs::metadata(&script)
            .expect("fake ASTAP metadata")
            .permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&script, permissions).expect("make fake ASTAP executable");

        let solver = AstapSolver::new(PlateSolverConfig {
            astap_path: Some(script),
            astrometry_path: None,
            catalog_path: None,
            search_radius: 5.0,
            downsample: 0,
            timeout_secs: 1,
            solver_choice: super::PlateSolverChoice::Astap,
        });
        let result = solver.solve(&image, None, None, None);
        assert!(!result.success);
        assert!(
            result
                .error
                .as_deref()
                .unwrap_or_default()
                .contains("timed out"),
            "unexpected timeout result: {:?}",
            result.error
        );
        std::thread::sleep(std::time::Duration::from_millis(1_500));
        assert!(
            !marker.exists(),
            "timed-out ASTAP continued running and wrote a late result"
        );

        let _ = std::fs::remove_dir_all(dir);
    }
}

/// Shared `.wcs` conformance fixture, consumed by this crate AND by the Dart
/// `PlateSolveService` tests. Declared here (not under `tests/`) because the
/// parsers it pins are private to this module.
#[cfg(test)]
#[path = "platesolve_wcs_conformance_tests.rs"]
mod wcs_conformance;

/// The `-fov` hint, pinned on the argument vector the ASTAP *process* is given.
///
/// These read the arguments this crate builds, which is the only argument
/// vector ASTAP ever sees from the desktop app, the headless API and the
/// sequencer alike. `PlateSolveService.astapArguments` (Dart) is a fallback
/// production never runs, so asserting against it proves nothing about a live
/// solve.
#[cfg(test)]
mod astap_arg_tests {
    use super::{build_astap_args, PlateSolverChoice, PlateSolverConfig};
    use std::path::{Path, PathBuf};

    fn config() -> PlateSolverConfig {
        PlateSolverConfig {
            astap_path: Some(PathBuf::from("/usr/bin/astap_cli")),
            astrometry_path: None,
            catalog_path: Some(PathBuf::from("/catalog")),
            search_radius: 10.0,
            downsample: 2,
            timeout_secs: 60,
            solver_choice: PlateSolverChoice::Astap,
        }
    }

    fn args(
        hint_ra: Option<f64>,
        hint_dec: Option<f64>,
        hint_scale: Option<f64>,
        naxis2: Option<f64>,
    ) -> Vec<String> {
        build_astap_args(
            &config(),
            Path::new("/scratch/frame.fits"),
            hint_ra,
            hint_dec,
            hint_scale,
            naxis2,
        )
        .into_iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect()
    }

    fn value_after(args: &[String], flag: &str) -> Option<String> {
        args.iter()
            .position(|a| a == flag)
            .map(|i| args[i + 1].clone())
    }

    /// The polar wizard's own rig: 600 mm at 3.76 um is 1.29"/px, and a
    /// 2048-row frame is 0.7347° of field height.
    #[test]
    fn a_scale_hint_becomes_fov_degrees_of_field_height() {
        let args = args(None, None, Some(1.2926), Some(2048.0));
        assert_eq!(
            value_after(&args, "-fov").as_deref(),
            Some("0.7353"),
            "scale hint did not reach the ASTAP argument vector: {args:?}"
        );
    }

    fn args_with_downsample(downsample: u32, hint_scale: Option<f64>) -> Vec<String> {
        let config = PlateSolverConfig {
            downsample,
            ..config()
        };
        build_astap_args(
            &config,
            Path::new("/scratch/frame.fits"),
            None,
            None,
            hint_scale,
            Some(3520.0),
        )
        .into_iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect()
    }

    /// A frame that is already binned in hardware is solved as it is, and
    /// saying so takes an explicit `-z 1`: omitting the flag hands the frame
    /// back to ASTAP's auto ladder, which is not the same instruction.
    #[test]
    fn an_explicit_no_downsample_reaches_astap_as_z_one() {
        assert_eq!(
            value_after(&args_with_downsample(1, None), "-z").as_deref(),
            Some("1")
        );
    }

    /// Zero is the one value that means "ASTAP decides", and it is sent by
    /// saying nothing.
    #[test]
    fn an_auto_downsample_sends_no_flag() {
        assert!(!args_with_downsample(0, None).iter().any(|a| a == "-z"));
    }

    /// `-fov` is the ANGULAR height of the field. Downsampling changes how
    /// many pixels ASTAP reads that field at, not how wide the field is, so
    /// the scale hint is the same number either way — the polar-alignment
    /// downsample rule depends on this.
    #[test]
    fn downsampling_does_not_move_the_field_of_view_hint() {
        let full = args_with_downsample(1, Some(0.77));
        let halved = args_with_downsample(2, Some(0.77));
        assert_eq!(value_after(&full, "-fov"), value_after(&halved, "-fov"));
        assert_eq!(value_after(&full, "-fov").as_deref(), Some("0.7529"));
    }

    /// A blind solve is a solve with no scale: nothing to convert, no flag.
    #[test]
    fn no_scale_hint_means_no_fov_flag() {
        assert!(!args(None, None, None, Some(2048.0))
            .iter()
            .any(|a| a == "-fov"));
    }

    /// Position and scale are independent hints; a near solve carries both.
    #[test]
    fn a_near_solve_carries_position_and_scale_together() {
        let args = args(Some(30.0), Some(45.0), Some(1.29), Some(1000.0));
        assert_eq!(value_after(&args, "-ra").as_deref(), Some("2.000000"));
        assert_eq!(value_after(&args, "-spd").as_deref(), Some("135.000000"));
        assert_eq!(value_after(&args, "-r").as_deref(), Some("10.00"));
        assert_eq!(value_after(&args, "-fov").as_deref(), Some("0.3583"));
    }

    /// Without the frame height there is no honest field size, so the hint is
    /// dropped rather than guessed — never emitted as a bare or zero `-fov`.
    #[test]
    fn an_unreadable_frame_height_drops_the_hint_instead_of_guessing() {
        assert!(!args(None, None, Some(1.29), None)
            .iter()
            .any(|a| a == "-fov"));
        assert!(!args(None, None, Some(0.0), Some(2048.0))
            .iter()
            .any(|a| a == "-fov"));
    }

    /// The flags that were always there stay there.
    #[test]
    fn the_baseline_flags_are_unchanged() {
        let args = args(None, None, None, None);
        assert_eq!(
            value_after(&args, "-f").as_deref(),
            Some("/scratch/frame.fits")
        );
        assert_eq!(value_after(&args, "-z").as_deref(), Some("2"));
        assert_eq!(value_after(&args, "-d").as_deref(), Some("/catalog"));
        assert_eq!(args.last().map(String::as_str), Some("-wcs"));
        assert!(
            !args.iter().any(|a| a == "-r"),
            "no radius without a position"
        );
    }
}

#[cfg(test)]
mod fits_naxis2_tests {
    use super::fits_naxis2;
    use crate::{write_fits, FitsHeader, ImageData, PixelType};

    #[test]
    fn reads_the_height_without_decoding_pixels() {
        let dir = std::env::temp_dir().join("sk_fits_naxis2_test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("frame.fits");
        let image = ImageData::new(16, 12, 1, PixelType::U16);
        write_fits(&path, &image, &FitsHeader::new()).unwrap();
        assert_eq!(fits_naxis2(&path), Some(12.0));
    }

    #[test]
    fn a_missing_file_reads_as_none() {
        assert_eq!(fits_naxis2(std::path::Path::new("/nonexistent.fits")), None);
    }

    /// The frame's own optics are the scale hint of last resort, and the one
    /// that stays right for an imported frame from somebody else's rig.
    #[test]
    fn the_frame_declares_its_own_plate_scale() {
        let dir = std::env::temp_dir().join("sk_fits_scale_test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scaled.fits");
        let image = ImageData::new(16, 12, 1, PixelType::U16);
        let mut header = FitsHeader::new();
        header.set_float("FOCALLEN", 600.0);
        header.set_float("XPIXSZ", 3.76);
        write_fits(&path, &image, &header).unwrap();

        let scale = super::super::fits_scale_arcsec_per_px(&path).unwrap();
        assert!(
            (scale - 1.292_59).abs() < 1e-4,
            "600 mm at 3.76 um is 1.29\"/px, got {scale}"
        );
    }

    /// A frame with no optics cards yields no hint — never a guess.
    #[test]
    fn a_frame_without_optics_cards_declares_no_scale() {
        let dir = std::env::temp_dir().join("sk_fits_scale_test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("bare.fits");
        let image = ImageData::new(16, 12, 1, PixelType::U16);
        write_fits(&path, &image, &FitsHeader::new()).unwrap();
        assert_eq!(super::super::fits_scale_arcsec_per_px(&path), None);
    }
}

/// The owner's NGC 7380 solve of 2026-09-14, parsed from the files ASTAP
/// itself wrote on the rig (`astap.exe ... -fov 0.75 -z 2 -wcs`), not from
/// hand-built cards: a `.wcs` that is one unterminated card stream, a minimal
/// header with `NAXIS = 0`, and an `.ini` with Windows line ends. That night
/// the app's own solve and this direct run agreed to 0.17", and the scale
/// implied 995 mm at the camera's 3.8 um pitch.
#[cfg(test)]
mod rig_2026_09_14_tests {
    use super::*;

    fn fixture(name: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../test-fixtures/rig-2026-09-14")
            .join(name)
    }

    /// ASTAP's own figures from the files: CRVAL1/2, CDELT1 (deg), CROTA2.
    const RA: f64 = 341.799_384_055;
    const DEC: f64 = 58.135_585_823;
    const SCALE: f64 = 2.187_995_008e-4 * 3600.0;

    fn assert_is_the_rig_solution(result: &PlateSolveResult, source: &str) {
        assert!(result.success, "{source}: {:?}", result.error);
        assert!((result.ra - RA).abs() < 1e-6, "{source}: RA {}", result.ra);
        assert!(
            (result.dec - DEC).abs() < 1e-6,
            "{source}: Dec {}",
            result.dec
        );
        assert!(
            (result.pixel_scale - SCALE).abs() < 5e-4,
            "{source}: {:.4}\"/px against ASTAP's {SCALE:.4}",
            result.pixel_scale
        );
        assert!(
            (result.rotation.abs() - 21.41).abs() < 0.05,
            "{source}: rotation {}",
            result.rotation
        );
        // The figure the operator was told that night: 995 mm at 3.8 um.
        let focal_mm = 206.264_806 * 3.8 / result.pixel_scale;
        assert!((focal_mm - 995.1).abs() < 0.5, "{source}: {focal_mm:.1} mm");
    }

    #[test]
    fn the_rig_wcs_parses_to_the_solution_astap_reported() {
        let wcs = fixture("solve-verify.wcs");
        let raw = fs::read_to_string(&wcs).expect("fixture");
        assert!(
            !raw.contains('\n'),
            "the fixture must stay ASTAP's unterminated card stream"
        );
        let result = parse_wcs_file_inner(&wcs, 0.2).expect("ASTAP's own .wcs must parse");
        assert_is_the_rig_solution(&result, "wcs");
    }

    #[test]
    fn the_rig_ini_parses_to_the_same_solution() {
        let ini = fixture("solve-verify.ini");
        assert!(fs::read(&ini)
            .expect("fixture")
            .windows(2)
            .any(|w| w == b"\r\n"));
        let result = parse_astap_ini_inner(&ini, 0.2).expect("ASTAP's own .ini must parse");
        assert_is_the_rig_solution(&result, "ini");
    }

    #[test]
    fn the_solved_center_is_where_the_rig_reported_it() {
        // 1.24' from NGC 7380's catalog position (22h47m21s, +58 07' 54"),
        // before centering.
        let result = parse_wcs_file_inner(&fixture("solve-verify.wcs"), 0.0).expect("parse");
        let (ra0, dec0) = (341.8375_f64.to_radians(), 58.131_667_f64.to_radians());
        let (ra, dec) = (result.ra.to_radians(), result.dec.to_radians());
        let separation = (dec.sin() * dec0.sin() + dec.cos() * dec0.cos() * (ra - ra0).cos())
            .clamp(-1.0, 1.0)
            .acos()
            .to_degrees()
            * 60.0;
        assert!((separation - 1.24).abs() < 0.05, "{separation:.2}'");
    }

    /// The full solve, when the frame and an ASTAP install are both present.
    /// Neither is on CI, and ASTAP is not installed on the development
    /// machine either, so this usually reports what it skipped.
    #[test]
    fn the_app_solver_reproduces_the_rig_solution_on_the_real_frame() {
        let Some(frame) = std::env::var_os("HOME")
            .map(|h| Path::new(&h).join(".cache/sk-rig-data/2026-09-14/solve/solve-verify.fits"))
            .filter(|p| p.is_file())
        else {
            eprintln!("SKIPPED: the full solve-verify.fits is not on this machine");
            return;
        };
        if find_astap_with_override(None).is_none() {
            eprintln!("SKIPPED: no ASTAP install found");
            return;
        }
        let result = solve_near(&frame, 341.8375, 58.131_667, 5.0);
        assert!(result.success, "{:?}", result.error);
        let arcsec = ((result.ra - RA) * DEC.to_radians().cos()).hypot(result.dec - DEC) * 3600.0;
        assert!(arcsec < 1.0, "{arcsec:.2}\" from the rig's own ASTAP run");
        assert!((result.pixel_scale - SCALE).abs() < 5e-4);
    }
}
