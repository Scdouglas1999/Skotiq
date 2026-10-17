//! Image debayering algorithms for color cameras

use rayon::prelude::*;

/// Bayer pattern type
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BayerPattern {
    RGGB,
    BGGR,
    GRBG,
    GBRG,
}

impl BayerPattern {
    /// Parse from FITS BAYERPAT keyword
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_uppercase().as_str() {
            "RGGB" => Some(Self::RGGB),
            "BGGR" => Some(Self::BGGR),
            "GRBG" => Some(Self::GRBG),
            "GBRG" => Some(Self::GBRG),
            _ => None,
        }
    }

    /// Get the color at a specific pixel position
    pub fn color_at(&self, x: usize, y: usize) -> BayerColor {
        let x_odd = x % 2 == 1;
        let y_odd = y % 2 == 1;

        match (self, x_odd, y_odd) {
            (Self::RGGB, false, false) => BayerColor::Red,
            (Self::RGGB, true, false) => BayerColor::Green,
            (Self::RGGB, false, true) => BayerColor::Green,
            (Self::RGGB, true, true) => BayerColor::Blue,

            (Self::BGGR, false, false) => BayerColor::Blue,
            (Self::BGGR, true, false) => BayerColor::Green,
            (Self::BGGR, false, true) => BayerColor::Green,
            (Self::BGGR, true, true) => BayerColor::Red,

            (Self::GRBG, false, false) => BayerColor::Green,
            (Self::GRBG, true, false) => BayerColor::Red,
            (Self::GRBG, false, true) => BayerColor::Blue,
            (Self::GRBG, true, true) => BayerColor::Green,

            (Self::GBRG, false, false) => BayerColor::Green,
            (Self::GBRG, true, false) => BayerColor::Blue,
            (Self::GBRG, false, true) => BayerColor::Red,
            (Self::GBRG, true, true) => BayerColor::Green,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BayerColor {
    Red,
    Green,
    Blue,
}

/// Debayer algorithm
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DebayerAlgorithm {
    /// Simple bilinear interpolation (fast)
    #[default]
    Bilinear,
    /// VNG - Variable Number of Gradients (better quality)
    VNG,
    /// Super pixel - 2x2 binning (fastest, half resolution)
    SuperPixel,
}

/// RGB image data
#[derive(Debug, Clone)]
pub struct RgbImage {
    pub width: u32,
    pub height: u32,
    pub red: Vec<u16>,
    pub green: Vec<u16>,
    pub blue: Vec<u16>,
}

impl RgbImage {
    /// Convert to interleaved RGB bytes (8-bit per channel for display)
    pub fn to_rgb8(&self) -> Vec<u8> {
        let len = self.width as usize * self.height as usize;
        let mut output = Vec::with_capacity(len * 3);

        for i in 0..len {
            output.push((self.red[i] >> 8) as u8);
            output.push((self.green[i] >> 8) as u8);
            output.push((self.blue[i] >> 8) as u8);
        }

        output
    }

    /// Convert to RGBA bytes (8-bit per channel for display)
    pub fn to_rgba8(&self) -> Vec<u8> {
        let len = self.width as usize * self.height as usize;
        let mut output = Vec::with_capacity(len * 4);

        for i in 0..len {
            output.push((self.red[i] >> 8) as u8);
            output.push((self.green[i] >> 8) as u8);
            output.push((self.blue[i] >> 8) as u8);
            output.push(255); // Alpha
        }

        output
    }

    /// Convert to interleaved RGB16 (for stretching before display)
    pub fn to_rgb16(&self) -> Vec<u16> {
        let len = self.width as usize * self.height as usize;
        let mut output = Vec::with_capacity(len * 3);

        for i in 0..len {
            output.push(self.red[i]);
            output.push(self.green[i]);
            output.push(self.blue[i]);
        }

        output
    }
}

/// Debayer a raw 16-bit image
pub fn debayer(
    raw_data: &[u8],
    width: u32,
    height: u32,
    pattern: BayerPattern,
    algorithm: DebayerAlgorithm,
) -> RgbImage {
    // Convert to u16 array
    let pixels: Vec<u16> = raw_data
        .as_chunks::<2>()
        .0
        .iter()
        .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
        .collect();

    match algorithm {
        DebayerAlgorithm::Bilinear => debayer_bilinear(&pixels, width, height, pattern),
        DebayerAlgorithm::VNG => debayer_vng(&pixels, width, height, pattern),
        DebayerAlgorithm::SuperPixel => debayer_superpixel(&pixels, width, height, pattern),
    }
}

/// Debayer a raw u16 image directly to the [`RgbImage`] struct, preserving the
/// demosaiced output geometry.
///
/// This is the geometry-preserving primitive: callers that need to know the
/// output dimensions (e.g. [`SuperPixel`](DebayerAlgorithm::SuperPixel) halves
/// resolution) must build their result from [`RgbImage::width`] /
/// [`RgbImage::height`] rather than assuming the input CFA size.
pub fn debayer_u16(
    raw_data: &[u16],
    width: u32,
    height: u32,
    pattern: BayerPattern,
    algorithm: DebayerAlgorithm,
) -> RgbImage {
    match algorithm {
        DebayerAlgorithm::Bilinear => debayer_bilinear(raw_data, width, height, pattern),
        DebayerAlgorithm::VNG => debayer_vng(raw_data, width, height, pattern),
        DebayerAlgorithm::SuperPixel => debayer_superpixel(raw_data, width, height, pattern),
    }
}

/// Debayer a raw u16 image directly to interleaved RGB16.
///
/// Convenience for callers that only need the interleaved samples and already
/// know the output geometry (e.g. full-resolution Bilinear/VNG). For algorithms
/// that change the output dimensions — notably
/// [`SuperPixel`](DebayerAlgorithm::SuperPixel), which halves resolution — use
/// [`debayer_u16`] and read the resulting [`RgbImage::width`] /
/// [`RgbImage::height`] so the buffer length and the declared dimensions stay
/// consistent.
pub fn debayer_to_rgb16(
    raw_data: &[u16],
    width: u32,
    height: u32,
    pattern: BayerPattern,
    algorithm: DebayerAlgorithm,
) -> Vec<u16> {
    debayer_u16(raw_data, width, height, pattern, algorithm).to_rgb16()
}

/// Bilinear interpolation debayering
fn debayer_bilinear(pixels: &[u16], width: u32, height: u32, pattern: BayerPattern) -> RgbImage {
    let w = width as usize;
    let h = height as usize;
    let len = w * h;

    let mut red = vec![0u16; len];
    let mut green = vec![0u16; len];
    let mut blue = vec![0u16; len];

    // Parallel processing using Rayon
    // We split the output vectors into rows and process them in parallel
    red.par_chunks_mut(w)
        .zip(green.par_chunks_mut(w))
        .zip(blue.par_chunks_mut(w))
        .enumerate()
        .for_each(|(y, ((red_row, green_row), blue_row))| {
            for x in 0..w {
                let idx = y * w + x;
                let color = pattern.color_at(x, y);

                // Set the known color
                match color {
                    BayerColor::Red => red_row[x] = pixels[idx],
                    BayerColor::Green => green_row[x] = pixels[idx],
                    BayerColor::Blue => blue_row[x] = pixels[idx],
                }

                // Interpolate missing colors
                match color {
                    BayerColor::Red => {
                        // At red pixel: interpolate green and blue
                        green_row[x] = interpolate_cross(pixels, w, h, x, y);
                        blue_row[x] = interpolate_diagonal(pixels, w, h, x, y);
                    }
                    BayerColor::Blue => {
                        // At blue pixel: interpolate green and red
                        green_row[x] = interpolate_cross(pixels, w, h, x, y);
                        red_row[x] = interpolate_diagonal(pixels, w, h, x, y);
                    }
                    BayerColor::Green => {
                        // At green pixel: interpolate red and blue
                        let horizontal_color = axis_neighbor_color(pattern, x, y, true);
                        if horizontal_color == BayerColor::Red {
                            red_row[x] = interpolate_horizontal(pixels, w, h, x, y);
                            blue_row[x] = interpolate_vertical(pixels, w, h, x, y);
                        } else {
                            red_row[x] = interpolate_vertical(pixels, w, h, x, y);
                            blue_row[x] = interpolate_horizontal(pixels, w, h, x, y);
                        }
                    }
                }
            }
        });

    RgbImage {
        width,
        height,
        red,
        green,
        blue,
    }
}

fn axis_neighbor_color(pattern: BayerPattern, x: usize, y: usize, horizontal: bool) -> BayerColor {
    if horizontal {
        if x > 0 {
            return pattern.color_at(x - 1, y);
        }
        pattern.color_at(x + 1, y)
    } else if y > 0 {
        pattern.color_at(x, y - 1)
    } else {
        pattern.color_at(x, y + 1)
    }
}

/// Interpolate from 4 adjacent pixels (cross pattern)
fn interpolate_cross(pixels: &[u16], w: usize, h: usize, x: usize, y: usize) -> u16 {
    let mut sum = 0u32;
    let mut count = 0u32;

    if x > 0 {
        sum += pixels[y * w + x - 1] as u32;
        count += 1;
    }
    if x < w - 1 {
        sum += pixels[y * w + x + 1] as u32;
        count += 1;
    }
    if y > 0 {
        sum += pixels[(y - 1) * w + x] as u32;
        count += 1;
    }
    if y < h - 1 {
        sum += pixels[(y + 1) * w + x] as u32;
        count += 1;
    }

    sum.checked_div(count).map_or(0, |q| q as u16)
}

/// Interpolate from 4 diagonal pixels
fn interpolate_diagonal(pixels: &[u16], w: usize, h: usize, x: usize, y: usize) -> u16 {
    let mut sum = 0u32;
    let mut count = 0u32;

    if x > 0 && y > 0 {
        sum += pixels[(y - 1) * w + x - 1] as u32;
        count += 1;
    }
    if x < w - 1 && y > 0 {
        sum += pixels[(y - 1) * w + x + 1] as u32;
        count += 1;
    }
    if x > 0 && y < h - 1 {
        sum += pixels[(y + 1) * w + x - 1] as u32;
        count += 1;
    }
    if x < w - 1 && y < h - 1 {
        sum += pixels[(y + 1) * w + x + 1] as u32;
        count += 1;
    }

    sum.checked_div(count).map_or(0, |q| q as u16)
}

/// Interpolate from horizontal neighbors
fn interpolate_horizontal(pixels: &[u16], w: usize, _h: usize, x: usize, y: usize) -> u16 {
    let mut sum = 0u32;
    let mut count = 0u32;

    if x > 0 {
        sum += pixels[y * w + x - 1] as u32;
        count += 1;
    }
    if x < w - 1 {
        sum += pixels[y * w + x + 1] as u32;
        count += 1;
    }

    sum.checked_div(count).map_or(0, |q| q as u16)
}

/// Interpolate from vertical neighbors
fn interpolate_vertical(pixels: &[u16], w: usize, h: usize, x: usize, y: usize) -> u16 {
    let mut sum = 0u32;
    let mut count = 0u32;

    if y > 0 {
        sum += pixels[(y - 1) * w + x] as u32;
        count += 1;
    }
    if y < h - 1 {
        sum += pixels[(y + 1) * w + x] as u32;
        count += 1;
    }

    sum.checked_div(count).map_or(0, |q| q as u16)
}

/// VNG (Variable Number of Gradients) debayering
/// Higher quality but slower than bilinear
fn debayer_vng(pixels: &[u16], width: u32, height: u32, pattern: BayerPattern) -> RgbImage {
    let w = width as usize;
    let h = height as usize;
    let len = w * h;

    let mut red = vec![0u16; len];
    let mut green = vec![0u16; len];
    let mut blue = vec![0u16; len];

    // VNG uses gradients in 8 directions to select best interpolation
    // Parallel processing for the main image area
    red.par_chunks_mut(w)
        .zip(green.par_chunks_mut(w))
        .zip(blue.par_chunks_mut(w))
        .enumerate()
        .for_each(|(y, ((red_row, green_row), blue_row))| {
            // Process main area (skip borders)
            if y >= 2 && y < h - 2 {
                for x in 2..w - 2 {
                    let color = pattern.color_at(x, y);

                    // Calculate gradients in 8 directions
                    let gradients = calculate_gradients(pixels, w, x, y);
                    // Why: `calculate_gradients` always returns an 8-element
                    // array of i32 gradients (per direction); .min() is therefore guaranteed
                    // Some. Zero is the inert placeholder if a future refactor returned
                    // empty — a zero threshold means "no smooth direction qualifies", which
                    // is the safe debayer-fallback path.
                    let min_g = gradients.iter().copied().min().unwrap_or(0);
                    // Threshold = 1.5 * min_gradient (Chang/Cok VNG criterion):
                    // directions whose gradient is at or below this are
                    // considered "smooth" and selected for interpolation,
                    // preserving edges. The earlier formula
                    // `min + 1.5 * (max - min)` evaluated to `min + 1.5*range`,
                    // which was always greater than max — every direction
                    // passed and VNG degenerated to averaging all 8 directions.
                    let threshold = (min_g * 3) / 2;

                    // Average values from directions with small gradients
                    let (r, g, b) =
                        vng_interpolate(pixels, w, h, x, y, &gradients, threshold, color, pattern);

                    red_row[x] = r;
                    green_row[x] = g;
                    blue_row[x] = b;
                }
            }

            // Handle borders with simple bilinear (also parallelized now!)
            // We iterate all pixels in the row, but only process if it's a border pixel
            if y < 2 || y >= h - 2 {
                // Entire row is border
                for x in 0..w {
                    process_border_pixel(pixels, red_row, green_row, blue_row, w, h, x, y, pattern);
                }
            } else {
                // Just left and right edges
                for x in 0..2 {
                    process_border_pixel(pixels, red_row, green_row, blue_row, w, h, x, y, pattern);
                }
                for x in w - 2..w {
                    process_border_pixel(pixels, red_row, green_row, blue_row, w, h, x, y, pattern);
                }
            }
        });

    RgbImage {
        width,
        height,
        red,
        green,
        blue,
    }
}

/// Helper for VNG border processing
#[allow(clippy::too_many_arguments)]
fn process_border_pixel(
    pixels: &[u16],
    red_row: &mut [u16],
    green_row: &mut [u16],
    blue_row: &mut [u16],
    w: usize,
    h: usize,
    x: usize,
    y: usize,
    pattern: BayerPattern,
) {
    let idx = y * w + x; // Only used for reading from pixels
    let color = pattern.color_at(x, y);

    match color {
        BayerColor::Red => {
            red_row[x] = pixels[idx];
            green_row[x] = interpolate_cross(pixels, w, h, x, y);
            blue_row[x] = interpolate_diagonal(pixels, w, h, x, y);
        }
        BayerColor::Green => {
            green_row[x] = pixels[idx];
            // A green site has two phases: in a red row its horizontal
            // neighbours are red and its vertical neighbours blue; in a blue
            // row this is reversed. Choose the axis from the actual colour of a
            // horizontal neighbour instead of assuming the red-row phase, which
            // mis-coloured every green pixel sitting in a blue row.
            let horiz_neighbor = if x + 1 < w {
                pattern.color_at(x + 1, y)
            } else {
                pattern.color_at(x - 1, y)
            };
            if horiz_neighbor == BayerColor::Red {
                red_row[x] = interpolate_horizontal(pixels, w, h, x, y);
                blue_row[x] = interpolate_vertical(pixels, w, h, x, y);
            } else {
                red_row[x] = interpolate_vertical(pixels, w, h, x, y);
                blue_row[x] = interpolate_horizontal(pixels, w, h, x, y);
            }
        }
        BayerColor::Blue => {
            blue_row[x] = pixels[idx];
            green_row[x] = interpolate_cross(pixels, w, h, x, y);
            red_row[x] = interpolate_diagonal(pixels, w, h, x, y);
        }
    }
}

/// Calculate gradients in 8 directions
fn calculate_gradients(pixels: &[u16], w: usize, x: usize, y: usize) -> [i32; 8] {
    let idx = |dx: i32, dy: i32| -> u16 {
        pixels[(y as i32 + dy) as usize * w + (x as i32 + dx) as usize]
    };

    [
        // N
        (idx(0, -2) as i32 - idx(0, 0) as i32).abs() + (idx(0, -1) as i32 - idx(0, 1) as i32).abs(),
        // NE
        (idx(2, -2) as i32 - idx(0, 0) as i32).abs()
            + (idx(1, -1) as i32 - idx(-1, 1) as i32).abs(),
        // E
        (idx(2, 0) as i32 - idx(0, 0) as i32).abs() + (idx(1, 0) as i32 - idx(-1, 0) as i32).abs(),
        // SE
        (idx(2, 2) as i32 - idx(0, 0) as i32).abs() + (idx(1, 1) as i32 - idx(-1, -1) as i32).abs(),
        // S
        (idx(0, 2) as i32 - idx(0, 0) as i32).abs() + (idx(0, 1) as i32 - idx(0, -1) as i32).abs(),
        // SW
        (idx(-2, 2) as i32 - idx(0, 0) as i32).abs()
            + (idx(-1, 1) as i32 - idx(1, -1) as i32).abs(),
        // W
        (idx(-2, 0) as i32 - idx(0, 0) as i32).abs() + (idx(-1, 0) as i32 - idx(1, 0) as i32).abs(),
        // NW
        (idx(-2, -2) as i32 - idx(0, 0) as i32).abs()
            + (idx(-1, -1) as i32 - idx(1, 1) as i32).abs(),
    ]
}

/// VNG interpolation using gradient-selected directions
///
/// For each of the 8 directions (N, NE, E, SE, S, SW, W, NW), we compute
/// candidate R, G, B values by sampling same-color neighbors along that
/// direction. We then select only the directions whose gradient is at or
/// below a threshold (1.5x the minimum gradient), and average the candidate
/// colors from those low-gradient directions. This produces smoother
/// interpolation along edges while preserving detail.
#[allow(clippy::too_many_arguments)]
fn vng_interpolate(
    pixels: &[u16],
    w: usize,
    _h: usize,
    x: usize,
    y: usize,
    gradients: &[i32; 8],
    threshold: i32,
    color: BayerColor,
    pattern: BayerPattern,
) -> (u16, u16, u16) {
    let val = pixels[y * w + x] as i32;

    // Helper to read a pixel at (x+dx, y+dy)
    let px = |dx: i32, dy: i32| -> i32 {
        pixels[(y as i32 + dy) as usize * w + (x as i32 + dx) as usize] as i32
    };

    // Direction offsets: N, NE, E, SE, S, SW, W, NW
    // Each direction provides two sample points at distance 1 and 2 in that direction.
    let dir_offsets: [(i32, i32); 8] = [
        (0, -1),  // N
        (1, -1),  // NE
        (1, 0),   // E
        (1, 1),   // SE
        (0, 1),   // S
        (-1, 1),  // SW
        (-1, 0),  // W
        (-1, -1), // NW
    ];

    // For VNG, we estimate color differences (green - red, green - blue) at the
    // center pixel using neighbors along each selected direction, then average
    // only the estimates from low-gradient (smooth) directions.

    let mut sum_r = 0i64;
    let mut sum_g = 0i64;
    let mut sum_b = 0i64;
    let mut count = 0i64;

    for (i, &(dx, dy)) in dir_offsets.iter().enumerate() {
        if gradients[i] > threshold {
            continue;
        }

        // Sample at distance 1 and 2 along this direction
        let p1 = px(dx, dy);
        let p2 = px(dx * 2, dy * 2);
        let c1 = pattern.color_at((x as i32 + dx) as usize, (y as i32 + dy) as usize);
        let c2 = pattern.color_at((x as i32 + dx * 2) as usize, (y as i32 + dy * 2) as usize);

        // Estimate each channel at the center pixel using this direction.
        // Strategy: the known channel is val. For missing channels, use the
        // neighbor of that color and adjust by the green difference to preserve
        // color ratios (adaptive color plane interpolation).
        let (est_r, est_g, est_b) = match color {
            BayerColor::Red => {
                // We know red = val. Estimate green from nearest green neighbor
                // along this direction, and blue from nearest blue neighbor.
                let est_g = if c1 == BayerColor::Green {
                    // Green neighbor at distance 1: estimate green at center
                    // as green_neighbor - (red_at_neighbor_estimate - red_at_center)
                    // Simplified: green = p1 + (val - p2) when p2 is same color as center
                    if c2 == BayerColor::Red {
                        p1 + (val - p2) / 2
                    } else {
                        p1
                    }
                } else if c2 == BayerColor::Green {
                    p2 + (val - p1) / 2
                } else {
                    // Both neighbors are non-green; use cross interpolation
                    interpolate_cross(pixels, w, _h, x, y) as i32
                };
                let est_b = if c1 == BayerColor::Blue {
                    p1 + (val - p2) / 2
                } else if c2 == BayerColor::Blue {
                    p2 + (val - p1) / 2
                } else {
                    interpolate_diagonal(pixels, w, _h, x, y) as i32
                };
                (val, est_g, est_b)
            }
            BayerColor::Blue => {
                let est_g = if c1 == BayerColor::Green {
                    if c2 == BayerColor::Blue {
                        p1 + (val - p2) / 2
                    } else {
                        p1
                    }
                } else if c2 == BayerColor::Green {
                    p2 + (val - p1) / 2
                } else {
                    interpolate_cross(pixels, w, _h, x, y) as i32
                };
                let est_r = if c1 == BayerColor::Red {
                    p1 + (val - p2) / 2
                } else if c2 == BayerColor::Red {
                    p2 + (val - p1) / 2
                } else {
                    interpolate_diagonal(pixels, w, _h, x, y) as i32
                };
                (est_r, est_g, val)
            }
            BayerColor::Green => {
                // We know green = val. Estimate red and blue from neighbors.
                let est_r = if c1 == BayerColor::Red {
                    if c2 == BayerColor::Green {
                        p1 + (val - p2) / 2
                    } else {
                        p1
                    }
                } else if c2 == BayerColor::Red {
                    p2 + (val - p1) / 2
                } else {
                    // No red neighbor in this direction; use directional interpolation
                    interpolate_horizontal(pixels, w, _h, x, y) as i32
                };
                let est_b = if c1 == BayerColor::Blue {
                    if c2 == BayerColor::Green {
                        p1 + (val - p2) / 2
                    } else {
                        p1
                    }
                } else if c2 == BayerColor::Blue {
                    p2 + (val - p1) / 2
                } else {
                    interpolate_vertical(pixels, w, _h, x, y) as i32
                };
                (est_r, val, est_b)
            }
        };

        sum_r += est_r as i64;
        sum_g += est_g as i64;
        sum_b += est_b as i64;
        count += 1;
    }

    // If no directions passed the threshold (shouldn't happen since threshold
    // is >= min gradient, but guard against it), use all directions.
    if count == 0 {
        for &(dx, dy) in &dir_offsets {
            let p1 = px(dx, dy);
            sum_r += p1 as i64;
            sum_g += p1 as i64;
            sum_b += p1 as i64;
            count += 1;
        }
    }

    (
        (sum_r / count).clamp(0, 65535) as u16,
        (sum_g / count).clamp(0, 65535) as u16,
        (sum_b / count).clamp(0, 65535) as u16,
    )
}

/// Super-pixel debayering (2x2 binning)
/// Produces half-resolution image but fastest method
fn debayer_superpixel(pixels: &[u16], width: u32, height: u32, pattern: BayerPattern) -> RgbImage {
    let w = width as usize;
    let h = height as usize;
    let out_w = w / 2;
    let out_h = h / 2;
    let len = out_w * out_h;

    let mut red = vec![0u16; len];
    let mut green = vec![0u16; len];
    let mut blue = vec![0u16; len];

    // Parallel processing for superpixel
    red.par_chunks_mut(out_w)
        .zip(green.par_chunks_mut(out_w))
        .zip(blue.par_chunks_mut(out_w))
        .enumerate()
        .for_each(|(y, ((red_row, green_row), blue_row))| {
            for x in 0..out_w {
                let src_x = x * 2;
                let src_y = y * 2;

                // Get 2x2 block
                let p00 = pixels[src_y * w + src_x] as u32;
                let p10 = pixels[src_y * w + src_x + 1] as u32;
                let p01 = pixels[(src_y + 1) * w + src_x] as u32;
                let p11 = pixels[(src_y + 1) * w + src_x + 1] as u32;

                // Assign based on pattern
                match pattern {
                    BayerPattern::RGGB => {
                        red_row[x] = p00 as u16;
                        green_row[x] = ((p10 + p01) / 2) as u16;
                        blue_row[x] = p11 as u16;
                    }
                    BayerPattern::BGGR => {
                        blue_row[x] = p00 as u16;
                        green_row[x] = ((p10 + p01) / 2) as u16;
                        red_row[x] = p11 as u16;
                    }
                    BayerPattern::GRBG => {
                        green_row[x] = ((p00 + p11) / 2) as u16;
                        red_row[x] = p10 as u16;
                        blue_row[x] = p01 as u16;
                    }
                    BayerPattern::GBRG => {
                        green_row[x] = ((p00 + p11) / 2) as u16;
                        blue_row[x] = p10 as u16;
                        red_row[x] = p01 as u16;
                    }
                }
            }
        });

    RgbImage {
        width: out_w as u32,
        height: out_h as u32,
        red,
        green,
        blue,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn patterned_raw(pattern: BayerPattern, width: u32, height: u32) -> Vec<u16> {
        let mut pixels = Vec::with_capacity((width * height) as usize);
        for y in 0..height as usize {
            for x in 0..width as usize {
                let value = match pattern.color_at(x, y) {
                    BayerColor::Red => 1000,
                    BayerColor::Green => 500,
                    BayerColor::Blue => 100,
                };
                pixels.push(value);
            }
        }
        pixels
    }

    #[test]
    fn bilinear_green_interpolation_uses_correct_neighbors_for_rggb() {
        let pixels = patterned_raw(BayerPattern::RGGB, 4, 4);
        let rgb = debayer_to_rgb16(
            &pixels,
            4,
            4,
            BayerPattern::RGGB,
            DebayerAlgorithm::Bilinear,
        );
        let idx = (4 + 2) * 3;
        assert_eq!(rgb[idx], 1000);
        assert_eq!(rgb[idx + 1], 500);
        assert_eq!(rgb[idx + 2], 100);
    }

    #[test]
    fn bilinear_green_interpolation_uses_correct_neighbors_for_bggr() {
        let pixels = patterned_raw(BayerPattern::BGGR, 4, 4);
        let rgb = debayer_to_rgb16(
            &pixels,
            4,
            4,
            BayerPattern::BGGR,
            DebayerAlgorithm::Bilinear,
        );
        let idx = ((2 * 4) + 1) * 3;
        assert_eq!(rgb[idx], 1000);
        assert_eq!(rgb[idx + 1], 500);
        assert_eq!(rgb[idx + 2], 100);
    }

    #[test]
    fn vng_border_green_phase_picks_correct_axis() {
        // A green border pixel in a *blue* row (RGGB (0,1)) has blue
        // neighbours horizontally and red vertically, so the border handler
        // must pick the phase from the row, not assume the red-row phase. A
        // 4x4 image is entirely within the 2-pixel VNG border, so every pixel
        // exercises `process_border_pixel`.
        // With uniform per-colour values (R=1000, G=500, B=100) the recovered
        // channels must equal the true colours regardless of stencil size.
        let pixels = patterned_raw(BayerPattern::RGGB, 4, 4);
        let rgb = debayer_to_rgb16(&pixels, 4, 4, BayerPattern::RGGB, DebayerAlgorithm::VNG);
        // Green site at (x=0, y=1): a blue-row green on the border.
        let (x, y) = (0usize, 1usize);
        let idx = (y * 4 + x) * 3;
        assert_eq!(
            rgb[idx], 1000,
            "red must come from the vertical red neighbours"
        );
        assert_eq!(rgb[idx + 1], 500, "green is the sampled value");
        assert_eq!(
            rgb[idx + 2],
            100,
            "blue must come from the horizontal blue neighbours"
        );
    }

    #[test]
    fn vng_threshold_excludes_high_gradient_directions_at_vertical_edge() {
        // Synthetic 9x9 RGGB image with a sharp vertical edge between columns
        // 4 and 5: left half is dark, right half is bright. We probe the
        // gradients at the edge column (x = 4) and confirm that the E/W
        // directional gradients exceed the VNG threshold (1.5 * min_g) and
        // would therefore be excluded — the threshold actually filters
        // something rather than passing every direction.
        let w: usize = 9;
        let h: usize = 9;
        let mut pixels = vec![0u16; w * h];
        for y in 0..h {
            for x in 0..w {
                // Bright right-half, dark left-half. Use the same brightness
                // for every Bayer color so the only gradient is the edge
                // itself, not the natural color mosaic pattern.
                let base: u16 = if x >= 5 { 50_000 } else { 1_000 };
                pixels[y * w + x] = base;
            }
        }

        // Probe at (x = 4, y = 4): the pixel just to the left of the edge.
        // Direction order from calculate_gradients: [N, NE, E, SE, S, SW, W, NW].
        let gradients = calculate_gradients(&pixels, w, 4, 4);
        let min_g = gradients.iter().copied().min().unwrap();
        let threshold = (min_g * 3) / 2;

        // N and S directions look at same-brightness neighbors (all in the
        // dark half), so their gradient must be the minimum (zero here).
        assert_eq!(gradients[0], 0, "N gradient on uniform column must be 0");
        assert_eq!(gradients[4], 0, "S gradient on uniform column must be 0");
        assert_eq!(min_g, 0, "minimum gradient on uniform column must be 0");
        assert_eq!(threshold, 0, "(min_g * 3) / 2 must be 0 when min_g = 0");

        // E direction crosses the edge: idx(2,0) is in the bright half,
        // idx(0,0) is in the dark half — the gradient must be huge and
        // therefore exceed the threshold.
        let east = gradients[2];
        assert!(
            east > threshold,
            "east gradient {east} must exceed threshold {threshold} at vertical edge",
        );
        // Same goes for NE and SE — all have a sample in the bright half.
        assert!(
            gradients[1] > threshold,
            "NE gradient must exceed threshold"
        );
        assert!(
            gradients[3] > threshold,
            "SE gradient must exceed threshold"
        );

        // Sanity check: the buggy formula min + 1.5*(max - min) would have
        // produced a threshold strictly greater than max, so every direction
        // would have passed. Verify our new threshold is NOT degenerate.
        let max_g = gradients.iter().copied().max().unwrap();
        let buggy_threshold = min_g + (max_g - min_g) * 3 / 2;
        assert!(
            buggy_threshold > max_g,
            "buggy formula would have passed every direction (sanity check)",
        );
        assert!(
            threshold < max_g,
            "fixed threshold must be below max gradient so it actually filters",
        );

        // Finally, run VNG end-to-end and ensure it produces a non-trivial
        // result (no panics, output preserves the bright/dark contrast).
        let rgb = debayer_to_rgb16(
            &pixels,
            w as u32,
            h as u32,
            BayerPattern::RGGB,
            DebayerAlgorithm::VNG,
        );
        let dark_idx = (4 * w + 2) * 3;
        let bright_idx = (4 * w + 7) * 3;
        let dark_sum: u32 =
            rgb[dark_idx] as u32 + rgb[dark_idx + 1] as u32 + rgb[dark_idx + 2] as u32;
        let bright_sum: u32 =
            rgb[bright_idx] as u32 + rgb[bright_idx + 1] as u32 + rgb[bright_idx + 2] as u32;
        assert!(
            bright_sum > dark_sum * 10,
            "VNG must preserve the vertical-edge contrast: bright_sum={bright_sum} dark_sum={dark_sum}",
        );
    }
}
