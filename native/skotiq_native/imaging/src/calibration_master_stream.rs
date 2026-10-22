//! Dark and bias masters built straight from FITS files, one band of rows at a
//! time.
//!
//! Peak memory is one band of every frame plus the 16-bit output, never the
//! whole stack: each band is read from disk with a seek, combined, and dropped.
//! Fifty full-size bias frames therefore fit in the same few hundred megabytes
//! as five.
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

use crate::fits::{copy_header_cards, read_header, write_fits, FitsError, FitsHeader};
use crate::integration::{integrate_columns, Combine, IntegrationConfig, IntegrationFrame, Reject};
use crate::{ImageData, PixelType};
use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
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

/// One input FITS file, opened for band reads.
struct BandSource {
    path: PathBuf,
    reader: BufReader<File>,
    header: FitsHeader,
    data_offset: u64,
    bitpix: i64,
    bzero: f64,
    bscale: f64,
    width: u32,
    height: u32,
    scratch: Vec<u8>,
}

struct CountingReader<R> {
    inner: R,
    count: u64,
}

impl<R: Read> Read for CountingReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.count += n as u64;
        Ok(n)
    }
}

impl BandSource {
    fn open(path: &Path) -> Result<Self, String> {
        let describe = |e: FitsError| format!("{}: {e}", path.display());
        let file = File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
        let mut counting = CountingReader {
            inner: BufReader::new(file),
            count: 0,
        };
        let header = read_header(&mut counting).map_err(describe)?;
        // The data unit starts at the first 2880-byte block after END.
        let data_offset = counting.count.div_ceil(2880) * 2880;
        let reader = counting.inner;
        let bitpix = header
            .get_int("BITPIX")
            .ok_or_else(|| format!("{}: no BITPIX", path.display()))?;
        if !matches!(bitpix, 8 | 16 | 32 | -32 | -64) {
            return Err(format!("{}: unsupported BITPIX {bitpix}", path.display()));
        }
        let naxis = header.get_int("NAXIS").unwrap_or(0);
        if naxis != 2 && !(naxis == 3 && header.get_int("NAXIS3") == Some(1)) {
            return Err(format!(
                "{}: a calibration frame must be a single 2-D plane (NAXIS={naxis})",
                path.display()
            ));
        }
        let width = header.get_int("NAXIS1").unwrap_or(0);
        let height = header.get_int("NAXIS2").unwrap_or(0);
        if width <= 0 || height <= 0 {
            return Err(format!("{}: empty image", path.display()));
        }
        let bzero = header.get_float("BZERO").unwrap_or(0.0);
        let bscale = header.get_float("BSCALE").unwrap_or(1.0);
        Ok(Self {
            path: path.to_path_buf(),
            reader,
            header,
            data_offset,
            bitpix,
            bzero,
            bscale,
            width: width as u32,
            height: height as u32,
            scratch: Vec::new(),
        })
    }

    fn bytes_per_sample(&self) -> usize {
        (self.bitpix.unsigned_abs() / 8) as usize
    }

    /// Decode rows `row..row + rows` into `out` as physical `f64` values.
    fn read_rows(&mut self, row: usize, rows: usize, out: &mut Vec<f64>) -> Result<(), String> {
        let bps = self.bytes_per_sample();
        let row_bytes = self.width as usize * bps;
        let start = self.data_offset + (row * row_bytes) as u64;
        self.scratch.resize(rows * row_bytes, 0);
        self.reader
            .seek(SeekFrom::Start(start))
            .and_then(|_| self.reader.read_exact(&mut self.scratch))
            .map_err(|e| {
                format!(
                    "{}: reading rows {row}..{}: {e}",
                    self.path.display(),
                    row + rows
                )
            })?;
        out.clear();
        out.reserve(rows * self.width as usize);
        let (bzero, bscale) = (self.bzero, self.bscale);
        let physical = |stored: f64| stored * bscale + bzero;
        match self.bitpix {
            8 => out.extend(self.scratch.iter().map(|&v| physical(f64::from(v)))),
            16 => out.extend(
                self.scratch
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .map(|c| physical(f64::from(i16::from_be_bytes(*c)))),
            ),
            32 => out.extend(
                self.scratch
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|c| physical(f64::from(i32::from_be_bytes(*c)))),
            ),
            -32 => out.extend(
                self.scratch
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|c| physical(f64::from(f32::from_be_bytes(*c)))),
            ),
            _ => out.extend(
                self.scratch
                    .as_chunks::<8>()
                    .0
                    .iter()
                    .map(|c| physical(f64::from_be_bytes(*c))),
            ),
        }
        Ok(())
    }
}

fn median_in_place(values: &mut [f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mid = values.len() / 2;
    let (_, m, _) = values.select_nth_unstable_by(mid, f64::total_cmp);
    *m
}

/// Sigma-clipped mean and robust σ of `values` (reordered in place).
fn clipped_level(values: &mut [f64]) -> (f64, f64) {
    let median = median_in_place(values);
    let mut deviations: Vec<f64> = values.iter().map(|v| (v - median).abs()).collect();
    let sigma = 1.4826 * median_in_place(&mut deviations);
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

/// Measure every frame's level without combining anything.
pub fn measure_frame_levels(paths: &[PathBuf]) -> Result<Vec<FrameLevel>, String> {
    paths
        .iter()
        .map(|p| BandSource::open(p).and_then(|mut s| measure_level(&mut s)))
        .collect()
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

/// Every source must agree with the first on a card, when both carry it.
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
        if let (Some(a), Some(b)) = (exposure(&first.header), exposure(&source.header)) {
            if (a - b).abs() > 1e-3_f64.max(a.abs() * 1e-4) {
                return Err(format!(
                    "{} was exposed {b} s but {} was exposed {a} s",
                    source.path.display(),
                    first.path.display()
                ));
            }
        }
        for key in ["GAIN", "OFFSET", "XBINNING", "YBINNING"] {
            if let (Some(a), Some(b)) = (
                card_i64(&first.header, &[key]),
                card_i64(&source.header, &[key]),
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

/// Build a dark or bias master from `paths` and write it to `output`.
///
/// Fails without writing anything when the frames disagree on size, exposure,
/// gain, offset or binning, when more than half of them leak, or when fewer
/// than two frames are left after the leaking ones are dropped.
pub fn build_streamed_master(
    paths: &[PathBuf],
    output: &Path,
    config: &StreamedMasterConfig,
) -> Result<StreamedMasterResult, String> {
    if paths.len() < 2 {
        return Err(format!(
            "a master needs at least 2 frames; {} given",
            paths.len()
        ));
    }
    let mut sources: Vec<BandSource> = paths
        .iter()
        .map(|p| BandSource::open(p))
        .collect::<Result<_, _>>()?;
    check_agreement(&sources)?;

    let frame_levels: Vec<FrameLevel> = sources
        .iter_mut()
        .map(measure_level)
        .collect::<Result<_, _>>()?;
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
        return Err(format!(
            "light leak: {} of {} frames read more than {:.1} ADU above the first frames \
             ({:.1} ADU); no master was written",
            leaking_frames.len(),
            paths.len(),
            leak.threshold,
            leak.baseline
        ));
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
            source.read_rows(row, rows, band)?;
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
        .map_err(|e| format!("combining rows {row}..{}: {e}", row + rows))?;
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

    let first = &kept[0].header;
    let temps: Vec<f64> = kept
        .iter()
        .filter_map(|s| card_f64(&s.header, &["CCD-TEMP", "CCD_TEMP"]))
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
    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("creating {}: {e}", parent.display()))?;
    }
    let partial = output.with_extension("partial.fits");
    write_fits(&partial, &image, &header)
        .map_err(|e| format!("writing {}: {e}", partial.display()))?;
    std::fs::rename(&partial, output)
        .map_err(|e| format!("moving master into {}: {e}", output.display()))?;

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
        write_fits(&path, &ImageData::from_u16(w, h, 1, pixels), &header).unwrap();
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
        assert!(err.contains("light leak"), "{err}");
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
        assert!(err.contains("exposed"), "{err}");
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
