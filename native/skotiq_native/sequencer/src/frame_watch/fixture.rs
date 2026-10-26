//! The rig night of 2026-10-23/24 (NGC 891, run 37): captured_images rows
//! 529-720 with each frame's measured HFR, star count, eccentricity, pointing
//! and the background plate solve the app logged for it.

use super::SolveOutcome;

/// NGC 891 as the plan had it.
pub(crate) const TARGET_RA_DEG: f64 = 2.375_947_222 * 15.0;
pub(crate) const TARGET_DEC_DEG: f64 = 42.349_138_9;
/// 3520 px at 0.79 arcsec/px.
pub(crate) const FIELD_SHORT_SIDE_ARCMIN: f64 = 3520.0 * 0.79 / 60.0;

#[derive(Debug, Clone)]
pub(crate) struct Row {
    pub(crate) id: u32,
    pub(crate) filter: String,
    pub(crate) exposure_secs: f64,
    pub(crate) hfr: Option<f64>,
    pub(crate) stars: Option<u32>,
    pub(crate) ecc: Option<f64>,
    pub(crate) alt: f64,
    pub(crate) az: f64,
    pub(crate) pier: String,
    pub(crate) db_accepted: bool,
    pub(crate) captured_at: f64,
    pub(crate) solve: SolveOutcome,
    pub(crate) db_reason: String,
}

pub(crate) fn rows() -> Vec<Row> {
    rows_from(include_str!("fixtures/ngc891_2026_10_24.csv"))
}

/// The rows of a fixture in the same format.
pub(crate) fn rows_from(csv: &str) -> Vec<Row> {
    csv.lines()
        .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
        .map(|line| {
            let f: Vec<&str> = line.split(',').collect();
            let opt = |s: &str| (!s.is_empty()).then(|| s.parse::<f64>().unwrap());
            let solve = match f[12] {
                "ok" => SolveOutcome::Solved {
                    ra_deg: f[13].parse().unwrap(),
                    dec_deg: f[14].parse().unwrap(),
                    pixel_scale_arcsec: f[15].parse().unwrap(),
                    rotation_deg: 0.0,
                },
                "fail" => SolveOutcome::Failed,
                _ => SolveOutcome::NotAttempted,
            };
            Row {
                id: f[0].parse().unwrap(),
                filter: f[2].to_string(),
                exposure_secs: f[3].parse().unwrap(),
                hfr: opt(f[4]),
                stars: opt(f[5]).map(|v| v as u32),
                ecc: opt(f[6]),
                alt: f[7].parse().unwrap(),
                az: f[8].parse().unwrap(),
                pier: f[9].to_string(),
                db_accepted: f[10] == "1",
                captured_at: f[11].parse().unwrap(),
                solve,
                db_reason: f.get(16).copied().unwrap_or("").to_string(),
            }
        })
        .collect()
}
