//! How a frame's file is named: the one rule every capture path uses (a Take
//! Exposures step, a Smart Exposure plan, the Flat Wizard, the second rig).

use crate::expressions::{interpolate_with, EvaluationFrame};
use crate::node::context::ExecutionContext;
use crate::{Binning, ExposureConfig, FrameType};
use std::path::PathBuf;

/// What a burst's frame names read from the step, besides the run and the
/// target in the naming context.
#[derive(Debug, Clone, Copy)]
pub(crate) struct BurstNaming<'a> {
    pub save_to: Option<&'a str>,
    pub frame_type: FrameType,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub binning: Binning,
    pub filter_index: Option<i32>,
    pub duration_secs: f64,
}

impl<'a> BurstNaming<'a> {
    /// A Take Exposures burst of `config` whose frames last `duration_secs`.
    pub fn of(config: &'a ExposureConfig, duration_secs: f64) -> Self {
        Self {
            save_to: config.save_to.as_deref(),
            frame_type: config.frame_type,
            gain: config.gain,
            offset: config.offset,
            binning: config.binning,
            filter_index: config.filter_index,
            duration_secs,
        }
    }
}

/// Per-frame save-path renderer for the `ExposureConfig.save_to` template.
/// Built once in the expose-instruction wrapper (which has ExecutionContext
/// access) and invoked per frame, so the same engine resolves `${frame:04}`
/// and `${exposure.duration:.0f}`.
///
/// Returns `Ok((dir, filename))` where:
/// * `dir` is the directory portion (absolute, with any user-specified
///   sub-directories from the template already expanded), and
/// * `filename` is the rendered file-name portion.
///
/// Errors surface as `InstructionResult::failure` from the caller — a
/// broken save-path template must abort the exposure rather than silently
/// drop frames into the wrong place.
pub type FrameSavePathRenderer =
    Box<dyn Fn(&FrameToName) -> Result<(PathBuf, String), String> + Send + Sync>;

/// What the save-path renderer knows of the frame it names.
#[derive(Debug, Clone, Copy)]
pub struct FrameToName {
    pub index_in_burst: u32,
    pub burst_total: u32,
    /// When the shutter opened: the date and time a frame's name carries.
    pub started_at: chrono::DateTime<chrono::Utc>,
    /// The sensor temperature the camera reported with the frame.
    pub sensor_temp_c: Option<f64>,
}

/// The save path a burst uses when its node sets no `save_to`: a folder per
/// target under the run's save path, as the imaging screen's naming pattern
/// does (`$TARGET/...`). Without the folder every target landed in one
/// directory, and the run wrote into whatever folder the save path named.
pub(crate) const DEFAULT_SAVE_TO_TEMPLATE: &str =
    "${target.name}/${target.name}_${filter}_${frame:04}.fits";

/// Highest frame number the save-path renderer probes for. Far beyond any
/// night; a folder past it gets suffixed names rather than a scan without end.
const SAVE_PATH_FRAME_NUMBER_CEILING: u32 = 1 << 20;

/// The namer of a burst's frames.
///
/// `save_to` semantics:
/// * `None`: render [`DEFAULT_SAVE_TO_TEMPLATE`] under the context's base
///   `save_path`.
/// * `Some(template)`: interpolate `template` and treat the result as a
///   relative path under the context's base `save_path` (or as absolute
///   when the user typed an absolute path). The final component is the
///   filename; any leading path segments are sub-directories that the
///   FITS-save code creates on demand.
///
/// `${frame}` in a save path is the next frame number not yet on disk for
/// that name, in the frame's folder or its Reject folder, not the frame's
/// place in this burst. A burst counting its own frames named the first frame
/// of every Smart Exposure visit `..._0001` and the files collected collision
/// suffixes (`NGC0891_L_0001_025.fits`, rig 2026-10-20); counted from the
/// disk, the number continues across visits, bursts, and a run restarted from
/// its checkpoint.
///
/// Returns `Err` when the burst has no resolvable destination — no base
/// `save_path` and no absolute `save_to`. The caller turns that into a node
/// failure so the frames are never captured-then-dropped.
pub(crate) fn frame_namer(
    context: &ExecutionContext,
    burst: BurstNaming<'_>,
) -> Result<FrameSavePathRenderer, String> {
    let base_path = context.run.rig.save_path.clone();
    let duration_secs = burst.duration_secs;

    let effective_template = burst
        .save_to
        .filter(|t| !t.trim().is_empty())
        .unwrap_or(DEFAULT_SAVE_TO_TEMPLATE)
        .to_string();

    // With no base path the only complete destination is an absolute template.
    // Anything else has nowhere to write, so the burst is refused rather than
    // run to completion counting frames it drops: a run that cannot keep its
    // data must not claim it succeeded.
    if base_path.is_none() && !std::path::Path::new(&effective_template).is_absolute() {
        return Err(format!(
            "Exposure has no save location: the sequencer save path is not set and the node's \
             save_to template (`{effective_template}`) is not an absolute path. Every frame this \
             node captures would be discarded. Set the save path before starting the run."
        ));
    }

    let exposure_gain = burst.gain;
    let exposure_offset = burst.offset;
    let exposure_binning = burst.binning.as_str().to_string();
    let filter_index = burst.filter_index;
    let reject_folder_override = context.run.grading.reject_folder_path.clone();
    // ExecutionContext is cheaply Clone-able (every field is `Arc`/`Copy`).
    let extension = context.run.device_ops.frame_file_extension();
    let mut ctx_snapshot = context.clone();
    // A calibration frame has no target BY NATURE — the shutter is closed or the
    // scope is on a flat panel — so `${target.name}` in the default template
    // could not resolve and the renderer aborted the whole run on frame 1:
    // "Variable `${target.name}` cannot be resolved: no active target". That made
    // the natural shape of a darks/bias sequence (no TargetHeader) impossible to
    // run. Substitute the frame type, so files land as `Dark_...` / `Bias_...`,
    // which is what an astronomer expects a target-less calibration frame to be
    // called.
    //
    // LIGHT frames still hard-fail here: inventing a target name for science
    // data would mislabel the data itself, which is worse than refusing.
    if ctx_snapshot.target_name.is_none() && burst.frame_type.is_calibration() {
        ctx_snapshot.target_name = Some(burst.frame_type.as_str().to_string());
    }

    Ok(Box::new(move |frame: &FrameToName| {
        let render = |frame_number: u32| -> Result<(PathBuf, String), String> {
            let eval = EvaluationFrame {
                frame: Some(frame_number),
                frame_total: Some(frame.burst_total),
                exposure_duration_secs: Some(duration_secs),
                exposure_gain,
                exposure_offset,
                exposure_binning: Some(exposure_binning.clone()),
                filter_position: filter_index,
                now_override: Some(frame.started_at),
                sensor_temp_c: frame.sensor_temp_c,
                ..EvaluationFrame::default()
            };
            let rendered = interpolate_with(
                &effective_template,
                &ctx_snapshot,
                &eval,
                |value: String| path_segment(&value),
            )
            .map_err(|e| e.to_string())?;
            let (dir, name) = split_rendered_save_path(&rendered, base_path.as_ref())?;
            Ok((dir, with_frame_extension(&name, extension)))
        };

        // Held from the probe to the claim, so two bursts saving at once (a
        // second camera in a Parallel branch) never take one name.
        let mut claimed = CLAIMED_FRAME_PATHS
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        claimed.retain(|path| !path.exists());
        let taken = |dir: &std::path::Path, name: &str| {
            let reject_dir =
                crate::instructions::resolve_reject_dir(dir, reject_folder_override.as_deref());
            let path = dir.join(name);
            path.exists() || reject_dir.join(name).exists() || claimed.contains(&path)
        };

        let first = render(1)?;
        let (final_dir, filename) = if render(2)? == first {
            // A template that renders no frame number names every frame the
            // same; a taken name gets the next free `_001`-style suffix.
            let (dir, name) = first;
            let name = free_suffixed_name(&name, |candidate| taken(&dir, candidate));
            (dir, name)
        } else {
            render(first_free_frame_number(|n| {
                let (dir, name) = render(n)?;
                Ok(taken(&dir, &name))
            })?)?
        };
        claimed.insert(final_dir.join(&filename));
        drop(claimed);
        // Pre-create the directory so the FITS writer downstream finds it.
        // A failure here is fatal (the caller turns the Err into a hard
        // node failure).
        std::fs::create_dir_all(&final_dir).map_err(|e| {
            format!(
                "could not create save directory `{}`: {e}",
                final_dir.display()
            )
        })?;
        Ok((final_dir, filename))
    }))
}

/// Frame files named and not yet on disk, across every burst of the process.
static CLAIMED_FRAME_PATHS: std::sync::Mutex<std::collections::BTreeSet<PathBuf>> =
    std::sync::Mutex::new(std::collections::BTreeSet::new());

/// `name`, or with the first `_001`-style suffix before its extension that
/// `taken` does not hold.
fn free_suffixed_name(name: &str, taken: impl Fn(&str) -> bool) -> String {
    if !taken(name) {
        return name.to_string();
    }
    let path = std::path::Path::new(name);
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let extension = path.extension().map(|e| e.to_string_lossy().into_owned());
    (1u32..)
        .map(|suffix| match &extension {
            Some(ext) => format!("{stem}_{suffix:03}.{ext}"),
            None => format!("{stem}_{suffix:03}"),
        })
        .find(|candidate| !taken(candidate))
        .expect("u32 suffixes run out only after four billion files")
}

/// A variable's value as one path segment of a frame's save path: the same
/// rule the app's naming pattern applies (`ImagingService` `_sanitizePathComponent`,
/// both pinned by `test_fixtures/path_segment_cases.json`). A target named
/// `M31/Ha` stays one folder, and nothing renders as `..`.
pub(crate) fn path_segment(value: &str) -> String {
    let replaced: String = value
        .chars()
        .map(|c| match c {
            '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*' => '_',
            c if (c as u32) < 0x20 => '_',
            c => c,
        })
        .collect();
    let trimmed = replaced
        .trim()
        .trim_start_matches(['.', ' ', '_'])
        .trim_end_matches(['.', ' ']);
    if trimmed.is_empty() {
        "_".to_string()
    } else {
        trimmed.to_string()
    }
}

/// `name` with the extension of the format frames are saved in. A template
/// that names a frame format (`.fits`, `.xisf`, ...) or none gets the saved
/// format's, so the capture format setting decides what lands on disk; any
/// other extension the user typed is kept and the format's appended.
fn with_frame_extension(name: &str, extension: &str) -> String {
    let path = std::path::Path::new(name);
    if skotiq_imaging::is_frame_path(path) {
        path.with_extension(extension)
            .to_string_lossy()
            .into_owned()
    } else {
        format!("{name}.{extension}")
    }
}

/// Split a rendered save path into its directory and filename, resolving a
/// relative directory against the run's base save path. We accept both `/`
/// and `\` separators (a Windows user may type either); absolute templates are
/// honoured verbatim (a user explicitly typed `/mnt/captures/...`).
fn split_rendered_save_path(
    rendered: &str,
    base_path: Option<&PathBuf>,
) -> Result<(PathBuf, String), String> {
    let rendered_path = std::path::PathBuf::from(rendered);
    let Some(name) = rendered_path.file_name() else {
        return Err(format!(
            "rendered save path `{rendered}` has no filename component"
        ));
    };
    let filename = name.to_string_lossy().into_owned();
    let rel_dir = rendered_path
        .parent()
        .map(std::path::Path::to_path_buf)
        .unwrap_or_default();
    let final_dir = if rel_dir.is_absolute() {
        rel_dir
    } else if let Some(base) = base_path {
        if rel_dir.as_os_str().is_empty() {
            base.clone()
        } else {
            base.join(rel_dir)
        }
    } else {
        rel_dir
    };
    Ok((final_dir, filename))
}

/// The lowest frame number from 1 up that `taken` reports free, assuming the
/// numbers in use run from 1 without gaps (they do, written by this
/// renderer). Doubling then bisecting keeps a folder of a thousand frames to
/// about twenty probes. A gap left by a deleted file may be reused, which
/// overwrites nothing.
pub(crate) fn first_free_frame_number(
    taken: impl Fn(u32) -> Result<bool, String>,
) -> Result<u32, String> {
    if !taken(1)? {
        return Ok(1);
    }
    let mut used = 1;
    let mut free = 2;
    while taken(free)? {
        used = free;
        if free >= SAVE_PATH_FRAME_NUMBER_CEILING {
            return Ok(free.saturating_add(1));
        }
        free = free.saturating_mul(2).min(SAVE_PATH_FRAME_NUMBER_CEILING);
    }
    while free - used > 1 {
        let mid = used + (free - used) / 2;
        if taken(mid)? {
            used = mid;
        } else {
            free = mid;
        }
    }
    Ok(free)
}
