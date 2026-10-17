//! Synthetic frame generation for the simulator camera.
//!
//! The frame lives here, out of the `DriverType::Simulator` download arm, so it
//! can be run through the REAL star detector in a unit test. That matters more
//! than usual here: every focus, HFR and grading result an operator sees while
//! evaluating Skotiq without hardware is measured against this buffer, so if
//! it is not detectable-star-bearing, those subsystems silently report nothing
//! and the simulator quietly teaches the wrong thing.
//!
//! Two shapes the buffer must not take. An all-zero buffer is what
//! `[IMAGE_VALIDATION]` correctly rejects as a dead frame, so no simulated
//! sequence can run. A faint gradient plus four flat 6x6 blocks of 50,000 ADU
//! passes validation while the detector finds NONE of them (every frame logs
//! "no stars detected for HFR calculation", autofocus dies with "Insufficient
//! stars detected. Only 0 stars found (minimum: 10)", and the HFR-degradation /
//! focus-drift triggers have nothing to measure). Hence the Gaussian field
//! below, plus the tests that hold it to the detector's bar.
//!
//! A synthetic gradient is a defect in its own right: `200 + ((x+y)%400)` is a
//! diagonal sawtooth, not noise, and nothing about it moves when exposure, gain
//! or offset change — an 8 s / gain 0 frame and a 2 s / gain 120 frame come out
//! 99.7% bit-identical, spanning 442 of 65,536 ADU. Saturation, clipping, well
//! depth, calibration-frame quality and defect maps therefore cannot fire at
//! all, and subtracting such a frame as a master dark injects a diagonal ramp
//! into every calibrated light. The model below is instead built out of
//! electrons: a bias pedestal, dark current and sky that accumulate with
//! exposure, stars that accumulate only on light frames, shot and read noise,
//! and a hard clip at the sensor's advertised ceiling. Charge is collected
//! first and read out once, so binning sums WELLS rather than summing reads —
//! see [`read_out`] for what the other ordering costs.

use skotiq_native::camera::FrameType;

#[cfg(test)]
mod tests;

/// Simulated sensor dimensions.
///
/// This is THE sensor. `SimulatedCamera::default` and
/// `device_capabilities::get_simulator_capabilities` declare these same numbers,
/// so the frame a caller receives matches the geometry the camera advertised and
/// a measurement taken through one capture path is comparable with the other.
pub const SIM_W: usize = 1920;
pub const SIM_H: usize = 1080;

/// Full-well ceiling of the simulated sensor, in ADU.
pub const SIM_MAX_ADU: u16 = 65_535;

/// Focuser position at which simulated stars are sharpest.
///
/// Chosen to sit INSIDE the default autofocus sweep but off its centre. The
/// focuser starts at 25000 and the default sweep spans roughly +/-200 steps, so:
///   * putting true focus at the centre (25000) would let an algorithm that never
///     moved appear to succeed, and
///   * putting it at the edge (25200, tried first) gives the sweep a monotonic
///     slope instead of a V — the parabola fit then degenerates and autofocus
///     correctly refuses it with "curve fit R² 0.000 is below 0.700".
///
/// 25075 brackets the minimum on both sides while still requiring real movement.
pub const SIM_TRUE_FOCUS: i32 = 25_075;

const SIM_STAR_COUNT: usize = 45;
/// Sharpest achievable star sigma, in pixels.
const SIM_MIN_SIGMA: f64 = 1.6;
/// Sigma growth per focuser step away from [`SIM_TRUE_FOCUS`].
///
/// Sized so the DEFAULT autofocus sweep sees enough HFR spread to satisfy the
/// routine's `MIN_HFR_VARIANCE` V-curve check. At 0.0025 the sweep produced only
/// 0.68 of spread and autofocus correctly refused it ("No valid V-curve
/// detected"), which made the whole routine untestable against the simulator.
const SIM_SIGMA_PER_STEP: f64 = 0.006;

/// Electrons per second collected from the brightest star in the field.
///
/// Sized so a short exposure is well above the noise and a long one drives the
/// core past [`SIM_MAX_ADU`], which is what gives saturation handling and frame
/// grading something true to react to.
const SIM_STAR_E_PER_SEC: f64 = 45_000.0;
/// Sky background electrons per second per pixel.
const SIM_SKY_E_PER_SEC: f64 = 30.0;
/// Dark current electrons per second per pixel at the sensor's nominal setpoint.
const SIM_DARK_E_PER_SEC: f64 = 0.6;
/// Read noise in electrons RMS, drawn once per READ-OUT pixel — so a binned
/// pixel carries the same read noise as an unbinned one, which is the whole
/// reason binning buys SNR.
const SIM_READ_NOISE_E: f64 = 3.2;
/// Illumination electrons per second per pixel on a flat frame.
const SIM_FLAT_E_PER_SEC: f64 = 9_000.0;
/// ADU of bias pedestal contributed by one unit of the camera's offset setting.
const SIM_OFFSET_ADU_PER_UNIT: f64 = 50.0;
/// Peak vignetting loss at the corners of a flat, as a fraction.
const SIM_VIGNETTE_DEPTH: f64 = 0.28;
/// Exposure used by the parameterless convenience constructor.
pub const SIM_DEFAULT_EXPOSURE_SECS: f64 = 10.0;

/// Total electrons per second from the FAINTEST star rendered in a real-sky
/// field.
///
/// Anchoring on the faintest rather than on an absolute zero point is what
/// `tools/sim_fidelity/plate_solve_probe.py` proved out, and it is deliberate:
/// the field is truncated to the brightest [`SIM_SKY_STAR_LIMIT`], so the faint
/// end is set by the truncation, not by the sky. Pinning it to a known SNR makes
/// every field solvable at every focal length, and the true magnitude scale
/// above it means bright stars still bloom and saturate exactly as they should.
/// Sized so the faintest star peaks around 20x the sky noise at the default 10 s
/// exposure and stays detectable down to about 1 s.
const SIM_SKY_FAINT_E_PER_SEC: f64 = 650.0;

/// How many catalogue stars a real-sky frame renders, brightest first.
pub const SIM_SKY_STAR_LIMIT: usize = 1500;

/// Extra field radius requested beyond the sensor's half-diagonal, so a star
/// just outside the corner still contributes its wings.
const SIM_SKY_RADIUS_MARGIN: f64 = 1.15;

/// A pointing to render instead of the pseudo-random field: the sky the mount
/// says it is looking at, projected onto the sensor.
#[derive(Debug, Clone)]
pub struct SimSkyView {
    pub centre_ra_deg: f64,
    pub centre_dec_deg: f64,
    /// Rotator angle, degrees, applied about the sensor centre.
    pub rotation_deg: f64,
    /// Unbinned plate scale. Binning is applied later, by [`read_out`], because
    /// charge is collected at sensor resolution.
    pub arcsec_per_px: f64,
    pub stars: Vec<crate::sim_sky::SkyStar>,
}

/// Everything the simulated sensor needs to produce one frame.
#[derive(Debug, Clone)]
pub struct SimFrameRequest {
    pub width: usize,
    pub height: usize,
    pub exposure_secs: f64,
    pub gain: i32,
    pub offset: i32,
    pub frame_type: FrameType,
    pub focus_position: Option<i32>,
    pub offset_x: f64,
    pub offset_y: f64,
    pub bin_x: u32,
    pub bin_y: u32,
    pub subframe: Option<(u32, u32, u32, u32)>,
    pub max_adu: u16,
    /// Seed for the per-frame noise draw. The star field itself is keyed off a
    /// separate fixed seed, so a given seed reproduces a given frame exactly
    /// while successive frames still differ the way real reads do.
    pub seed: u64,
    /// When set, paint the real sky at this pointing instead of the pseudo-random
    /// field. `None` is the default and keeps that field bit-for-bit stable —
    /// see [`add_stars`] for why that matters to the sim's own test suite.
    pub sky: Option<SimSkyView>,
}

impl Default for SimFrameRequest {
    fn default() -> Self {
        Self {
            width: SIM_W,
            height: SIM_H,
            exposure_secs: SIM_DEFAULT_EXPOSURE_SECS,
            gain: 0,
            offset: 10,
            frame_type: FrameType::Light,
            focus_position: Some(SIM_TRUE_FOCUS),
            offset_x: 0.0,
            offset_y: 0.0,
            bin_x: 1,
            bin_y: 1,
            subframe: None,
            max_adu: SIM_MAX_ADU,
            seed: 0,
            sky: None,
        }
    }
}

/// Dimensions of the buffer [`synthesize_sim_frame`] will return for `request`.
pub fn sim_frame_dimensions(request: &SimFrameRequest) -> (u32, u32) {
    let (_, _, w, h) = resolved_region(request);
    (
        (w / request.bin_x.max(1)).max(1),
        (h / request.bin_y.max(1)).max(1),
    )
}

fn resolved_region(request: &SimFrameRequest) -> (u32, u32, u32, u32) {
    let sensor_w = request.width as u32;
    let sensor_h = request.height as u32;
    match request.subframe {
        Some((x, y, w, h)) => {
            let x = x.min(sensor_w.saturating_sub(1));
            let y = y.min(sensor_h.saturating_sub(1));
            (x, y, w.clamp(1, sensor_w - x), h.clamp(1, sensor_h - y))
        }
        None => (0, 0, sensor_w, sensor_h),
    }
}

/// ADU produced per electron at a given gain setting.
fn adu_per_electron(gain: i32) -> f64 {
    0.25 * (1.0 + f64::from(gain.max(0)) / 100.0)
}

/// Star sigma (pixels) for a given focuser position.
pub fn sim_star_sigma(focus_position: Option<i32>) -> f64 {
    // A camera-only rig has no focuser to defocus it: treat that as in-focus so
    // plain capture tests still get sharp stars.
    let position = focus_position.unwrap_or(SIM_TRUE_FOCUS);
    let defocus = (position - SIM_TRUE_FOCUS).abs() as f64;
    SIM_MIN_SIGMA + defocus * SIM_SIGMA_PER_STEP
}

struct Lcg(u64);

impl Lcg {
    fn new(seed: u64) -> Self {
        Self(seed ^ 0x9E37_79B9_7F4A_7C15)
    }

    fn next_f64(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        (self.0 >> 33) as f64 / (1u64 << 31) as f64
    }

    /// Unit-variance zero-mean draw. Irwin-Hall over four uniforms: cheap enough
    /// to run per pixel on a full sensor and close enough to Gaussian for a
    /// noise floor.
    fn next_normal(&mut self) -> f64 {
        let sum = self.next_f64() + self.next_f64() + self.next_f64() + self.next_f64();
        (sum - 2.0) * 1.732_050_807_568_877_2
    }
}

/// Build the simulator's synthetic frame for `request`.
///
/// Two stages, in the order a real sensor does them: collect charge over the
/// whole exposure, then read that charge out once. Binning happens between the
/// two because on-chip binning sums CHARGE and reads the sum through a single
/// amplifier — see [`read_out`] for what went wrong while the read was folded
/// into the collection step.
pub fn synthesize_sim_frame(request: &SimFrameRequest) -> Vec<u16> {
    let (region_x, region_y, region_w, region_h) = resolved_region(request);
    // One RNG for the whole frame: shot noise is drawn per SENSOR pixel and read
    // noise per OUTPUT pixel, so both have to come off the same seeded stream to
    // keep a given seed reproducing a given frame.
    let mut noise = Lcg::new(request.seed);
    let electrons = collect_electrons(request, region_x, region_y, region_w, region_h, &mut noise);
    read_out(
        &electrons,
        region_w as usize,
        region_h as usize,
        request,
        &mut noise,
    )
}

/// Charge collected in each SENSOR pixel of the region, in electrons.
///
/// Shot noise belongs here rather than in the read: it is already in the well
/// when the charge is summed, so binning correctly adds it in quadrature. The
/// pedestal and read noise are not — they arrive once, at the amplifier.
fn collect_electrons(
    request: &SimFrameRequest,
    region_x: u32,
    region_y: u32,
    region_w: u32,
    region_h: u32,
    noise: &mut Lcg,
) -> Vec<f64> {
    let width = region_w as usize;
    let height = region_h as usize;
    let exposure = request.exposure_secs.max(0.0);
    let frame_type = request.frame_type;

    // A bias frame is a zero-length read: no dark current, no sky, no light.
    let integrating = !matches!(frame_type, FrameType::Bias);
    let effective_exposure = if integrating { exposure } else { 0.0 };
    let collects_sky = matches!(frame_type, FrameType::Light);
    let collects_stars = collects_sky;
    let is_flat = matches!(frame_type, FrameType::Flat);

    let dark_e = SIM_DARK_E_PER_SEC * effective_exposure;
    let sky_e = if collects_sky {
        SIM_SKY_E_PER_SEC * effective_exposure
    } else {
        0.0
    };

    let mut signal = vec![0.0f64; width * height];

    let sensor_w = request.width as f64;
    let sensor_h = request.height as f64;
    let centre_x = sensor_w / 2.0;
    let centre_y = sensor_h / 2.0;
    let max_radius_sq = centre_x * centre_x + centre_y * centre_y;

    for y in 0..height {
        let sensor_row_y = (region_y as usize + y) as f64;
        for x in 0..width {
            let sensor_col_x = (region_x as usize + x) as f64;
            let mut e = dark_e + sky_e;
            if is_flat {
                let dx = sensor_col_x - centre_x;
                let dy = sensor_row_y - centre_y;
                let vignette = 1.0 - SIM_VIGNETTE_DEPTH * (dx * dx + dy * dy) / max_radius_sq;
                e += SIM_FLAT_E_PER_SEC * effective_exposure * vignette;
            }
            signal[y * width + x] = e;
        }
    }

    if collects_stars {
        match &request.sky {
            Some(sky) => add_sky_stars(
                &mut signal,
                request,
                sky,
                region_x,
                region_y,
                region_w,
                region_h,
                effective_exposure,
            ),
            None => add_stars(
                &mut signal,
                request,
                region_x,
                region_y,
                region_w,
                region_h,
                effective_exposure,
            ),
        }
    }

    for value in signal.iter_mut() {
        let electrons = *value;
        *value = electrons + noise.next_normal() * electrons.max(0.0).sqrt();
    }

    signal
}

#[allow(clippy::too_many_arguments)]
fn add_stars(
    signal: &mut [f64],
    request: &SimFrameRequest,
    region_x: u32,
    region_y: u32,
    region_w: u32,
    region_h: u32,
    exposure: f64,
) {
    let sigma = sim_star_sigma(request.focus_position);
    let two_sigma_sq = 2.0 * sigma * sigma;
    let peak_e = SIM_STAR_E_PER_SEC * exposure / (std::f64::consts::TAU * sigma * sigma);
    if peak_e <= 0.0 {
        return;
    }
    let radius = (3.0 * sigma).ceil() as isize;
    let width = region_w as isize;
    let height = region_h as isize;

    // Fixed-seed LCG: the field is identical run to run, so tests can assert on
    // star counts and HFR without tolerating a reshuffled field. Only the noise
    // draw varies between frames.
    let mut field = Lcg::new(0x5EED_1234_ABCD_0001);

    for _ in 0..SIM_STAR_COUNT {
        // Inset from the edges so every star's full profile fits on the sensor.
        // The mount offset is added AFTER the inset so the field translates as a
        // rigid body: a star near the edge can clip off-sensor under a large
        // offset, exactly as it would on a real drifting mount (the per-pixel
        // bounds check below handles that).
        let margin = radius as f64 + 2.0;
        let sensor_cx =
            margin + field.next_f64() * (request.width as f64 - 2.0 * margin) + request.offset_x;
        let sensor_cy =
            margin + field.next_f64() * (request.height as f64 - 2.0 * margin) + request.offset_y;
        // Some brightness spread, so the detector sees a realistic magnitude
        // range rather than 45 identical stars.
        let star_peak = peak_e * (0.45 + 0.55 * field.next_f64());

        let cx = sensor_cx - f64::from(region_x);
        let cy = sensor_cy - f64::from(region_y);
        let cxi = cx as isize;
        let cyi = cy as isize;
        for dy in -radius..=radius {
            for dx in -radius..=radius {
                let px = cxi + dx;
                let py = cyi + dy;
                if px < 0 || py < 0 || px >= width || py >= height {
                    continue;
                }
                let r_sq = (px as f64 - cx).powi(2) + (py as f64 - cy).powi(2);
                let value = star_peak * (-r_sq / two_sigma_sq).exp();
                if value < 1.0 {
                    continue;
                }
                signal[py as usize * region_w as usize + px as usize] += value;
            }
        }
    }
}

/// Smallest `cos` of the angular distance from the tangent point that still
/// projects. Guards the gnomonic divide, which blows up at 90 degrees and
/// mirrors the sky onto the frame beyond it.
const TAN_HORIZON: f64 = 0.05;

/// Field radius, in degrees, that covers a sensor at a given plate scale.
///
/// The half-diagonal plus a margin, so a star just outside a corner still lands
/// its wings on the sensor.
pub fn sim_sky_field_radius_deg(width: usize, height: usize, arcsec_per_px: f64) -> f64 {
    let w_deg = width as f64 * arcsec_per_px / 3600.0;
    let h_deg = height as f64 * arcsec_per_px / 3600.0;
    w_deg.hypot(h_deg) / 2.0 * SIM_SKY_RADIUS_MARGIN
}

/// Gnomonic (TAN) projection of one catalogue star onto the simulated sensor.
///
/// Returns full-sensor pixel coordinates with the origin at the top-left corner,
/// before the subframe origin or the mount's guide offset are applied. `None`
/// when the star is too far from the tangent point to project.
///
/// TAN because that is the projection ASTAP writes into the WCS it solves for,
/// so a frame rendered this way and then solved is being measured against its
/// own geometry rather than against an approximation of it.
pub fn project_star(
    sky: &SimSkyView,
    sensor_w: f64,
    sensor_h: f64,
    star: &crate::sim_sky::SkyStar,
) -> Option<(f64, f64)> {
    let scale_rad = (sky.arcsec_per_px / 3600.0).to_radians();
    if !scale_rad.is_finite() || scale_rad <= 0.0 {
        return None;
    }
    let (sin_dec0, cos_dec0) = sky.centre_dec_deg.to_radians().sin_cos();
    let (sin_dec, cos_dec) = star.dec_deg.to_radians().sin_cos();
    let (sin_dra, cos_dra) = (star.ra_deg - sky.centre_ra_deg).to_radians().sin_cos();

    let cos_c = sin_dec0 * sin_dec + cos_dec0 * cos_dec * cos_dra;
    if cos_c <= TAN_HORIZON {
        return None;
    }
    // Standard coordinates about the tangent point, in radians on the sky.
    let xi = cos_dec * sin_dra / cos_c;
    let eta = (cos_dec0 * sin_dec - sin_dec0 * cos_dec * cos_dra) / cos_c;

    // RA increases to the LEFT of a sky-side-up frame and north (+eta) is up,
    // while raster rows run downward — so both standard coordinates negate on
    // the way into pixels.
    let px = -xi / scale_rad;
    let py = -eta / scale_rad;
    let (sin_rot, cos_rot) = sky.rotation_deg.to_radians().sin_cos();
    Some((
        sensor_w / 2.0 + px * cos_rot - py * sin_rot,
        sensor_h / 2.0 + px * sin_rot + py * cos_rot,
    ))
}

/// Paint the catalogue field described by `sky` into the collected charge.
///
/// Everything downstream of this is shared with the pseudo-random field: shot
/// noise, the read, the offset pedestal and the well clip are all applied by
/// [`collect_electrons`] and [`read_out`] afterwards, and the PSF width still
/// comes from [`sim_star_sigma`], so a real-sky frame defocuses on the focuser
/// and saturates at the ceiling exactly like the pseudo-random field.
///
/// No RNG runs here: a given pointing and star list render a given frame, and
/// only the seeded noise draw varies between frames.
#[allow(clippy::too_many_arguments)]
fn add_sky_stars(
    signal: &mut [f64],
    request: &SimFrameRequest,
    sky: &SimSkyView,
    region_x: u32,
    region_y: u32,
    region_w: u32,
    region_h: u32,
    exposure: f64,
) {
    let sigma = sim_star_sigma(request.focus_position);
    let two_sigma_sq = 2.0 * sigma * sigma;
    // Peak electrons per electron/second of total flux.
    let unit_peak = exposure / (std::f64::consts::TAU * sigma * sigma);
    if unit_peak <= 0.0 {
        return;
    }
    // Four sigma, where the pseudo-random field uses three: a catalogue field is
    // dominated by stars near the detection floor, and clipping their wings a
    // sigma early costs exactly the flux the solver centroids on.
    let radius = (4.0 * sigma).ceil() as isize;

    let sensor_w = request.width as f64;
    let sensor_h = request.height as f64;
    let margin = radius as f64 + 2.0;

    let mut placed: Vec<(f64, f64, f64)> = Vec::with_capacity(sky.stars.len());
    for star in &sky.stars {
        let Some((x, y)) = project_star(sky, sensor_w, sensor_h, star) else {
            continue;
        };
        // The guide offset rides on top of the pointing: the simulated mount
        // accumulates guide-pulse and drift displacement that its reported
        // RA/Dec does not carry, so without this the built-in guider would see
        // its own pulses move nothing.
        let x = x + request.offset_x;
        let y = y + request.offset_y;
        if x < -margin || y < -margin || x > sensor_w + margin || y > sensor_h + margin {
            continue;
        }
        placed.push((x, y, star.mag));
    }
    if placed.is_empty() {
        return;
    }

    // Anchor the brightness scale on the faintest star that landed — see
    // [`SIM_SKY_FAINT_E_PER_SEC`]. Above that anchor the TRUE magnitude scale
    // applies, so the bright end blooms and saturates on its own.
    let faintest = placed
        .iter()
        .map(|(_, _, mag)| *mag)
        .fold(f64::MIN, f64::max);
    let faint_peak_e = SIM_SKY_FAINT_E_PER_SEC * unit_peak;

    let width = region_w as isize;
    let height = region_h as isize;
    for (sensor_cx, sensor_cy, mag) in placed {
        let peak_e = faint_peak_e * 10f64.powf(0.4 * (faintest - mag));
        let cx = sensor_cx - f64::from(region_x);
        let cy = sensor_cy - f64::from(region_y);
        let cxi = cx.round() as isize;
        let cyi = cy.round() as isize;
        for dy in -radius..=radius {
            let py = cyi + dy;
            if py < 0 || py >= height {
                continue;
            }
            for dx in -radius..=radius {
                let px = cxi + dx;
                if px < 0 || px >= width {
                    continue;
                }
                let r_sq = (px as f64 - cx).powi(2) + (py as f64 - cy).powi(2);
                let value = peak_e * (-r_sq / two_sigma_sq).exp();
                if value < 1.0 {
                    continue;
                }
                signal[py as usize * region_w as usize + px as usize] += value;
            }
        }
    }
}

/// Read the collected charge out: sum `bin_x` x `bin_y` blocks the way a real
/// sensor sums charge on chip, then apply ONE read per output pixel — one read
/// noise draw and one offset pedestal — and clip at the ADC ceiling.
///
/// The ordering is the whole point. Applying the pedestal and the read noise
/// per sensor pixel and then summing them in the binning loop scales both with
/// bin area: a bias frame reads 499.5 ADU at bin 1 but 1999.5 ADU at bin 2, and
/// read noise grows by sqrt(bin area) instead of staying put. No camera behaves
/// that way — the offset is injected once at the amplifier — so a bias or dark
/// master captured binned would sit four pedestals high, calibration that
/// subtracts an unbinned master from a binned light would be wrong by 1500 ADU,
/// and any offset-derived check that passes against the simulator passes for a
/// reason the hardware does not share.
fn read_out(
    electrons: &[f64],
    width: usize,
    height: usize,
    request: &SimFrameRequest,
    noise: &mut Lcg,
) -> Vec<u16> {
    let bin_x = request.bin_x.max(1) as usize;
    let bin_y = request.bin_y.max(1) as usize;
    let out_w = (width / bin_x).max(1);
    let out_h = (height / bin_y).max(1);
    let adu_per_e = adu_per_electron(request.gain);
    let pedestal = f64::from(request.offset.max(0)) * SIM_OFFSET_ADU_PER_UNIT;
    let ceiling = f64::from(request.max_adu);
    let mut out = vec![0u16; out_w * out_h];

    for oy in 0..out_h {
        for ox in 0..out_w {
            let mut charge = 0.0;
            for by in 0..bin_y {
                let sy = oy * bin_y + by;
                if sy >= height {
                    continue;
                }
                for bx in 0..bin_x {
                    let sx = ox * bin_x + bx;
                    if sx >= width {
                        continue;
                    }
                    charge += electrons[sy * width + sx];
                }
            }
            let read = noise.next_normal() * SIM_READ_NOISE_E;
            out[oy * out_w + ox] =
                (pedestal + (charge + read) * adu_per_e).clamp(0.0, ceiling) as u16;
        }
    }
    out
}

/// Build a default light frame with the star field translated by
/// `(offset_x, offset_y)` pixels.
///
/// The offset is what makes guiding exercisable without a mount: the simulated
/// mount accumulates guide-pulse and drift displacement (see
/// `api::devices::simulation::sim_guide_offset_px`) and passes it here, so the
/// built-in guider sees its own pulses move the stars. Without it every
/// calibration attempt died on "Calibration response on east axis was too small
/// (0.000px)" — the pulse op returned `Ok` but nothing moved — which made
/// calibration, closed-loop correction and dithering untestable offline.
#[cfg(test)]
pub fn synthesize_sim_frame_with_offset(
    focus_position: Option<i32>,
    offset_x: f64,
    offset_y: f64,
) -> Vec<u16> {
    synthesize_sim_frame(&SimFrameRequest {
        focus_position,
        offset_x,
        offset_y,
        ..SimFrameRequest::default()
    })
}
