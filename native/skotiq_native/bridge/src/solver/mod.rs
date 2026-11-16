//! The plate-solve service every solve in the app goes through: a sequencer
//! frame, a polar-alignment frame, or a file the app asks about. One solver
//! process runs at a time and a frame is solved once however many callers ask
//! ([`admission`]); a hinted solve escalates to a wide search and then blind
//! inside the operator's timeout ([`ladder`]); and each solve is told the field
//! scale and teaches the camera's scale to the next one ([`scale`]).

mod admission;
mod ladder;
mod scale;

pub(crate) use ladder::{split_solve_budget, SolvePosition};
pub(crate) use scale::{gather_solve_hints, gather_solve_hints_for_camera, SolveHints, SolveScale};

use crate::error::SkotiqError;
use admission::SolvePreference;
use skotiq_imaging::PlateSolveResult;

/// One frame's solve.
pub(crate) struct SolveRequest<'a> {
    /// Where the telescope is thought to point; `None` solves blind.
    pub(crate) position: Option<SolvePosition>,
    /// Arcsec per pixel the caller measured for this exact frame.
    pub(crate) frame_scale: Option<f64>,
    /// The optics and camera the frame was taken with: the scale a solve is
    /// told when neither the caller nor the frame names one, and what a
    /// successful solve teaches.
    pub(crate) scale: &'a SolveScale,
    /// The whole ladder's budget; `None` is the default timeout.
    pub(crate) timeout_secs: Option<u32>,
    /// The ASTAP `-z` factor; `None` keeps the configured default. A frame
    /// already binned in hardware passes `Some(1)` so the reductions do not
    /// compound.
    pub(crate) downsample: Option<u32>,
}

/// Solve the frame at `file_path`. A solve that succeeds teaches its camera
/// the scale it measured (see [`SolveScale::record_measured_scale`]).
pub(crate) async fn solve(
    file_path: &str,
    request: SolveRequest<'_>,
) -> Result<PlateSolveResult, SkotiqError> {
    apply_saved_solver_preference();
    let (label, preference) = match request.position {
        Some(_) => ("near", SolvePreference::Hinted),
        None => ("blind", SolvePreference::Blind),
    };
    let scale_arcsec_per_px = resolve_solve_scale(
        std::path::Path::new(file_path),
        request.frame_scale,
        request.scale,
    );
    let result = admission::coalesced_solve(file_path, label, preference, || {
        ladder::solve_ladder(
            file_path,
            request.position,
            request.timeout_secs,
            scale_arcsec_per_px,
            request.downsample,
        )
    })
    .await?;
    if result.success {
        request.scale.record_measured_scale(result.pixel_scale);
    }
    Ok(result)
}

/// The field scale to hand a solve of `path`, in arcsec/pixel.
///
/// Order of authority:
/// 1. what the caller measured for this exact frame (`frame_scale`),
/// 2. what the frame's own header declares, right even for an imported frame
///    shot on somebody else's rig,
/// 3. the optics and camera of `scale`, computed or remembered.
///
/// With none of the three the solver searches for the scale, and
/// [`SolveScale::log_scale`] says which input is missing.
fn resolve_solve_scale(
    path: &std::path::Path,
    frame_scale: Option<f64>,
    scale: &SolveScale,
) -> Option<f64> {
    if let Some(measured) = frame_scale.filter(|s| s.is_finite() && *s > 0.0) {
        return Some(measured);
    }
    if let Some(declared) = skotiq_platesolve::fits_scale_arcsec_per_px(path) {
        tracing::debug!(
            "Plate solve: field scale {:.2}\"/px read from the frame's own header",
            declared
        );
        return Some(declared);
    }
    let rig = scale.arcsec_per_px();
    if let Some(rig) = rig {
        tracing::debug!(
            "Plate solve: field scale {:.2}\"/px from the rig (the frame carries no \
             FOCALLEN/XPIXSZ)",
            rig
        );
    }
    rig
}

/// Hand the solver crate the operator's saved solver paths and choice.
pub(crate) fn apply_solver_preference(pref: &crate::storage::PlateSolverPreference) {
    fn named(path: &str) -> Option<&str> {
        Some(path).filter(|p| !p.is_empty())
    }
    skotiq_platesolve::set_solver_preference(
        named(&pref.astap_path),
        named(&pref.astrometry_path),
        named(&pref.catalog_path),
        Some(pref.solver_choice.as_str()),
    );
}

/// The solver crate's preference is process memory and starts empty on every
/// launch, so each solve applies the saved one first.
fn apply_saved_solver_preference() {
    match crate::state::get_platesolver_preference() {
        Ok(pref) => apply_solver_preference(&pref),
        Err(e) => tracing::warn!(
            "Could not load plate-solver preference before solve (storage not ready?): {}",
            e
        ),
    }
}
