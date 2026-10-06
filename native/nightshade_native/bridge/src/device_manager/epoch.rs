//! J2000 → mean-of-date ("JNOW") coordinate conversion for the mount
//! boundary.
//!
//! Every catalog, plate solver, and internal coordinate in Nightshade is
//! J2000/ICRS, but GOTO mounts overwhelmingly expect apparent/topocentric
//! coordinates of date: ASCOM mounts default to `equTopocentric`, the INDI
//! `EQUATORIAL_EOD_COORD` property is JNOW by definition, and native
//! LX200-protocol mounts are JNOW. Sending raw J2000 to a JNOW mount lands
//! the initial GOTO ~50.3″ × (years since 2000) off — about 22′ in 2026 —
//! which closed-loop centering then has to claw back with an extra
//! solve/sync iteration (and a raw slew without centering simply misses).
//!
//! Scope deliberately limited to **precession** (IAU 1976 / Meeus ch. 21):
//! nutation (≤ 17″) and annual aberration (≤ 20.5″) are an order of
//! magnitude below the dominant term and well inside every mount's pointing
//! noise; plate-solve centering owns the last arcminute regardless.
//!
//! Direction policy: only coordinates SENT to the mount (slew / sync) are
//! converted. Coordinates READ from the mount stay in the mount's native
//! frame, exactly as before — the trigger monitor's hour-angle math
//! (HA = LST − RA_of_date) is only correct with of-date RA, and the
//! conversion of inputs alone keeps the mount's internal pointing model in
//! a single consistent frame.

/// Julian centuries of TT since J2000.0 for a given Julian day.
fn centuries_since_j2000(jd: f64) -> f64 {
    (jd - 2451545.0) / 36525.0
}

/// Precess J2000.0 equatorial coordinates to mean-of-date at Julian day
/// [`jd`]. RA in hours, Dec in degrees; returns (ra_hours, dec_degrees).
///
/// Meeus, *Astronomical Algorithms* 2nd ed., eq. 21.3 + 21.4 (the rigorous
/// rotation, not the annual-rate approximation — exact at any epoch
/// separation and stable at the pole).
pub fn precess_j2000_to_jd(ra_hours: f64, dec_deg: f64, jd: f64) -> (f64, f64) {
    let t = centuries_since_j2000(jd);

    // Precession angles in arcseconds (eq. 21.3 with J2000 start epoch).
    let zeta = (2306.2181 + (0.30188 + 0.017998 * t) * t) * t;
    let z = (2306.2181 + (1.09468 + 0.018203 * t) * t) * t;
    let theta = (2004.3109 - (0.42665 + 0.041833 * t) * t) * t;

    let arcsec = std::f64::consts::PI / (180.0 * 3600.0);
    let zeta = zeta * arcsec;
    let z = z * arcsec;
    let theta = theta * arcsec;

    let ra0 = ra_hours * 15.0_f64.to_radians();
    let dec0 = dec_deg.to_radians();

    // Eq. 21.4.
    let a = dec0.cos() * (ra0 + zeta).sin();
    let b = theta.cos() * dec0.cos() * (ra0 + zeta).cos() - theta.sin() * dec0.sin();
    let c = theta.sin() * dec0.cos() * (ra0 + zeta).cos() + theta.cos() * dec0.sin();

    let ra = z + a.atan2(b);
    let dec = c.asin();

    let mut ra_hours_out = ra.to_degrees() / 15.0;
    ra_hours_out = ra_hours_out.rem_euclid(24.0);
    (ra_hours_out, dec.to_degrees())
}

/// Precess J2000.0 coordinates to mean-of-date **now**.
pub fn j2000_to_jnow(ra_hours: f64, dec_deg: f64) -> (f64, f64) {
    let jd = nightshade_sequencer::meridian::julian_day(&chrono::Utc::now());
    precess_j2000_to_jd(ra_hours, dec_deg, jd)
}

/// Precess mean-of-date coordinates at Julian day [`jd`] back to J2000.0 —
/// the exact inverse of [`precess_j2000_to_jd`] (the same three rotations,
/// applied in reverse order with their signs flipped).
pub fn precess_jd_to_j2000(ra_hours: f64, dec_deg: f64, jd: f64) -> (f64, f64) {
    let t = centuries_since_j2000(jd);

    let zeta = (2306.2181 + (0.30188 + 0.017998 * t) * t) * t;
    let z = (2306.2181 + (1.09468 + 0.018203 * t) * t) * t;
    let theta = (2004.3109 - (0.42665 + 0.041833 * t) * t) * t;

    let arcsec = std::f64::consts::PI / (180.0 * 3600.0);
    let zeta = zeta * arcsec;
    let z = z * arcsec;
    let theta = theta * arcsec;

    let ra = ra_hours * 15.0_f64.to_radians();
    let dec = dec_deg.to_radians();

    let a = dec.cos() * (ra - z).sin();
    let b = theta.cos() * dec.cos() * (ra - z).cos() + theta.sin() * dec.sin();
    let c = -theta.sin() * dec.cos() * (ra - z).cos() + theta.cos() * dec.sin();

    let ra0 = a.atan2(b) - zeta;
    let dec0 = c.asin();

    (
        (ra0.to_degrees() / 15.0).rem_euclid(24.0),
        dec0.to_degrees(),
    )
}

/// Precess mean-of-date coordinates **now** back to J2000.0.
pub fn jnow_to_j2000(ra_hours: f64, dec_deg: f64) -> (f64, f64) {
    let jd = nightshade_sequencer::meridian::julian_day(&chrono::Utc::now());
    precess_jd_to_j2000(ra_hours, dec_deg, jd)
}

/// The coordinate frame the SIMULATED mount keeps, accepts and reports.
///
/// Real GOTO mounts speak coordinates of date (see the module note), so the
/// device layer precesses what it sends to them and reads back of-date
/// positions. The simulator used to be exempt from both halves and stored raw
/// J2000, which made it the one mount on which a J2000 target and a read-back
/// were the same number. Every place that compared or re-sent one as the other
/// therefore passed on the simulator and failed on the rig — on 2026-09-14
/// every sequence with a target died 1.5 s in because slew validation compared
/// a J2000 target with an of-date read-back, and no simulator run could show it.
///
/// So the simulator is a JNow mount by default. `NIGHTSHADE_SIM_MOUNT_FRAME=j2000`
/// restores the old behaviour for a run that needs catalog numbers to
/// round-trip through the mount unchanged.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SimMountFrame {
    /// Mean-of-date, like an ASCOM topocentric, INDI EOD, OnStep or LX200 mount.
    OfDate,
    /// Raw J2000: what is sent is what is stored and read back.
    J2000,
}

/// Environment switch for [`SimMountFrame`].
pub const SIM_MOUNT_FRAME_ENV: &str = "NIGHTSHADE_SIM_MOUNT_FRAME";

const FRAME_UNRESOLVED: u8 = 0;
const FRAME_OF_DATE: u8 = 1;
const FRAME_J2000: u8 = 2;

static SIM_MOUNT_FRAME: std::sync::atomic::AtomicU8 =
    std::sync::atomic::AtomicU8::new(FRAME_UNRESOLVED);

/// Parse the environment value; `None` for anything unrecognized.
fn parse_sim_mount_frame(value: &str) -> Option<SimMountFrame> {
    match value.trim().to_ascii_lowercase().as_str() {
        "" | "jnow" | "of-date" | "ofdate" | "of_date" => Some(SimMountFrame::OfDate),
        "j2000" | "icrs" => Some(SimMountFrame::J2000),
        _ => None,
    }
}

/// The simulated mount's frame, read once from [`SIM_MOUNT_FRAME_ENV`].
pub fn sim_mount_frame() -> SimMountFrame {
    use std::sync::atomic::Ordering;
    match SIM_MOUNT_FRAME.load(Ordering::Relaxed) {
        FRAME_OF_DATE => return SimMountFrame::OfDate,
        FRAME_J2000 => return SimMountFrame::J2000,
        _ => {}
    }
    let frame = match std::env::var(SIM_MOUNT_FRAME_ENV) {
        Err(_) => SimMountFrame::OfDate,
        Ok(value) => parse_sim_mount_frame(&value).unwrap_or_else(|| {
            // A typo must not quietly hand back a frame nobody asked for; say
            // so and keep the real-mount behaviour.
            tracing::error!(
                "{}={:?} is not a frame (use jnow or j2000); the simulated mount stays of-date",
                SIM_MOUNT_FRAME_ENV,
                value
            );
            SimMountFrame::OfDate
        }),
    };
    set_sim_mount_frame(frame);
    frame
}

/// Pin the simulated mount's frame, overriding the environment.
pub fn set_sim_mount_frame(frame: SimMountFrame) {
    let raw = match frame {
        SimMountFrame::OfDate => FRAME_OF_DATE,
        SimMountFrame::J2000 => FRAME_J2000,
    };
    SIM_MOUNT_FRAME.store(raw, std::sync::atomic::Ordering::Relaxed);
}

/// Pins the simulated mount's frame for one test and restores the previous
/// frame when dropped. Hold the simulator singleton lock alongside it: the
/// frame is process-wide, like the simulated mount itself.
#[cfg(test)]
pub(crate) struct SimFrameGuard(SimMountFrame);

#[cfg(test)]
impl SimFrameGuard {
    pub(crate) fn pin(frame: SimMountFrame) -> Self {
        let previous = sim_mount_frame();
        set_sim_mount_frame(frame);
        Self(previous)
    }
}

#[cfg(test)]
impl Drop for SimFrameGuard {
    fn drop(&mut self) {
        set_sim_mount_frame(self.0);
    }
}

/// Whether a mount on this driver keeps coordinates of date.
///
/// The single decision behind the send path (`mount_slew`, `mount_sync`) and
/// the read-back comparison (`DeviceOps::mount_readback_frame`), so the two
/// cannot disagree. Every real driver does; the simulator does unless pinned
/// to J2000.
pub fn mount_frame_is_of_date(driver_type: crate::device::DriverType) -> bool {
    match driver_type {
        crate::device::DriverType::Simulator => sim_mount_frame() == SimMountFrame::OfDate,
        _ => true,
    }
}

/// Express J2000 coordinates in the frame a mount on `driver_type` speaks.
pub fn j2000_to_mount_frame(
    driver_type: crate::device::DriverType,
    ra_hours: f64,
    dec_deg: f64,
) -> (f64, f64) {
    if mount_frame_is_of_date(driver_type) {
        j2000_to_jnow(ra_hours, dec_deg)
    } else {
        (ra_hours, dec_deg)
    }
}

/// Express a mount read-back from `driver_type` in J2000.
pub fn mount_frame_to_j2000(
    driver_type: crate::device::DriverType,
    ra_hours: f64,
    dec_deg: f64,
) -> (f64, f64) {
    if mount_frame_is_of_date(driver_type) {
        jnow_to_j2000(ra_hours, dec_deg)
    } else {
        (ra_hours, dec_deg)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Meeus example 21.b: θ Persei. After proper motion to the target
    /// epoch the J2000 place is α = 2h44m12.975s, δ = +49°13′39.90″;
    /// precessing to JD 2462088.69 (2028 Nov 13.19 TD) must give
    /// α = 2h46m11.331s, δ = +49°20′54.54″.
    #[test]
    fn meeus_example_21b() {
        let ra0 = 2.0 + 44.0 / 60.0 + 12.975 / 3600.0;
        let dec0 = 49.0 + 13.0 / 60.0 + 39.90 / 3600.0;
        let (ra, dec) = precess_j2000_to_jd(ra0, dec0, 2462088.69);

        let ra_expected = 2.0 + 46.0 / 60.0 + 11.331 / 3600.0;
        let dec_expected = 49.0 + 20.0 / 60.0 + 54.54 / 3600.0;

        // 0.1 s of RA ≈ 1.5″; 0.05″ in Dec. Generous but sub-arcsecond.
        assert!(
            (ra - ra_expected).abs() * 3600.0 < 0.1,
            "RA {} vs expected {}",
            ra,
            ra_expected
        );
        assert!(
            (dec - dec_expected).abs() * 3600.0 < 0.5,
            "Dec {} vs expected {}",
            dec,
            dec_expected
        );
    }

    /// At J2000 the transform must be the identity.
    #[test]
    fn identity_at_j2000() {
        let (ra, dec) = precess_j2000_to_jd(5.5, -20.25, 2451545.0);
        assert!((ra - 5.5).abs() < 1e-9);
        assert!((dec + 20.25).abs() < 1e-9);
    }

    /// The reverse precession undoes the forward one to far under an
    /// arcsecond, across the sky and next to both poles.
    #[test]
    fn reverse_precession_round_trips() {
        let jd = 2461309.5; // 2026-09-26
        for &(ra, dec) in &[
            (0.0, 0.0),
            (5.5, -20.25),
            (22.7892, 58.1324),
            (23.999, 0.0),
            (12.0, 89.9),
            (18.0, -89.5),
        ] {
            let (ra_now, dec_now) = precess_j2000_to_jd(ra, dec, jd);
            let (ra_back, dec_back) = precess_jd_to_j2000(ra_now, dec_now, jd);
            let mut dra = (ra_back - ra).rem_euclid(24.0);
            if dra > 12.0 {
                dra -= 24.0;
            }
            let err_arcsec = (dra * 15.0 * dec.to_radians().cos()).hypot(dec_back - dec) * 3600.0;
            assert!(
                err_arcsec < 0.01,
                "({ra}, {dec}) came back {err_arcsec}\" off"
            );
        }
    }

    /// The owner's OnStep measurement on 2026-09-14: NGC7380 at J2000
    /// 22.7892h/58.1324deg was commanded as 22.8070h/58.2738deg of date.
    #[test]
    fn onstep_ngc7380_reference() {
        let jd = 2461298.5; // 2026-09-15
        let (ra, dec) = precess_j2000_to_jd(22.7892, 58.1324, jd);
        assert!((ra - 22.8070).abs() < 0.0005, "ra={ra}");
        assert!((dec - 58.2738).abs() < 0.001, "dec={dec}");
    }

    #[test]
    fn sim_frame_environment_values() {
        assert_eq!(parse_sim_mount_frame("jnow"), Some(SimMountFrame::OfDate));
        assert_eq!(parse_sim_mount_frame(" J2000 "), Some(SimMountFrame::J2000));
        assert_eq!(parse_sim_mount_frame(""), Some(SimMountFrame::OfDate));
        assert_eq!(parse_sim_mount_frame("b1950"), None);
    }

    /// RA must stay normalized across the 0h/24h wrap.
    #[test]
    fn ra_wraps_at_24h() {
        let (ra, _) = precess_j2000_to_jd(23.999, 0.0, 2461041.5); // ~2026
        assert!((0.0..24.0).contains(&ra), "ra={ra}");
    }
}
