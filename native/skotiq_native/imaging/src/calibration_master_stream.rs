//! Dark and bias masters built straight from frame files, one band of rows at
//! a time.
//!
//! Peak memory is one band of every frame plus the 16-bit output, never the
//! whole stack: each band is read from disk with a seek, combined, and dropped.
//! Fifty full-size bias frames therefore fit in the same few hundred megabytes
//! as five. A FITS frame is read in place; a frame in another format (XISF, a
//! camera raw file) is decoded once into a FITS copy ([`FitsCopy`]), read the
//! same way, and removed when the build ends. Every frame's band is needed at
//! once for the rejection, so the decoded frames are either all held in
//! memory or all spilled to disk; the copies are that spill. They go into a
//! work folder beside the master ([`WorkFolder`]), on the disk the master is
//! written to: the system's temporary folder is memory on most Linux
//! desktops, and forty raw darks from a 40-megapixel body are 3 GB. The build
//! checks that the disk has room before it decodes anything.
//!
//! The combine is a winsorized sigma-clipped mean (3σ low and high), the
//! PixInsight default for calibration masters. The master is written as
//! unsigned 16-bit, the sample type of the lights it calibrates, with the
//! acquisition keys a matcher reads (`EXPTIME`, `GAIN`, `OFFSET`, binning,
//! `CCD-TEMP`, `SET-TEMP`) and the combine recorded in `HISTORY`.
//!
//! Before combining, each frame's level is measured on a sample of rows. Darks
//! taken in daylight with a filter-wheel blank can leak light; a leaking frame
//! reads brighter than the first frames of its group. Such frames are left out
//! of the master and reported.

use crate::fits::{copy_header_cards, write_fits, FitsError, FitsHeader};
use crate::fits_reader::FitsReader;
use crate::integration::{integrate_columns, Combine, IntegrationConfig, IntegrationFrame, Reject};
use crate::robust_stats::median_and_sigma_upper;
use crate::{frame_format, FitsCopy, ImageFormat};
use crate::{ImageData, PixelType};
use std::fs::File;
use std::io::BufReader;
use std::path::{Path, PathBuf};

/// Which calibration master is being built. Only the `IMAGETYP` card differs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamedMasterKind {
    Dark,
    Bias,
}

impl StreamedMasterKind {
    fn image_type(self) -> &'static str {
        match self {
            StreamedMasterKind::Dark => "Master Dark",
            StreamedMasterKind::Bias => "Master Bias",
        }
    }
}

/// When a frame counts as brighter than its group.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LightLeakConfig {
    /// A frame leaks when its level exceeds the group baseline by more than
    /// the larger of this many ADU and [`Self::min_rise_fraction`] of the
    /// baseline.
    pub min_rise_adu: f64,
    /// Relative form of [`Self::min_rise_adu`].
    pub min_rise_fraction: f64,
    /// How many of the earliest frames form the baseline (their median level).
    pub baseline_frames: usize,
}

impl Default for LightLeakConfig {
    fn default() -> Self {
        Self {
            min_rise_adu: 5.0,
            min_rise_fraction: 0.01,
            baseline_frames: 3,
        }
    }
}

/// Settings for [`build_streamed_master`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StreamedMasterConfig {
    pub kind: StreamedMasterKind,
    pub low_sigma: f64,
    pub high_sigma: f64,
    /// Upper bound on the decoded `f64` band across all frames, in bytes.
    pub band_budget_bytes: usize,
    pub leak: LightLeakConfig,
}

impl StreamedMasterConfig {
    pub fn new(kind: StreamedMasterKind) -> Self {
        Self {
            kind,
            low_sigma: 3.0,
            high_sigma: 3.0,
            band_budget_bytes: 64 * 1024 * 1024,
            leak: LightLeakConfig::default(),
        }
    }
}

/// Level of one input frame, measured on sampled rows.
#[derive(Debug, Clone, PartialEq)]
pub struct FrameLevel {
    pub path: PathBuf,
    /// Sigma-clipped mean of the sampled pixels, in ADU.
    pub level: f64,
    /// Robust standard deviation (1.4826 × MAD) of the sampled pixels.
    pub noise: f64,
}

/// What the level check concluded for a group of frames.
#[derive(Debug, Clone, PartialEq)]
pub struct LightLeakAssessment {
    /// Median level of the baseline frames.
    pub baseline: f64,
    /// Rise above the baseline that counts as a leak, in ADU.
    pub threshold: f64,
    /// Indices (into the measured frames) of frames above the threshold.
    pub leaking: Vec<usize>,
}

/// Outcome of [`build_streamed_master`].
#[derive(Debug, Clone, PartialEq)]
pub struct StreamedMasterResult {
    pub output_path: PathBuf,
    pub kind: StreamedMasterKind,
    pub width: u32,
    pub height: u32,
    /// Frames combined into the master.
    pub frame_count: usize,
    /// Frames left out because they read brighter than the group.
    pub leaking_frames: Vec<PathBuf>,
    pub frame_levels: Vec<FrameLevel>,
    pub leak: LightLeakAssessment,
    pub exposure_secs: Option<f64>,
    pub gain: Option<i64>,
    pub offset: Option<i64>,
    pub bin_x: Option<i64>,
    pub bin_y: Option<i64>,
    /// Mean `CCD-TEMP` of the combined frames.
    pub ccd_temp_mean: Option<f64>,
    pub set_temp: Option<f64>,
    /// Mean of the master, in ADU.
    pub master_mean: f64,
    /// Fraction of samples the sigma clip rejected.
    pub rejection_fraction: f64,
}

/// Rows sampled per frame for the level measurement.
const LEVEL_SAMPLE_ROWS: usize = 48;

/// Which frames rise above the group's opening frames.
///
/// A regulated sensor holds its dark level to well under an ADU through a
/// group, so a rise of a few ADU over the opening frames is light, not noise.
pub fn assess_light_leak(levels: &[f64], config: &LightLeakConfig) -> LightLeakAssessment {
    if levels.is_empty() {
        return LightLeakAssessment {
            baseline: 0.0,
            threshold: 0.0,
            leaking: Vec::new(),
        };
    }
    let take = config.baseline_frames.clamp(1, levels.len());
    let mut opening: Vec<f64> = levels[..take].to_vec();
    opening.sort_by(f64::total_cmp);
    let baseline = opening[opening.len() / 2];
    let threshold = config
        .min_rise_adu
        .max(config.min_rise_fraction * baseline.abs());
    let leaking = levels
        .iter()
        .enumerate()
        .filter(|(_, &level)| level - baseline > threshold)
        .map(|(i, _)| i)
        .collect();
    LightLeakAssessment {
        baseline,
        threshold,
        leaking,
    }
}

/// One input frame, opened for band reads.
struct BandSource {
    path: PathBuf,
    reader: FitsReader<BufReader<File>>,
    width: u32,
    height: u32,
    scratch: Vec<u8>,
    /// The FITS copy the reader reads when the frame is in another format.
    /// Declared after `reader` so the file is closed before it is removed.
    _copy: Option<FitsCopy>,
}

impl BandSource {
    /// `work` is where a frame that is not FITS is decoded to.
    fn open(path: &Path, work: &WorkFolder) -> Result<Self, String> {
        let describe = |e: FitsError| format!("{}: {e}", path.display());
        let copy = match frame_format(path).map_err(|e| format!("{}: {e}", path.display()))? {
            ImageFormat::Fits => None,
            _ => Some(
                FitsCopy::new_in(path, work.path()?)
                    .map_err(|e| format!("{}: {e}", path.display()))?,
            ),
        };
        let fits = copy.as_ref().map_or(path, FitsCopy::path);
        let file = File::open(fits).map_err(|e| format!("{}: {e}", path.display()))?;
        let reader = FitsReader::open(BufReader::new(file)).map_err(describe)?;
        let header = reader.header();
        let naxis = header.get_int("NAXIS").unwrap_or(0);
        if naxis != 2 && !(naxis == 3 && header.get_int("NAXIS3") == Some(1)) {
            return Err(format!(
                "{}: a calibration frame must be a single 2-D plane (NAXIS={naxis})",
                path.display()
            ));
        }
        let (width, height) = reader
            .shape()
            .map(|shape| (shape.width, shape.height))
            .filter(|(w, h)| *w > 0 && *h > 0)
            .ok_or_else(|| format!("{}: empty image", path.display()))?;
        Ok(Self {
            path: path.to_path_buf(),
            reader,
            width,
            height,
            scratch: Vec::new(),
            _copy: copy,
        })
    }

    fn header(&self) -> &FitsHeader {
        self.reader.header()
    }

    /// Decode rows `row..row + rows` into `out` as physical `f64` values.
    fn read_rows(&mut self, row: usize, rows: usize, out: &mut Vec<f64>) -> Result<(), String> {
        self.reader
            .read_rows(row, rows, &mut self.scratch, out)
            .map_err(|e| {
                format!(
                    "{}: reading rows {row}..{}: {e}",
                    self.path.display(),
                    row + rows
                )
            })
    }
}

/// The folder a build decodes its non-FITS frames into: a hidden sibling of
/// the master, made when the first copy needs it and removed with everything
/// in it when the build ends, however it ends.
struct WorkFolder {
    path: PathBuf,
    made: std::cell::Cell<bool>,
}

const WORK_FOLDER_PREFIX: &str = ".skotiq-master-work-";

impl WorkFolder {
    /// The work folder of the build that writes `output`. Folders an earlier
    /// run of the app left beside it (a crash, a power cut) are removed: the
    /// calibration library has one writer, so a folder with another process
    /// id in its name belongs to no build.
    fn beside(output: &Path) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let parent = output.parent().unwrap_or(Path::new(""));
        let mine = format!("{WORK_FOLDER_PREFIX}{}-", std::process::id());
        if let Ok(entries) = std::fs::read_dir(if parent.as_os_str().is_empty() {
            Path::new(".")
        } else {
            parent
        }) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.starts_with(WORK_FOLDER_PREFIX) && !name.starts_with(&mine) {
                    let _ = std::fs::remove_dir_all(entry.path());
                }
            }
        }
        Self {
            path: parent.join(format!(
                "{mine}{}",
                NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            )),
            made: std::cell::Cell::new(false),
        }
    }

    fn path(&self) -> Result<&Path, String> {
        if !self.made.get() {
            std::fs::create_dir_all(&self.path)
                .map_err(|e| format!("creating {}: {e}", self.path.display()))?;
            self.made.set(true);
        }
        Ok(&self.path)
    }
}

impl Drop for WorkFolder {
    fn drop(&mut self) {
        if self.made.get() {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }
}

/// Bytes the FITS copies of the frames in `paths` that are not FITS will
/// take, from each frame's header: no frame is decoded to find out. A frame
/// whose header does not give its size counts as three times its file.
fn working_copy_bytes(paths: &[PathBuf]) -> u64 {
    paths
        .iter()
        .filter(|path| !matches!(frame_format(path), Ok(ImageFormat::Fits)))
        .map(|path| {
            let from_header = crate::read_frame_header(path).ok().and_then(|header| {
                let axis = |key: &str| header.get_int(key).filter(|n| *n > 0).map(|n| n as u64);
                let samples = axis("NAXIS1")? * axis("NAXIS2")? * axis("NAXIS3").unwrap_or(1);
                let bytes = header.get_int("BITPIX").map_or(2, |b| b.unsigned_abs() / 8);
                Some(samples * bytes.max(2))
            });
            from_header.unwrap_or_else(|| std::fs::metadata(path).map_or(0, |file| file.len() * 3))
        })
        .sum()
}

/// Free bytes on the disk that holds `folder`; `None` when the system will
/// not say.
fn free_bytes(folder: &Path) -> Option<u64> {
    fs2::available_space(folder).ok()
}

fn gigabytes(bytes: u64) -> String {
    format!("{:.1} GB", bytes as f64 / 1e9)
}

/// Sigma-clipped mean and robust σ of `values` (reordered in place).
fn clipped_level(values: &mut [f64]) -> (f64, f64) {
    let (median, sigma) = median_and_sigma_upper(values);
    let bound = 3.0 * sigma.max(f64::EPSILON);
    let (sum, count) = values
        .iter()
        .filter(|v| (*v - median).abs() <= bound)
        .fold((0.0, 0usize), |(s, n), v| (s + v, n + 1));
    let level = if count > 0 {
        sum / count as f64
    } else {
        median
    };
    (level, sigma)
}

fn measure_level(source: &mut BandSource) -> Result<FrameLevel, String> {
    let height = source.height as usize;
    let rows = LEVEL_SAMPLE_ROWS.min(height);
    let mut samples: Vec<f64> = Vec::with_capacity(rows * source.width as usize);
    let mut row_values = Vec::new();
    for i in 0..rows {
        // Evenly spaced rows, avoiding the very first and last (amp glow edges
        // are part of the dark, but a leak is a field-wide rise).
        let row = ((2 * i + 1) * height) / (2 * rows);
        source.read_rows(row, 1, &mut row_values)?;
        samples.extend(row_values.iter().copied().filter(|v| v.is_finite()));
    }
    let (level, noise) = clipped_level(&mut samples);
    Ok(FrameLevel {
        path: source.path.clone(),
        level,
        noise,
    })
}

fn card_f64(header: &FitsHeader, keys: &[&str]) -> Option<f64> {
    keys.iter().find_map(|k| header.get_float(k))
}

fn card_i64(header: &FitsHeader, keys: &[&str]) -> Option<i64> {
    keys.iter().find_map(|k| {
        header
            .get_int(k)
            .or_else(|| header.get_float(k).map(|f| f.round() as i64))
    })
}

/// Every source must agree with the first on a card, when both carry it: size,
/// exposure, set-point, read mode, gain, offset and binning.
fn check_agreement(sources: &[BandSource]) -> Result<(), String> {
    let first = &sources[0];
    for source in &sources[1..] {
        if source.width != first.width || source.height != first.height {
            return Err(format!(
                "{} is {}x{} but {} is {}x{}",
                source.path.display(),
                source.width,
                source.height,
                first.path.display(),
                first.width,
                first.height
            ));
        }
        let exposure = |h: &FitsHeader| card_f64(h, &["EXPTIME", "EXPOSURE"]);
        if let (Some(a), Some(b)) = (exposure(first.header()), exposure(source.header())) {
            if (a - b).abs() > 1e-3_f64.max(a.abs() * 1e-4) {
                return Err(format!(
                    "{} was exposed {b} s but {} was exposed {a} s",
                    source.path.display(),
                    first.path.display()
                ));
            }
        }
        let set_point = |h: &FitsHeader| card_f64(h, &["SET-TEMP", "SET_TEMP"]);
        if let (Some(a), Some(b)) = (set_point(first.header()), set_point(source.header())) {
            if (a - b).abs() > 0.05 {
                return Err(format!(
                    "{} was taken at a {b} °C set-point but {} at {a} °C",
                    source.path.display(),
                    first.path.display()
                ));
            }
        }
        let mode = |h: &FitsHeader| h.get_string("READOUTM").map(str::to_string);
        if let (Some(a), Some(b)) = (mode(first.header()), mode(source.header())) {
            if a != b {
                return Err(format!(
                    "{} was read out in mode {b} but {} in mode {a}",
                    source.path.display(),
                    first.path.display()
                ));
            }
        }
        for key in ["GAIN", "OFFSET", "XBINNING", "YBINNING"] {
            if let (Some(a), Some(b)) = (
                card_i64(first.header(), &[key]),
                card_i64(source.header(), &[key]),
            ) {
                if a != b {
                    return Err(format!(
                        "{} has {key}={b} but {} has {key}={a}",
                        source.path.display(),
                        first.path.display()
                    ));
                }
            }
        }
    }
    Ok(())
}

/// Why no master was built.
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum MasterBuildError {
    /// The frames cannot make one master: too few, unreadable, not a single
    /// plane, disagreeing on how they were taken, or leaking light. Nothing
    /// was written; other frames would do.
    #[error("{0}")]
    Refused(String),
    /// The master could not be combined or written.
    #[error("{0}")]
    Failed(String),
}

/// Build a dark or bias master from `paths` and write it to `output`.
///
/// Fails without writing anything when the frames disagree on size, exposure,
/// set-point, gain, offset, binning or read mode, when more than half of them leak, or when fewer
/// than two frames are left after the leaking ones are dropped.
pub fn build_streamed_master(
    paths: &[PathBuf],
    output: &Path,
    config: &StreamedMasterConfig,
) -> Result<StreamedMasterResult, MasterBuildError> {
    build_with_free_space(paths, output, config, free_bytes)
}

fn build_with_free_space(
    paths: &[PathBuf],
    output: &Path,
    config: &StreamedMasterConfig,
    free_bytes: impl Fn(&Path) -> Option<u64>,
) -> Result<StreamedMasterResult, MasterBuildError> {
    use MasterBuildError::{Failed, Refused};
    if paths.len() < 2 {
        return Err(Refused(format!(
            "a master needs at least 2 frames; {} given",
            paths.len()
        )));
    }
    let output_dir = output.parent().unwrap_or(Path::new(""));
    if !output_dir.as_os_str().is_empty() {
        std::fs::create_dir_all(output_dir)
            .map_err(|e| Failed(format!("creating {}: {e}", output_dir.display())))?;
    }
    let space_folder = if output_dir.as_os_str().is_empty() {
        Path::new(".")
    } else {
        output_dir
    };
    let needed = working_copy_bytes(paths);
    if let Some(free) = free_bytes(space_folder).filter(|free| needed > 0 && *free < needed) {
        return Err(Failed(format!(
            "Building this master needs about {} of working space in {} to decode {} frames \
             that are not FITS, and {} is free. Free some space there and build again.",
            gigabytes(needed),
            space_folder.display(),
            paths
                .iter()
                .filter(|path| !matches!(frame_format(path), Ok(ImageFormat::Fits)))
                .count(),
            gigabytes(free)
        )));
    }
    // Declared before the sources so it is dropped after them: a copy's file
    // is closed and removed before its folder is.
    let work = WorkFolder::beside(output);
    let mut sources: Vec<BandSource> = paths
        .iter()
        .map(|p| BandSource::open(p, &work))
        .collect::<Result<_, _>>()
        .map_err(Refused)?;
    check_agreement(&sources).map_err(Refused)?;

    let frame_levels: Vec<FrameLevel> = sources
        .iter_mut()
        .map(measure_level)
        .collect::<Result<_, _>>()
        .map_err(Refused)?;
    let levels: Vec<f64> = frame_levels.iter().map(|l| l.level).collect();
    let leak = assess_light_leak(&levels, &config.leak);
    let leaking_frames: Vec<PathBuf> = leak
        .leaking
        .iter()
        .map(|&i| frame_levels[i].path.clone())
        .collect();
    let mut kept: Vec<BandSource> = sources
        .into_iter()
        .enumerate()
        .filter(|(i, _)| !leak.leaking.contains(i))
        .map(|(_, s)| s)
        .collect();
    // When most of the group brightened, the opening frames are suspect too:
    // the light was already climbing when the baseline was taken.
    if kept.len() < 2 || leaking_frames.len() * 2 > paths.len() {
        return Err(Refused(format!(
            "light leak: {} of {} frames read more than {:.1} ADU above the first frames \
             ({:.1} ADU); no master was written",
            leaking_frames.len(),
            paths.len(),
            leak.threshold,
            leak.baseline
        )));
    }

    let width = kept[0].width as usize;
    let height = kept[0].height as usize;
    let band_rows = (config.band_budget_bytes / (kept.len() * width * 8)).clamp(1, height);
    let integration = IntegrationConfig {
        combine: Combine::Mean,
        reject: Reject::WinsorizedSigmaClip {
            low: config.low_sigma,
            high: config.high_sigma,
        },
        output_type: PixelType::F32,
        generate_rejection_map: false,
        generate_weight_map: false,
        min_coverage: 1,
    };

    let mut master: Vec<u16> = Vec::with_capacity(width * height);
    let mut bands: Vec<Vec<f64>> = vec![Vec::new(); kept.len()];
    let (mut sum, mut considered, mut rejected) = (0.0f64, 0u64, 0u64);
    let mut row = 0usize;
    while row < height {
        let rows = band_rows.min(height - row);
        for (band, source) in bands.iter_mut().zip(kept.iter_mut()) {
            source.read_rows(row, rows, band).map_err(Refused)?;
        }
        let frames: Vec<IntegrationFrame<'_>> = bands
            .iter()
            .map(|pixels| IntegrationFrame {
                pixels,
                weight: 1.0,
                coverage: None,
            })
            .collect();
        let columns = integrate_columns(
            &frames,
            width as u32,
            rows as u32,
            1,
            &integration,
            Reject::MAX_ITERATIONS,
        )
        .map_err(|e| Failed(format!("combining rows {row}..{}: {e}", row + rows)))?;
        considered += columns.stats.total_samples;
        rejected += columns.stats.total_rejected;
        for &v in &columns.master {
            sum += v;
            master.push(if v.is_finite() {
                v.round().clamp(0.0, 65535.0) as u16
            } else {
                0
            });
        }
        row += rows;
    }

    let first = kept[0].header();
    let temps: Vec<f64> = kept
        .iter()
        .filter_map(|s| card_f64(s.header(), &["CCD-TEMP", "CCD_TEMP"]))
        .collect();
    let ccd_temp_mean = (!temps.is_empty()).then(|| temps.iter().sum::<f64>() / temps.len() as f64);
    let exposure_secs = card_f64(first, &["EXPTIME", "EXPOSURE"]);
    let gain = card_i64(first, &["GAIN"]);
    let offset = card_i64(first, &["OFFSET"]);
    let bin_x = card_i64(first, &["XBINNING"]);
    let bin_y = card_i64(first, &["YBINNING"]);
    let set_temp = card_f64(first, &["SET-TEMP", "SET_TEMP"]);
    let master_mean = sum / (width * height) as f64;
    let rejection_fraction = if considered > 0 {
        rejected as f64 / considered as f64
    } else {
        0.0
    };

    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", config.kind.image_type());
    if let Some(v) = exposure_secs {
        header.set_float("EXPTIME", v);
        header.set_float("EXPOSURE", v);
    }
    if let Some(v) = gain {
        header.set_int("GAIN", v);
    }
    if let Some(v) = offset {
        header.set_int("OFFSET", v);
    }
    if let Some(v) = bin_x {
        header.set_int("XBINNING", v);
    }
    if let Some(v) = bin_y {
        header.set_int("YBINNING", v);
    }
    if let Some(v) = ccd_temp_mean {
        header.set_float("CCD-TEMP", (v * 100.0).round() / 100.0);
    }
    // The coldest and warmest frame, so the library can tell a master whose
    // frames were not all at its set-point from one whose mean merely is.
    let extreme = |pick: fn(f64, f64) -> f64| temps.iter().copied().reduce(pick);
    if let (Some(coldest), Some(warmest)) = (extreme(f64::min), extreme(f64::max)) {
        header.set_float("CCDTMIN", (coldest * 100.0).round() / 100.0);
        header.set_float("CCDTMAX", (warmest * 100.0).round() / 100.0);
    }
    if let Some(v) = set_temp {
        header.set_float("SET-TEMP", v);
    }
    copy_header_cards(&mut header, first, |key| {
        matches!(
            key,
            "INSTRUME" | "XPIXSZ" | "YPIXSZ" | "READOUTM" | "BAYERPAT" | "XBAYROFF" | "YBAYROFF"
        )
    });
    header.set_int("NCOMBINE", kept.len() as i64);
    header.add_history(&format!(
        "Winsorized sigma-clipped mean, low {:.1} sigma, high {:.1} sigma, {} frames",
        config.low_sigma,
        config.high_sigma,
        kept.len()
    ));
    header.add_history(&format!(
        "Rejected {:.3}% of samples",
        rejection_fraction * 100.0
    ));
    if !leaking_frames.is_empty() {
        header.add_history(&format!(
            "Left out {} frames reading above {:.1} ADU over the first frames",
            leaking_frames.len(),
            leak.threshold
        ));
    }

    let image = ImageData::from_u16(width as u32, height as u32, 1, &master);
    drop(master);
    let partial = output.with_extension("partial.fits");
    write_fits(&partial, &image, &header)
        .map_err(|e| Failed(format!("writing {}: {e}", partial.display())))?;
    std::fs::rename(&partial, output)
        .map_err(|e| Failed(format!("moving master into {}: {e}", output.display())))?;

    Ok(StreamedMasterResult {
        output_path: output.to_path_buf(),
        kind: config.kind,
        width: width as u32,
        height: height as u32,
        frame_count: kept.len(),
        leaking_frames,
        frame_levels,
        leak,
        exposure_secs,
        gain,
        offset,
        bin_x,
        bin_y,
        ccd_temp_mean,
        set_temp,
        master_mean,
        rejection_fraction,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fits::read_fits;

    struct TempDir(PathBuf);

    impl TempDir {
        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn tempdir() -> TempDir {
        use std::sync::atomic::{AtomicU32, Ordering};
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "skotiq-stream-master-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }

    fn write_frame(
        dir: &Path,
        name: &str,
        pixels: &[u16],
        w: u32,
        h: u32,
        cards: &[(&str, f64)],
    ) -> PathBuf {
        let mut header = FitsHeader::new();
        for (k, v) in cards {
            if v.fract() == 0.0 && *k != "EXPTIME" && *k != "CCD-TEMP" {
                header.set_int(k, *v as i64);
            } else {
                header.set_float(k, *v);
            }
        }
        let path = dir.join(name);
        crate::write_frame(&path, &ImageData::from_u16(w, h, 1, pixels), &header).unwrap();
        path
    }

    fn noisy(seed: u64, w: u32, h: u32, level: f64) -> Vec<u16> {
        let mut state = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (0..(w * h))
            .map(|_| {
                state = state
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                let u = (state >> 33) as f64 / (1u64 << 31) as f64;
                (level + (u - 0.5) * 8.0).round() as u16
            })
            .collect()
    }

    const CARDS: &[(&str, f64)] = &[
        ("EXPTIME", 90.0),
        ("GAIN", 76.0),
        ("OFFSET", 15.0),
        ("XBINNING", 1.0),
        ("YBINNING", 1.0),
        ("CCD-TEMP", -10.0),
        ("SET-TEMP", -10.0),
    ];

    #[test]
    fn master_is_u16_with_matching_keys_and_rejects_a_cosmic_ray() {
        let dir = tempdir();
        let (w, h) = (37, 23);
        let mut paths = Vec::new();
        for i in 0..9 {
            let mut px = noisy(i, w, h, 300.0);
            if i == 4 {
                px[5 * w as usize + 7] = 60000;
            }
            paths.push(write_frame(
                dir.path(),
                &format!("d{i}.fits"),
                &px,
                w,
                h,
                CARDS,
            ));
        }
        let out = dir.path().join("master.fits");
        let mut config = StreamedMasterConfig::new(StreamedMasterKind::Dark);
        // Force many bands, including a short last one.
        config.band_budget_bytes = 9 * w as usize * 8 * 4;
        let result = build_streamed_master(&paths, &out, &config).unwrap();
        assert_eq!(result.frame_count, 9);
        assert!(result.leaking_frames.is_empty());
        let (image, header) = read_fits(&out).unwrap();
        assert_eq!(image.pixel_type, PixelType::U16);
        assert_eq!((image.width, image.height), (w, h));
        let px = image.as_u16().unwrap();
        assert!(
            (px[5 * w as usize + 7] as i32 - 300).abs() <= 3,
            "cosmic ray survived: {}",
            px[5 * w as usize + 7]
        );
        assert_eq!(header.get_string("IMAGETYP"), Some("Master Dark"));
        assert_eq!(header.get_float("EXPTIME"), Some(90.0));
        assert_eq!(header.get_int("GAIN"), Some(76));
        assert_eq!(header.get_int("OFFSET"), Some(15));
        assert_eq!(header.get_int("XBINNING"), Some(1));
        assert_eq!(header.get_float("CCD-TEMP"), Some(-10.0));
        assert_eq!(header.get_float("SET-TEMP"), Some(-10.0));
        assert_eq!(header.get_int("NCOMBINE"), Some(9));
        assert!(header.history.iter().any(|h| h.contains("Winsorized")));
        assert!(!dir.path().join("master.partial.fits").exists());
    }

    /// XISF darks build the same master as FITS darks of the same pixels, a
    /// group may mix the two, and the FITS copies the band reader used are
    /// gone afterwards, also when the build is refused.
    #[test]
    fn frames_in_any_format_build_the_same_master() {
        let dir = tempdir();
        let (w, h) = (19, 13);
        let frames: Vec<Vec<u16>> = (0..5).map(|i| noisy(i + 40, w, h, 400.0)).collect();
        let named = |ext: &dyn Fn(usize) -> &'static str| -> Vec<PathBuf> {
            frames
                .iter()
                .enumerate()
                .map(|(i, px)| {
                    write_frame(dir.path(), &format!("f{i}.{}", ext(i)), px, w, h, CARDS)
                })
                .collect()
        };
        let fits = named(&|_| "fits");
        let xisf = named(&|_| "xisf");
        let mixed = named(&|i| if i % 2 == 0 { "xisf" } else { "fits" });
        let config = StreamedMasterConfig::new(StreamedMasterKind::Dark);
        let master = |paths: &[PathBuf], name: &str| {
            let out = dir.path().join("Masters").join(name);
            let result = build_streamed_master(paths, &out, &config).unwrap();
            assert_eq!(result.gain, Some(76), "{name}");
            read_fits(&out).unwrap().0.data
        };
        let from_fits = master(&fits, "fits.fits");
        assert_eq!(master(&xisf, "xisf.fits"), from_fits);
        assert_eq!(master(&mixed, "mixed.fits"), from_fits);

        let mut wrong = xisf.clone();
        wrong.push(write_frame(
            dir.path(),
            "long.xisf",
            &frames[0],
            w,
            h,
            &[("EXPTIME", 300.0)],
        ));
        let refused = build_streamed_master(&wrong, &dir.path().join("Masters/no.fits"), &config);
        assert!(matches!(refused, Err(MasterBuildError::Refused(m)) if m.contains("exposed")));

        let left: Vec<_> = std::fs::read_dir(dir.path().join("Masters"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with('.'))
            .collect();
        assert!(left.is_empty(), "{left:?}");
    }

    fn hidden_entries(folder: &Path) -> Vec<String> {
        std::fs::read_dir(folder)
            .map(|entries| {
                entries
                    .flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .filter(|n| n.starts_with('.'))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The system's temporary folder is memory on most Linux desktops, so
    /// the decoded copies of a raw or XISF group must never be written
    /// there: they go beside the master while the build runs.
    #[test]
    fn decoded_copies_are_spilled_beside_the_master_not_into_the_system_temp_folder() {
        let dir = tempdir();
        let (w, h) = (1200, 900);
        let paths: Vec<PathBuf> = (0..6)
            .map(|i| {
                write_frame(
                    dir.path(),
                    &format!("s{i}.xisf"),
                    &noisy(i + 70, w, h, 400.0),
                    w,
                    h,
                    CARDS,
                )
            })
            .collect();
        let masters = dir.path().join("Masters");
        std::fs::create_dir_all(&masters).unwrap();
        let in_temp = format!(".skotiq-fits-copy-{}-", std::process::id());
        let done = std::sync::atomic::AtomicBool::new(false);
        let (seen_in_temp, seen_beside_master) = std::thread::scope(|scope| {
            let watcher = scope.spawn(|| {
                let (mut in_system_temp, mut beside_master) = (false, false);
                while !done.load(std::sync::atomic::Ordering::Relaxed) {
                    in_system_temp |= std::fs::read_dir(std::env::temp_dir())
                        .map(|entries| {
                            entries
                                .flatten()
                                .any(|e| e.file_name().to_string_lossy().starts_with(&in_temp))
                        })
                        .unwrap_or(false);
                    beside_master |= hidden_entries(&masters)
                        .iter()
                        .any(|n| n.starts_with(WORK_FOLDER_PREFIX));
                    std::thread::sleep(std::time::Duration::from_micros(200));
                }
                (in_system_temp, beside_master)
            });
            let config = StreamedMasterConfig::new(StreamedMasterKind::Dark);
            build_streamed_master(&paths, &masters.join("m.fits"), &config).unwrap();
            done.store(true, std::sync::atomic::Ordering::Relaxed);
            watcher.join().unwrap()
        });
        assert!(
            !seen_in_temp,
            "a decoded copy was written to the system temp folder"
        );
        assert!(
            seen_beside_master,
            "no work folder was seen beside the master"
        );
        assert!(hidden_entries(&masters).is_empty());
    }

    #[test]
    fn a_build_without_room_for_the_decoded_copies_says_so_and_decodes_nothing() {
        let dir = tempdir();
        let (w, h) = (40, 30);
        let frame = |name: &str, seed: u64| {
            write_frame(dir.path(), name, &noisy(seed, w, h, 300.0), w, h, CARDS)
        };
        let xisf: Vec<PathBuf> = (0..3).map(|i| frame(&format!("x{i}.xisf"), i)).collect();
        let fits: Vec<PathBuf> = (0..3).map(|i| frame(&format!("x{i}.fits"), i)).collect();
        let masters = dir.path().join("Masters");
        let config = StreamedMasterConfig::new(StreamedMasterKind::Dark);
        assert_eq!(working_copy_bytes(&xisf), 3 * 40 * 30 * 2);
        assert_eq!(working_copy_bytes(&fits), 0);

        let no_room =
            build_with_free_space(&xisf, &masters.join("no.fits"), &config, |_| Some(7000));
        assert!(
            matches!(&no_room, Err(MasterBuildError::Failed(m)) if m.contains("working space")),
            "{no_room:?}"
        );
        assert!(!masters.join("no.fits").exists());
        assert!(hidden_entries(&masters).is_empty());

        // FITS frames are read in place and need no working space.
        build_with_free_space(&fits, &masters.join("fits.fits"), &config, |_| Some(0)).unwrap();
        // A system that will not say how much is free does not stop a build.
        build_with_free_space(&xisf, &masters.join("xisf.fits"), &config, |_| None).unwrap();
    }

    #[test]
    fn a_work_folder_an_earlier_run_left_behind_is_removed_by_the_next_build() {
        let dir = tempdir();
        let (w, h) = (16, 11);
        let paths: Vec<PathBuf> = (0..3)
            .map(|i| {
                write_frame(
                    dir.path(),
                    &format!("w{i}.xisf"),
                    &noisy(i, w, h, 300.0),
                    w,
                    h,
                    CARDS,
                )
            })
            .collect();
        let masters = dir.path().join("Masters");
        let stale = masters.join(format!("{WORK_FOLDER_PREFIX}1-0"));
        std::fs::create_dir_all(&stale).unwrap();
        std::fs::write(stale.join(".skotiq-fits-copy-1-0.fits"), b"left by a crash").unwrap();

        let config = StreamedMasterConfig::new(StreamedMasterKind::Dark);
        build_streamed_master(&paths, &masters.join("m.fits"), &config).unwrap();
        assert!(hidden_entries(&masters).is_empty());
    }

    #[test]
    fn banded_result_equals_single_band_result() {
        let dir = tempdir();
        let (w, h) = (16, 11);
        let paths: Vec<PathBuf> = (0..5)
            .map(|i| {
                write_frame(
                    dir.path(),
                    &format!("b{i}.fits"),
                    &noisy(i + 20, w, h, 500.0),
                    w,
                    h,
                    CARDS,
                )
            })
            .collect();
        let mut one = StreamedMasterConfig::new(StreamedMasterKind::Bias);
        one.band_budget_bytes = usize::MAX / 2;
        let mut many = one;
        many.band_budget_bytes = 1;
        build_streamed_master(&paths, &dir.path().join("one.fits"), &one).unwrap();
        build_streamed_master(&paths, &dir.path().join("many.fits"), &many).unwrap();
        let a = read_fits(&dir.path().join("one.fits")).unwrap().0;
        let b = read_fits(&dir.path().join("many.fits")).unwrap().0;
        assert_eq!(a.data, b.data);
    }

    #[test]
    fn frames_that_brighten_are_left_out_and_reported() {
        let dir = tempdir();
        let (w, h) = (20, 60);
        let mut paths = Vec::new();
        for i in 0..8u64 {
            let level = if i >= 6 {
                300.0 + 40.0 * (i - 5) as f64
            } else {
                300.0
            };
            paths.push(write_frame(
                dir.path(),
                &format!("d{i}.fits"),
                &noisy(i, w, h, level),
                w,
                h,
                CARDS,
            ));
        }
        let out = dir.path().join("m.fits");
        let result = build_streamed_master(
            &paths,
            &out,
            &StreamedMasterConfig::new(StreamedMasterKind::Dark),
        )
        .unwrap();
        assert_eq!(result.frame_count, 6);
        assert_eq!(
            result.leaking_frames,
            vec![paths[6].clone(), paths[7].clone()]
        );
        assert!((result.master_mean - 300.0).abs() < 2.0);
    }

    #[test]
    fn a_group_that_leaks_from_the_start_of_its_rise_writes_no_master() {
        let dir = tempdir();
        let (w, h) = (10, 10);
        let mut paths = Vec::new();
        for i in 0..6u64 {
            let level = 300.0 + 50.0 * i as f64;
            paths.push(write_frame(
                dir.path(),
                &format!("d{i}.fits"),
                &noisy(i, w, h, level),
                w,
                h,
                CARDS,
            ));
        }
        let out = dir.path().join("m.fits");
        let err = build_streamed_master(
            &paths,
            &out,
            &StreamedMasterConfig::new(StreamedMasterKind::Dark),
        )
        .unwrap_err();
        assert!(
            matches!(&err, MasterBuildError::Refused(m) if m.contains("light leak")),
            "{err}"
        );
        assert!(!out.exists());
    }

    #[test]
    fn mismatched_exposures_are_refused() {
        let dir = tempdir();
        let a = write_frame(dir.path(), "a.fits", &noisy(1, 4, 4, 300.0), 4, 4, CARDS);
        let mut other = CARDS.to_vec();
        other[0] = ("EXPTIME", 120.0);
        let b = write_frame(dir.path(), "b.fits", &noisy(2, 4, 4, 300.0), 4, 4, &other);
        let err = build_streamed_master(
            &[a, b],
            &dir.path().join("m.fits"),
            &StreamedMasterConfig::new(StreamedMasterKind::Dark),
        )
        .unwrap_err();
        assert!(
            matches!(&err, MasterBuildError::Refused(m) if m.contains("exposed")),
            "{err}"
        );
    }

    /// A QHY camera's darks taken in two read modes differ in read noise and
    /// pedestal; one master of both calibrates neither.
    #[test]
    fn mixed_read_modes_are_refused_and_one_mode_is_carried() {
        let dir = tempdir();
        let in_mode = |name: &str, seed: u64, mode: &str| {
            let path = write_frame(dir.path(), name, &noisy(seed, 4, 4, 300.0), 4, 4, CARDS);
            crate::rewrite_frame_header(&path, |h| h.set_string("READOUTM", mode)).unwrap();
            path
        };
        let config = StreamedMasterConfig::new(StreamedMasterKind::Dark);
        let photographic = in_mode("a.fits", 1, "Photographic DSO 16BIT");
        let high_gain = in_mode("b.fits", 2, "High Gain Mode 16BIT");
        let err = build_streamed_master(
            &[photographic.clone(), high_gain],
            &dir.path().join("m.fits"),
            &config,
        )
        .unwrap_err();
        assert!(
            matches!(&err, MasterBuildError::Refused(m) if m.contains("read out in mode")),
            "{err}"
        );

        let same = in_mode("c.fits", 3, "Photographic DSO 16BIT");
        let out = dir.path().join("one.fits");
        build_streamed_master(&[photographic, same], &out, &config).unwrap();
        let (_, header) = crate::read_frame(&out).unwrap();
        assert_eq!(
            header.get_string("READOUTM"),
            Some("Photographic DSO 16BIT")
        );
    }

    /// Darks of two cooler set-points stand for neither temperature.
    #[test]
    fn mixed_set_points_are_refused_and_the_extremes_are_carried() {
        let dir = tempdir();
        let config = StreamedMasterConfig::new(StreamedMasterKind::Dark);
        let at = |name: &str, seed: u64, set_point: f64, sensor: f64| {
            let path = write_frame(dir.path(), name, &noisy(seed, 4, 4, 300.0), 4, 4, CARDS);
            crate::rewrite_frame_header(&path, |h| {
                h.set_float("SET-TEMP", set_point);
                h.set_float("CCD-TEMP", sensor);
            })
            .unwrap();
            path
        };
        let minus_six = at("a.fits", 1, -6.0, -6.2);
        let minus_four = at("b.fits", 2, -4.0, -5.0);
        let err = build_streamed_master(
            &[minus_six.clone(), minus_four],
            &dir.path().join("m.fits"),
            &config,
        )
        .unwrap_err();
        assert!(
            matches!(&err, MasterBuildError::Refused(m) if m.contains("set-point")),
            "{err}"
        );

        let also_minus_six = at("c.fits", 3, -6.0, -5.0);
        let out = dir.path().join("one.fits");
        build_streamed_master(&[minus_six, also_minus_six], &out, &config).unwrap();
        let (_, header) = crate::read_frame(&out).unwrap();
        assert_eq!(header.get_float("CCDTMIN"), Some(-6.2));
        assert_eq!(header.get_float("CCDTMAX"), Some(-5.0));
        assert_eq!(header.get_float("SET-TEMP"), Some(-6.0));
    }

    #[test]
    fn leak_threshold_uses_the_larger_of_absolute_and_relative_rise() {
        let config = LightLeakConfig::default();
        let flat = assess_light_leak(&[300.0, 301.0, 299.0, 304.0], &config);
        assert!(flat.leaking.is_empty());
        let bright = assess_light_leak(&[2000.0, 2001.0, 1999.0, 2015.0, 2025.0], &config);
        assert_eq!(bright.threshold, 20.0);
        assert_eq!(bright.leaking, vec![4]);
    }
}
