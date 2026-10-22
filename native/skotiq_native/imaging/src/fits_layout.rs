//! Sample order of multi-plane FITS data.
//!
//! The FITS standard stores a `NAXIS3 > 1` image plane by plane: every sample
//! of plane 1, then every sample of plane 2, and so on. In memory an
//! [`ImageData`](crate::ImageData) keeps its channels interleaved
//! (`R G B R G B …`), so the writer and the readers convert between the two.
//!
//! Earlier builds of this app wrote the interleaved buffer as it was, under the
//! same planar header, and every other FITS reader (PixInsight, astropy, Siril)
//! opened those files scrambled. The writer now stamps [`LAYOUT_KEYWORD`] on
//! every multi-plane file. A multi-plane file without the stamp is either a
//! standard planar file from another program or a legacy interleaved file from
//! this app; [`detect_layout`] tells them apart from the pixels.

use crate::{FitsHeader, PixelType};

/// The header card that records how a multi-plane file's samples are ordered.
pub const LAYOUT_KEYWORD: &str = "SKLAYOUT";

/// How the samples of a multi-plane image follow each other on disk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlaneLayout {
    /// The FITS standard: one whole plane after another.
    Planar,
    /// The pixel's channels side by side, as legacy files of this app hold them.
    Interleaved,
}

impl PlaneLayout {
    /// The value written to [`LAYOUT_KEYWORD`].
    pub fn as_card(self) -> &'static str {
        match self {
            PlaneLayout::Planar => "PLANAR",
            PlaneLayout::Interleaved => "INTERLEAVED",
        }
    }
}

/// The layout a header states, if it states one.
pub fn layout_from_header(header: &FitsHeader) -> Option<PlaneLayout> {
    let value = header
        .get_string(LAYOUT_KEYWORD)?
        .trim()
        .to_ascii_uppercase();
    match value.as_str() {
        "PLANAR" => Some(PlaneLayout::Planar),
        "INTERLEAVED" => Some(PlaneLayout::Interleaved),
        _ => None,
    }
}

/// Points sampled when measuring the layout, spread over the whole frame.
const DETECTION_SAMPLES: usize = 200_000;

/// Below this correlation the first two planes, read as planes, share no
/// structure.
const UNRELATED_PLANES: f64 = 0.1;

/// Above this correlation the first two channels, read as interleaved, share
/// the same stars.
const RELATED_CHANNELS: f64 = 0.6;

/// Decide how a multi-plane image without a layout card is ordered.
///
/// `sample(k)` returns the `k`-th sample in file order. The test compares the
/// small-scale structure (each sample minus a neighbor to its left) of the
/// first two channels under both readings. Stars and nebula edges sit at the same
/// pixel in every channel, so the right reading correlates strongly. Read as
/// planes, a legacy interleaved file pairs two unrelated parts of the frame
/// and correlates near zero. Read as interleaved, a planar file pairs
/// neighboring pixels of one plane, which also correlate, so only the planar
/// reading can rule a layout out. Anything short of a clear interleaved
/// verdict is read as planar, the standard.
pub fn detect_layout(
    width: usize,
    height: usize,
    channels: usize,
    sample: impl Fn(usize) -> f64,
) -> PlaneLayout {
    if channels < 2 || width < 3 || height < 1 {
        return PlaneLayout::Planar;
    }
    let pixels = width * height;
    let step = (pixels / DETECTION_SAMPLES).max(1);
    if plane_correlation(width, height, channels, &sample) >= UNRELATED_PLANES {
        return PlaneLayout::Planar;
    }
    let interleaved = correlation(pixels, step, width, 1, |p| {
        (sample(p * channels), sample(p * channels + 1))
    });
    if interleaved >= RELATED_CHANNELS {
        PlaneLayout::Interleaved
    } else {
        PlaneLayout::Planar
    }
}

/// How strongly the first two planes share small-scale structure when the
/// samples are read plane by plane: near 1 for a color image read in its true
/// order, near 0 for a legacy interleaved file read as planes.
///
/// Samples `channels` apart are differenced: in a legacy file those are one
/// channel of two neighboring pixels, so the fixed offsets between channel
/// levels cannot show up as shared structure.
pub fn plane_correlation(
    width: usize,
    height: usize,
    channels: usize,
    sample: impl Fn(usize) -> f64,
) -> f64 {
    let pixels = width * height;
    let step = (pixels / DETECTION_SAMPLES).max(1);
    correlation(pixels, step, width, channels, |p| {
        (sample(p), sample(pixels + p))
    })
}

/// Pearson correlation of the horizontal differences, `lag` pixels apart, of
/// two channels over every `step`-th pixel with a neighbor that far left in
/// its row.
fn correlation(
    pixels: usize,
    step: usize,
    width: usize,
    lag: usize,
    pair: impl Fn(usize) -> (f64, f64),
) -> f64 {
    let (mut n, mut sa, mut sb, mut saa, mut sbb, mut sab) = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    let mut p = lag;
    while p < pixels {
        if p % width >= lag {
            let (a1, b1) = pair(p);
            let (a0, b0) = pair(p - lag);
            let (a, b) = (a1 - a0, b1 - b0);
            if a.is_finite() && b.is_finite() {
                n += 1.0;
                sa += a;
                sb += b;
                saa += a * a;
                sbb += b * b;
                sab += a * b;
            }
        }
        p += step;
    }
    if n < 2.0 {
        return 0.0;
    }
    let cov = sab / n - (sa / n) * (sb / n);
    let va = saa / n - (sa / n).powi(2);
    let vb = sbb / n - (sb / n).powi(2);
    if va <= 0.0 || vb <= 0.0 {
        return 0.0;
    }
    cov / (va * vb).sqrt()
}

/// The value of the `k`-th sample of a little-endian buffer of `pixel_type`.
pub fn le_sample(data: &[u8], pixel_type: PixelType, k: usize) -> f64 {
    let size = pixel_type.byte_size();
    let Some(bytes) = data.get(k * size..(k + 1) * size) else {
        return f64::NAN;
    };
    match pixel_type {
        PixelType::U8 => bytes[0] as f64,
        PixelType::U16 => u16::from_le_bytes([bytes[0], bytes[1]]) as f64,
        PixelType::U32 => u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as f64,
        PixelType::F32 => f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as f64,
        PixelType::F64 => f64::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]),
    }
}

/// Reorder a planar sample buffer into interleaved order. `sample_bytes` is
/// the size of one sample.
pub fn planar_to_interleaved(
    data: &[u8],
    pixels: usize,
    channels: usize,
    sample_bytes: usize,
) -> Vec<u8> {
    let mut out = vec![0u8; data.len()];
    let plane_bytes = pixels * sample_bytes;
    for c in 0..channels {
        let plane = &data[c * plane_bytes..(c + 1) * plane_bytes];
        for (p, sample) in plane.chunks_exact(sample_bytes).enumerate() {
            let at = (p * channels + c) * sample_bytes;
            out[at..at + sample_bytes].copy_from_slice(sample);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A star field whose three channels share their stars at different
    /// brightness, plus independent noise per channel.
    fn scene(width: usize, height: usize) -> Vec<[f32; 3]> {
        let mut state = 0x2545_f491_4f6c_dd1du64;
        let mut noise = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state >> 40) as f32 / (1u64 << 24) as f32 - 0.5
        };
        let stars: Vec<(f32, f32)> = (0..80)
            .map(|i| {
                let t = i as f32 * 0.618_034;
                (
                    (t.fract() * width as f32),
                    ((t * 7.3).fract() * height as f32),
                )
            })
            .collect();
        (0..width * height)
            .map(|p| {
                let (x, y) = ((p % width) as f32, (p / width) as f32);
                let star: f32 = stars
                    .iter()
                    .map(|&(sx, sy)| (-((x - sx).powi(2) + (y - sy).powi(2)) / 4.0).exp())
                    .sum();
                [
                    100.0 + 900.0 * star + 5.0 * noise(),
                    120.0 + 600.0 * star + 5.0 * noise(),
                    90.0 + 400.0 * star + 5.0 * noise(),
                ]
            })
            .collect()
    }

    #[test]
    fn a_planar_file_reads_as_planar() {
        let (w, h) = (160, 120);
        let px = scene(w, h);
        let planar: Vec<f64> = (0..3)
            .flat_map(|c| px.iter().map(move |p| p[c] as f64))
            .collect();
        assert_eq!(detect_layout(w, h, 3, |k| planar[k]), PlaneLayout::Planar);
    }

    #[test]
    fn a_legacy_interleaved_file_reads_as_interleaved() {
        let (w, h) = (160, 120);
        let px = scene(w, h);
        let interleaved: Vec<f64> = px.iter().flat_map(|p| p.map(f64::from)).collect();
        assert_eq!(
            detect_layout(w, h, 3, |k| interleaved[k]),
            PlaneLayout::Interleaved
        );
    }

    #[test]
    fn pure_noise_falls_back_to_the_standard() {
        let mut state = 7u64;
        let data: Vec<f64> = (0..3 * 100 * 80)
            .map(|_| {
                state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
                (state >> 33) as f64
            })
            .collect();
        assert_eq!(detect_layout(100, 80, 3, |k| data[k]), PlaneLayout::Planar);
    }

    #[test]
    fn planar_to_interleaved_reorders_samples() {
        let planar: Vec<u8> = vec![1, 2, 3, 10, 20, 30];
        assert_eq!(
            planar_to_interleaved(&planar, 3, 2, 1),
            vec![1, 10, 2, 20, 3, 30]
        );
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("sk_fits_layout_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(name)
    }

    fn color_image(w: usize, h: usize) -> crate::ImageData {
        let samples: Vec<f32> = scene(w, h).into_iter().flatten().collect();
        crate::ImageData::from_f32(w as u32, h as u32, 3, &samples)
    }

    /// The data block of a FITS file, as big-endian f32 samples.
    fn data_block(path: &std::path::Path, samples: usize) -> Vec<f32> {
        let bytes = std::fs::read(path).unwrap();
        let header = crate::read_fits_header(path).unwrap();
        let cards = 36 * 80;
        let end = bytes
            .chunks(80)
            .position(|card| card.starts_with(b"END "))
            .unwrap();
        let start = (end * 80 / cards + 1) * cards;
        assert!(header.get_int("NAXIS3") == Some(3));
        bytes[start..start + samples * 4]
            .as_chunks::<4>()
            .0
            .iter()
            .map(|b| f32::from_be_bytes(*b))
            .collect()
    }

    #[test]
    fn the_writer_stores_color_plane_by_plane() {
        let (w, h) = (40, 30);
        let image = color_image(w, h);
        let path = scratch("planar.fits");
        crate::write_fits(&path, &image, &FitsHeader::new()).unwrap();

        let on_disk = data_block(&path, w * h * 3);
        let source = image.as_f32().unwrap();
        for c in 0..3 {
            for p in [0, 1, w + 3, w * h - 1] {
                assert_eq!(
                    on_disk[c * w * h + p],
                    source[p * 3 + c],
                    "plane {c} pixel {p}"
                );
            }
        }
        let header = crate::read_fits_header(&path).unwrap();
        assert_eq!(header.get_string(LAYOUT_KEYWORD), Some("PLANAR"));

        let (back, back_header) = crate::read_fits(&path).unwrap();
        assert_eq!(back.data, image.data);
        assert!(back_header.get(LAYOUT_KEYWORD).is_none());
    }

    /// Write `samples` (file order) under a three-plane f32 header that carries
    /// no layout card, as legacy builds and other programs do.
    fn write_unstamped(path: &std::path::Path, w: usize, h: usize, samples: &[f32]) {
        let mut out = Vec::new();
        for card in [
            "SIMPLE  =                    T".to_string(),
            "BITPIX  =                  -32".to_string(),
            "NAXIS   =                    3".to_string(),
            format!("NAXIS1  = {w:>20}"),
            format!("NAXIS2  = {h:>20}"),
            "NAXIS3  =                    3".to_string(),
            "END".to_string(),
        ] {
            out.extend_from_slice(format!("{card:<80}").as_bytes());
        }
        out.resize(2880, b' ');
        for v in samples {
            out.extend_from_slice(&v.to_be_bytes());
        }
        out.resize(out.len().div_ceil(2880) * 2880, 0);
        std::fs::write(path, out).unwrap();
    }

    #[test]
    fn a_legacy_interleaved_file_still_reads_correctly() {
        let (w, h) = (160, 120);
        let image = color_image(w, h);
        let path = scratch("legacy.fits");
        write_unstamped(&path, w, h, &image.as_f32().unwrap());

        let (back, _) = crate::read_fits(&path).unwrap();
        assert_eq!(back.data, image.data);
        let mapped = crate::MappedFitsReader::open(&path).unwrap();
        assert_eq!(
            mapped.read_region(0, 0, w as u32, h as u32).unwrap().data,
            image.data
        );
    }

    #[test]
    fn another_programs_planar_file_reads_correctly() {
        let (w, h) = (160, 120);
        let image = color_image(w, h);
        let interleaved = image.as_f32().unwrap();
        let planar: Vec<f32> = (0..3)
            .flat_map(|c| interleaved.iter().skip(c).step_by(3).copied())
            .collect();
        let path = scratch("external.fits");
        write_unstamped(&path, w, h, &planar);

        let (back, _) = crate::read_fits(&path).unwrap();
        assert_eq!(back.data, image.data);
        let mapped = crate::MappedFitsReader::open(&path).unwrap();
        let region = mapped.read_region(5, 7, 20, 10).unwrap();
        let expected = &interleaved[(7 * w + 5) * 3..(7 * w + 5) * 3 + 3];
        assert_eq!(region.as_f32().unwrap()[..3], *expected);
        let thumb = mapped.read_downsampled(4).unwrap();
        assert_eq!(thumb.as_f32().unwrap()[3..6], interleaved[12..15]);
    }
}
