//! Real-sky star source for the simulator camera.
//!
//! Why this exists
//! ---------------
//! [`crate::sim_frame`] paints a pseudo-random Gaussian field and translates it
//! as a rigid body with the mount's guide offset. It does not render the sky the
//! mount is pointing at. Plate solving is NOT special-cased for the simulator —
//! [`crate::api::plate_solve`] shells out to the real ASTAP binary — so under the
//! simulator every plate-solve-dependent feature was unexercisable without
//! hardware: Slew & Center, the centering dialog, the framing wizard, mosaic tile
//! solving, meridian-flip recentre, blind solve, the catalog overlay (which needs
//! a WCS), the plate-solving settings Test button, and polar alignment's solve
//! path.
//!
//! This module reads ASTAP's OWN star database — the `catalog_path` of the
//! persisted plate-solver preference, i.e. the very catalogue the solver will
//! match against — so the simulated sky and the solver cannot disagree by
//! construction. `tools/sim_fidelity/plate_solve_probe.py` is the reference
//! implementation this is a port of, and its measured result on ASTAP's D05 set
//! is a solved centre inside one pixel at 1000mm, 400mm, 200mm and 135mm.
//!
//! Catalogue depth is the limiter, not the projection. Rendered from the app's
//! bundled HYG catalogue (2.9 stars/deg^2) a 400mm field holds 6 stars and ASTAP
//! aborts with "Only 4 stars found in image"; rendered from D05 (500 stars/deg^2)
//! the same field holds 300+ and solves. That is the whole reason this reads the
//! solver's database rather than any catalogue the app already ships.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock, RwLock};

use rayon::prelude::*;

/// Record size, in bytes, of the `.1476` record format this parser understands.
const RECORD_FORMAT_5: u8 = 5;
/// Length of the fixed text header that precedes the records.
const HEADER_LEN: usize = 110;
/// Offset within the header of the byte declaring the record size.
const HEADER_RECORD_SIZE_OFFSET: usize = 109;

/// Declination is stored in 23 bits spanning +/-90 degrees.
const DEC_SCALE: f64 = 90.0 / (128.0 * 256.0 * 256.0 - 1.0);
/// Right ascension is stored in 24 bits spanning 24 hours.
const RA_SCALE_HOURS: f64 = 24.0 / (256.0 * 256.0 * 256.0 - 1.0);

/// A catalogue star, in the equinox the database is built on (J2000 for ASTAP's
/// Gaia-derived sets).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SkyStar {
    pub ra_deg: f64,
    pub dec_deg: f64,
    pub mag: f64,
}

/// A cone on the sky: everything within `radius_deg` of a direction.
#[derive(Debug, Clone, Copy)]
pub struct Cone {
    ra_deg: f64,
    dec_deg: f64,
    radius_deg: f64,
}

impl Cone {
    pub fn new(ra_deg: f64, dec_deg: f64, radius_deg: f64) -> Self {
        Self {
            ra_deg,
            dec_deg,
            radius_deg,
        }
    }
}

/// Unit vector for a sky position. One `sin_cos` per angle rather than four
/// separate trig calls, because the index build runs this over every record in
/// the database.
fn unit_vector(ra_deg: f64, dec_deg: f64) -> [f64; 3] {
    let (sin_ra, cos_ra) = ra_deg.to_radians().sin_cos();
    let (sin_dec, cos_dec) = dec_deg.to_radians().sin_cos();
    [cos_dec * cos_ra, cos_dec * sin_ra, sin_dec]
}

fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

/// Parse one area file's bytes into stars, optionally keeping only those inside
/// `want`.
///
/// Layout (ASTAP `unit_star_database.pas`, record format 5): a 110-byte text
/// header whose `byte[109]` is the record size, then 5-byte records. RA lives in
/// three little-endian bytes. DEC's low two bytes are in the record, but its
/// HIGH byte comes from the most recent *header record* — a record whose RA
/// reads `0xFFFFFF` — which also carries the magnitude shared by the run of
/// stars that follows it.
pub fn parse_area(bytes: &[u8], want: Option<Cone>) -> Vec<SkyStar> {
    if bytes.len() < HEADER_LEN || bytes[HEADER_RECORD_SIZE_OFFSET] != RECORD_FORMAT_5 {
        return Vec::new();
    }
    let body = &bytes[HEADER_LEN..];

    let filter = want.map(|cone| {
        let centre = unit_vector(cone.ra_deg, cone.dec_deg);
        (centre, cone.radius_deg.to_radians().cos())
    });

    let mut stars = Vec::new();
    // Carried across records by the header records interleaved in the stream.
    let mut dec_high: i32 = 0;
    let mut mag = 0.0f64;

    for record in body.as_chunks::<{ RECORD_FORMAT_5 as usize }>().0 {
        let ra_raw =
            u32::from(record[0]) | (u32::from(record[1]) << 8) | (u32::from(record[2]) << 16);
        if ra_raw == 0x00FF_FFFF {
            dec_high = i32::from(record[3]) - 128;
            mag = (f64::from(record[4]) - 16.0) / 10.0;
            continue;
        }
        let dec_raw = i32::from(record[3]) | (i32::from(record[4]) << 8) | (dec_high << 16);
        let dec_deg = f64::from(dec_raw) * DEC_SCALE;
        let ra_deg = f64::from(ra_raw) * RA_SCALE_HOURS * 15.0;
        if let Some((centre, cos_limit)) = filter {
            if dot(unit_vector(ra_deg, dec_deg), centre) < cos_limit {
                continue;
            }
        }
        stars.push(SkyStar {
            ra_deg,
            dec_deg,
            mag,
        });
    }
    stars
}

fn read_area(path: &Path, want: Option<Cone>) -> Vec<SkyStar> {
    match std::fs::read(path) {
        Ok(bytes) => parse_area(&bytes, want),
        Err(err) => {
            tracing::debug!("sim sky: could not read area file {:?}: {}", path, err);
            Vec::new()
        }
    }
}

/// One area file reduced to the smallest cone that contains all of its stars.
#[derive(Debug, Clone)]
struct AreaCap {
    path: PathBuf,
    centre: [f64; 3],
    radius_deg: f64,
}

/// Which area files cover which part of the sky, so a field reads a handful of
/// them rather than all 1476.
#[derive(Debug)]
pub struct SkyIndex {
    areas: Vec<AreaCap>,
}

impl SkyIndex {
    /// Build the index by reducing every `<prefix>_*.1476` file in `dir` to a
    /// bounding cone.
    ///
    /// A cone, not an RA/Dec bounding box. A box is the wrong shape twice over:
    /// it is torn at the RA=0 wrap and it is degenerate near the poles, and a
    /// file dropped for either reason leaves a blank wedge in the rendered
    /// frame — the solver then finds image stars where its database has none and
    /// the quad match fails. A unit vector plus an angular radius has no seam.
    pub fn build(dir: &Path, prefix: &str) -> Self {
        let mut paths: Vec<PathBuf> = match std::fs::read_dir(dir) {
            Ok(entries) => entries
                .filter_map(|entry| entry.ok())
                .map(|entry| entry.path())
                .filter(|path| is_area_file(path, prefix))
                .collect(),
            Err(_) => Vec::new(),
        };
        // Sorted so the star order a field returns is reproducible run to run.
        paths.sort();

        let areas = paths
            .par_iter()
            .filter_map(|path| {
                let stars = read_area(path, None);
                if stars.is_empty() {
                    return None;
                }
                let vectors: Vec<[f64; 3]> = stars
                    .iter()
                    .map(|star| unit_vector(star.ra_deg, star.dec_deg))
                    .collect();
                let mut sum = [0.0f64; 3];
                for v in &vectors {
                    sum[0] += v[0];
                    sum[1] += v[1];
                    sum[2] += v[2];
                }
                let norm = (sum[0] * sum[0] + sum[1] * sum[1] + sum[2] * sum[2]).sqrt();
                if norm <= 0.0 {
                    return None;
                }
                let centre = [sum[0] / norm, sum[1] / norm, sum[2] / norm];
                let worst = vectors
                    .iter()
                    .map(|v| dot(*v, centre))
                    .fold(1.0f64, f64::min);
                Some(AreaCap {
                    path: path.clone(),
                    centre,
                    radius_deg: worst.clamp(-1.0, 1.0).acos().to_degrees(),
                })
            })
            .collect();

        Self { areas }
    }

    pub fn area_count(&self) -> usize {
        self.areas.len()
    }

    /// Stars within `radius_deg` of the given centre, BRIGHTEST FIRST and capped
    /// at `limit`.
    ///
    /// The sort order is load-bearing: truncating on anything else leaves the
    /// frame complete to no particular depth, and an image whose star list is
    /// not the brightest-N of the region is exactly what breaks the solver's
    /// quad match.
    pub fn field(&self, ra_deg: f64, dec_deg: f64, radius_deg: f64, limit: usize) -> Vec<SkyStar> {
        let want = Cone::new(ra_deg, dec_deg, radius_deg);
        let centre = unit_vector(ra_deg, dec_deg);
        let mut stars: Vec<SkyStar> = self
            .areas
            .iter()
            .filter(|area| {
                let separation = dot(area.centre, centre)
                    .clamp(-1.0, 1.0)
                    .acos()
                    .to_degrees();
                separation <= area.radius_deg + radius_deg
            })
            .flat_map(|area| read_area(&area.path, Some(want)))
            .collect();
        // Stable sort over a deterministic file order, so equal magnitudes keep
        // a reproducible position and a given pointing renders a given frame.
        stars.sort_by(|a, b| {
            a.mag
                .partial_cmp(&b.mag)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        stars.truncate(limit);
        stars
    }
}

fn is_area_file(path: &Path, prefix: &str) -> bool {
    if path.extension().and_then(|ext| ext.to_str()) != Some("1476") {
        return false;
    }
    match path.file_stem().and_then(|stem| stem.to_str()) {
        Some(stem) => area_prefix(stem).is_some_and(|found| found == prefix),
        None => false,
    }
}

/// The database name embedded in an area filename: `d05_0101` -> `d05`.
fn area_prefix(stem: &str) -> Option<&str> {
    stem.rsplit_once('_').map(|(prefix, _)| prefix)
}

/// Pick which database in `dir` to render from when several are installed.
///
/// The DEEPEST one, measured in catalogue bytes — records are a fixed five bytes
/// each, so total size is a direct proxy for how many stars a database holds.
/// Ties are broken by name so the choice stays stable.
///
/// Depth is the property that has to win, because the solver is never told which
/// database to use: `api::plate_solve` hands ASTAP the DIRECTORY (`-d`) and lets
/// it select a set for the field. Rendering from the deepest one is then the safe
/// direction — whatever ASTAP picks, its stars are a subset of ours at the bright
/// end, so the brightest-N it matches quads on are all present in the frame.
/// Rendering from a shallower one puts image stars where its database has none.
///
/// Counting FILES cannot express that. `.1476` names the number of sky areas the
/// format divides the sphere into, so every database of that format ships exactly
/// 1476 of them; a file vote always ties and falls through to the filename, which
/// sorts `w08` — the 8-stars/deg^2 wide-field set — above every deep Gaia set
/// there is. A rig with both installed then rendered two stars per frame and
/// nothing solved.
fn choose_prefix(dir: &Path) -> Option<String> {
    let entries = std::fs::read_dir(dir).ok()?;
    let mut sizes: HashMap<String, u64> = HashMap::new();
    for entry in entries.filter_map(|entry| entry.ok()) {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("1476") {
            continue;
        }
        if let Some(prefix) = path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .and_then(area_prefix)
        {
            // `path`, not `entry`: `DirEntry::metadata` does not traverse a
            // symlink, so a database linked in from elsewhere would weigh in at
            // the size of its link and lose the vote it should win.
            let bytes = path.metadata().map(|meta| meta.len()).unwrap_or(0);
            *sizes.entry(prefix.to_string()).or_default() += bytes;
        }
    }
    sizes
        .into_iter()
        .max_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)))
        .map(|(prefix, _)| prefix)
}

/// Built indices, keyed by catalogue directory.
///
/// `None` is cached as deliberately as `Some`: the overwhelmingly common case is
/// a simulator run with no ASTAP database installed, and re-scanning the
/// directory on every frame to rediscover that would put a `read_dir` on the
/// capture path forever.
type IndexCache = RwLock<HashMap<PathBuf, Option<Arc<SkyIndex>>>>;

fn cache() -> &'static IndexCache {
    static CACHE: OnceLock<IndexCache> = OnceLock::new();
    CACHE.get_or_init(|| RwLock::new(HashMap::new()))
}

/// The index for `dir`, building it on first use.
///
/// Returns `None` when the directory holds no `*.1476` files, which is the
/// signal to the frame synthesiser to keep painting its pseudo-random field.
pub fn index_for(dir: &Path) -> Option<Arc<SkyIndex>> {
    if let Ok(cached) = cache().read() {
        if let Some(hit) = cached.get(dir) {
            return hit.clone();
        }
    }

    // Built OUTSIDE the lock: it reads the whole database (~130 MB for D05) and
    // holding the map's write lock across that would stall every other reader.
    // Two callers racing the first frame both build; the loser's work is
    // dropped, which is cheaper than serialising them.
    let started = std::time::Instant::now();
    let built = choose_prefix(dir).and_then(|prefix| {
        let index = SkyIndex::build(dir, &prefix);
        if index.area_count() == 0 {
            None
        } else {
            tracing::info!(
                "sim sky: indexed {} '{}' area files from {:?} in {:.2}s",
                index.area_count(),
                prefix,
                dir,
                started.elapsed().as_secs_f64()
            );
            Some(Arc::new(index))
        }
    });

    match cache().write() {
        Ok(mut cached) => cached.entry(dir.to_path_buf()).or_insert(built).clone(),
        Err(_) => built,
    }
}

/// The index for the catalogue the plate solver is configured to use, or `None`
/// when no catalogue is configured or storage is not up yet.
///
/// Reading the SAME preference the solver reads is the point: it makes the
/// simulated sky and the solver's database the same data, so a solve can only
/// fail for a reason that would also fail on real hardware.
///
/// The preference itself is re-read per frame — a sub-kilobyte JSON parse
/// against a ~20 ms frame render, and the same read `plate_solve` already does
/// per solve — so pointing Settings → Plate Solving at a different catalogue
/// takes effect on the next exposure instead of the next launch. The expensive
/// part, the index, is what [`index_for`] caches.
pub fn configured_index() -> Option<Arc<SkyIndex>> {
    let pref = crate::state::get_platesolver_preference().ok()?;
    if pref.catalog_path.is_empty() {
        return None;
    }
    index_for(Path::new(&pref.catalog_path))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build an area file the way ASTAP writes one, so the parser is tested
    /// without depending on a star database being installed.
    fn synth_area(runs: &[(f64, Vec<(f64, f64)>)]) -> Vec<u8> {
        let mut bytes = vec![b' '; HEADER_LEN];
        bytes[HEADER_RECORD_SIZE_OFFSET] = RECORD_FORMAT_5;
        for (mag, stars) in runs {
            // ASTAP groups stars of equal magnitude behind a header record that
            // carries both the magnitude and the high byte of the declination.
            let dec_high = stars
                .first()
                .map(|(_, dec)| ((dec / DEC_SCALE).round() as i32) >> 16)
                .unwrap_or(0);
            bytes.extend_from_slice(&[
                0xFF,
                0xFF,
                0xFF,
                (dec_high + 128) as u8,
                (mag * 10.0 + 16.0).round() as u8,
            ]);
            for (ra_deg, dec_deg) in stars {
                let ra_raw = (ra_deg / 15.0 / RA_SCALE_HOURS).round() as u32;
                let dec_raw = (dec_deg / DEC_SCALE).round() as i32;
                assert_eq!(
                    dec_raw >> 16,
                    dec_high,
                    "fixture stars in one run must share a declination high byte"
                );
                bytes.extend_from_slice(&[
                    (ra_raw & 0xFF) as u8,
                    ((ra_raw >> 8) & 0xFF) as u8,
                    ((ra_raw >> 16) & 0xFF) as u8,
                    (dec_raw & 0xFF) as u8,
                    ((dec_raw >> 8) & 0xFF) as u8,
                ]);
            }
        }
        bytes
    }

    #[test]
    fn parses_positions_and_magnitudes_from_a_record_format_5_area() {
        let bytes = synth_area(&[
            (7.5, vec![(83.822, 22.014), (84.0, 22.02)]),
            (11.3, vec![(83.9, 22.001)]),
        ]);
        let stars = parse_area(&bytes, None);

        assert_eq!(stars.len(), 3, "three star records, header records skipped");
        assert!((stars[0].ra_deg - 83.822).abs() < 1e-4, "{:?}", stars[0]);
        assert!((stars[0].dec_deg - 22.014).abs() < 1e-4, "{:?}", stars[0]);
        assert!((stars[0].mag - 7.5).abs() < 1e-9, "{:?}", stars[0]);
        // The magnitude carried by the second header record applies to the run
        // that follows it, not to the stars before it.
        assert!((stars[2].mag - 11.3).abs() < 1e-9, "{:?}", stars[2]);
    }

    #[test]
    fn parses_southern_declinations_through_the_signed_high_byte() {
        let bytes = synth_area(&[(9.0, vec![(80.0, -35.5)])]);
        let stars = parse_area(&bytes, None);
        assert_eq!(stars.len(), 1);
        assert!(
            (stars[0].dec_deg + 35.5).abs() < 1e-4,
            "declination high byte must be read as signed: {:?}",
            stars[0]
        );
    }

    #[test]
    fn rejects_a_header_that_does_not_declare_the_record_size() {
        let mut bytes = synth_area(&[(9.0, vec![(80.0, 20.0)])]);
        bytes[HEADER_RECORD_SIZE_OFFSET] = 4;
        assert!(parse_area(&bytes, None).is_empty());
        assert!(parse_area(&bytes[..40], None).is_empty(), "short header");
    }

    #[test]
    fn cone_filter_keeps_only_stars_inside_the_radius() {
        let bytes = synth_area(&[(9.0, vec![(80.0, 20.0), (80.5, 20.0), (95.0, 20.0)])]);
        let stars = parse_area(&bytes, Some(Cone::new(80.0, 20.0, 1.0)));
        let ras: Vec<f64> = stars.iter().map(|s| s.ra_deg).collect();
        assert_eq!(ras.len(), 2, "got {:?}", ras);
        assert!(ras.iter().all(|ra| *ra < 81.0), "got {:?}", ras);
    }

    #[test]
    fn cone_filter_survives_the_ra_zero_wrap() {
        // Two stars 0.4 deg apart that a RA bounding box would put 359.8 deg
        // apart. This is the case that tears a box index and leaves a blank
        // wedge in the rendered frame.
        let bytes = synth_area(&[(9.0, vec![(359.8, 10.0), (0.2, 10.0)])]);
        let stars = parse_area(&bytes, Some(Cone::new(0.0, 10.0, 0.5)));
        assert_eq!(stars.len(), 2, "got {:?}", stars);
    }

    fn write_index_fixture() -> tempfile::TempDir {
        let dir = tempfile::TempDir::new().unwrap();
        // Two well-separated areas, plus a decoy from a shallower database that
        // must lose the prefix vote.
        std::fs::write(
            dir.path().join("d05_0001.1476"),
            synth_area(&[(8.0, vec![(10.0, 5.0), (10.4, 5.1), (9.7, 5.2)])]),
        )
        .unwrap();
        std::fs::write(
            dir.path().join("d05_0002.1476"),
            synth_area(&[(6.0, vec![(200.0, -40.0), (200.5, -39.8)])]),
        )
        .unwrap();
        std::fs::write(
            dir.path().join("w08_0001.1476"),
            synth_area(&[(4.0, vec![(10.0, 5.0)])]),
        )
        .unwrap();
        dir
    }

    #[test]
    fn index_reads_only_the_areas_a_field_touches() {
        let dir = write_index_fixture();
        let index = SkyIndex::build(dir.path(), "d05");
        assert_eq!(index.area_count(), 2);

        let near = index.field(10.0, 5.0, 1.0, 100);
        assert_eq!(near.len(), 3, "got {:?}", near);
        assert!(near.iter().all(|s| s.ra_deg < 20.0));

        let far = index.field(200.2, -40.1, 1.0, 100);
        assert_eq!(far.len(), 2, "got {:?}", far);

        let empty = index.field(120.0, 60.0, 1.0, 100);
        assert!(empty.is_empty(), "got {:?}", empty);
    }

    #[test]
    fn field_returns_brightest_first_and_truncates_on_brightness() {
        let dir = tempfile::TempDir::new().unwrap();
        std::fs::write(
            dir.path().join("d05_0001.1476"),
            synth_area(&[
                (12.0, vec![(10.0, 5.0)]),
                (7.0, vec![(10.1, 5.0)]),
                (9.5, vec![(10.2, 5.0)]),
            ]),
        )
        .unwrap();
        let index = SkyIndex::build(dir.path(), "d05");

        let all = index.field(10.1, 5.0, 1.0, 100);
        let mags: Vec<f64> = all.iter().map(|s| s.mag).collect();
        assert_eq!(mags, vec![7.0, 9.5, 12.0], "brightest first");

        let capped = index.field(10.1, 5.0, 1.0, 2);
        let capped_mags: Vec<f64> = capped.iter().map(|s| s.mag).collect();
        assert_eq!(capped_mags, vec![7.0, 9.5], "the cap drops the FAINTEST");
    }

    #[test]
    fn prefix_vote_picks_the_most_complete_database() {
        let dir = write_index_fixture();
        assert_eq!(choose_prefix(dir.path()).as_deref(), Some("d05"));
    }

    /// Two databases of EQUAL file count, which is the only case reality
    /// produces: `.1476` names the number of sky areas, so every database of
    /// that format ships exactly 1476 files. A vote counted in files therefore
    /// always ties and falls through to the filename, which orders `w08` — the
    /// 8-stars/deg^2 wide-field set — above every deep Gaia set there is.
    ///
    /// That matters because the solver is handed the DIRECTORY (`-d`) and picks
    /// its own database for the field; rendering from a shallower one than it
    /// matches against puts image stars where its database has none.
    #[test]
    fn prefix_vote_prefers_depth_when_the_file_counts_tie() {
        let dir = tempfile::TempDir::new().unwrap();
        let mut dense = Vec::new();
        for i in 0..200 {
            dense.push((10.0 + f64::from(i) * 0.001, 5.0));
        }
        for area in ["0001", "0002"] {
            std::fs::write(
                dir.path().join(format!("d05_{area}.1476")),
                synth_area(&[(9.0, dense.clone())]),
            )
            .unwrap();
            // Same number of files, a fraction of the stars.
            std::fs::write(
                dir.path().join(format!("w08_{area}.1476")),
                synth_area(&[(4.0, vec![(10.0, 5.0)])]),
            )
            .unwrap();
        }
        assert_eq!(
            choose_prefix(dir.path()).as_deref(),
            Some("d05"),
            "with the file counts tied the deeper database must win, not the \
             name that happens to sort last"
        );
    }

    #[test]
    fn a_directory_with_no_area_files_yields_no_index() {
        let dir = tempfile::TempDir::new().unwrap();
        std::fs::write(dir.path().join("astap_cli"), b"not a database").unwrap();
        assert!(choose_prefix(dir.path()).is_none());
        assert!(index_for(dir.path()).is_none());
        // Cached, so the miss does not re-scan the directory on the next frame.
        assert!(index_for(dir.path()).is_none());
    }

    #[test]
    fn index_is_built_once_and_cached_by_directory() {
        let dir = write_index_fixture();
        let first = index_for(dir.path()).expect("fixture has area files");
        let second = index_for(dir.path()).expect("cached");
        assert!(
            Arc::ptr_eq(&first, &second),
            "the second lookup must reuse the built index, not rebuild it"
        );
    }
}

/// End-to-end proof that a simulated frame is solvable by the REAL solver.
///
/// Ignored by default so CI without ASTAP stays green. To run it, point it at a
/// directory holding both `astap_cli` and a `*.1476` star database:
///
/// ```text
/// SKOTIQ_SIM_SKY_ASTAP_DIR=~/.local/share/skotiq-audit/astap/bin \
///   cargo test -p skotiq_bridge --lib astap -- --ignored --nocapture
/// ```
///
/// The default path is the one `tools/sim_fidelity/plate_solve_probe.py` uses,
/// so with the audit fixture installed no environment variable is needed. The
/// probe is the reference implementation; this test is the same experiment run
/// through the shipping renderer rather than through Python.
#[cfg(test)]
pub(crate) mod astap_integration {
    use super::*;
    use crate::sim_frame::{
        project_star, sim_sky_field_radius_deg, synthesize_sim_frame, SimFrameRequest, SimSkyView,
        SIM_H, SIM_SKY_STAR_LIMIT, SIM_W,
    };

    /// The simulated sensor's declared pixel pitch, in micrometres.
    pub(crate) const PIXEL_UM: f64 = 3.76;
    pub(crate) const ARCSEC_PER_RADIAN: f64 = 206_264.806_247_096_36;

    pub(crate) fn astap_dir() -> PathBuf {
        match std::env::var("SKOTIQ_SIM_SKY_ASTAP_DIR") {
            Ok(dir) => PathBuf::from(dir),
            Err(_) => {
                let home = std::env::var("HOME").unwrap_or_default();
                PathBuf::from(home).join(".local/share/skotiq-audit/astap/bin")
            }
        }
    }

    /// Write a synthetic record-format-5 area file holding `stars`, given as
    /// `(ra_deg, dec_deg, mag)`.
    ///
    /// Lets a test drive the REAL parser, index, projection and renderer with no
    /// star database installed, which is what makes a CI-visible test of the
    /// capture-path wiring possible at all.
    ///
    /// ASTAP groups stars behind a header record carrying BOTH the magnitude and
    /// the high byte of the declination, so the stars are emitted in runs that
    /// share both — sorting by that pair is what keeps the run structure legal.
    pub(crate) fn write_synthetic_area(path: &Path, stars: &[(f64, f64, f64)]) {
        let mut rows: Vec<(i32, i64, f64, f64)> = stars
            .iter()
            .map(|(ra_deg, dec_deg, mag)| {
                let dec_raw = (dec_deg / DEC_SCALE).round() as i32;
                (
                    dec_raw >> 16,
                    (mag * 10.0).round() as i64,
                    *ra_deg,
                    *dec_deg,
                )
            })
            .collect();
        rows.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));

        let mut bytes = vec![b' '; HEADER_LEN];
        bytes[HEADER_RECORD_SIZE_OFFSET] = RECORD_FORMAT_5;
        let mut run: Option<(i32, i64)> = None;
        for (dec_high, mag_tenths, ra_deg, dec_deg) in rows {
            if run != Some((dec_high, mag_tenths)) {
                bytes.extend_from_slice(&[
                    0xFF,
                    0xFF,
                    0xFF,
                    (dec_high + 128) as u8,
                    (mag_tenths + 16) as u8,
                ]);
                run = Some((dec_high, mag_tenths));
            }
            let ra_raw = (ra_deg / 15.0 / RA_SCALE_HOURS).round() as u32;
            let dec_raw = (dec_deg / DEC_SCALE).round() as i32;
            bytes.extend_from_slice(&[
                (ra_raw & 0xFF) as u8,
                ((ra_raw >> 8) & 0xFF) as u8,
                ((ra_raw >> 16) & 0xFF) as u8,
                (dec_raw & 0xFF) as u8,
                ((dec_raw >> 8) & 0xFF) as u8,
            ]);
        }
        std::fs::write(path, &bytes).expect("write synthetic area file");
    }

    /// The fixture writer round-trips through the real parser, including the
    /// signed declination high byte that the run structure carries.
    #[test]
    fn the_synthetic_area_fixture_round_trips_through_the_parser() {
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("d05_0001.1476");
        let want = [
            (83.822, -5.391, 9.0),
            (83.9, -5.5, 12.5),
            (84.1, 22.0, 7.5),
            (10.0, -35.5, 11.0),
        ];
        write_synthetic_area(&path, &want);

        let got = parse_area(&std::fs::read(&path).unwrap(), None);
        assert_eq!(got.len(), want.len());
        for (ra_deg, dec_deg, mag) in want {
            assert!(
                got.iter().any(|star| (star.ra_deg - ra_deg).abs() < 1e-4
                    && (star.dec_deg - dec_deg).abs() < 1e-4
                    && (star.mag - mag).abs() < 1e-9),
                "({ra_deg}, {dec_deg}, {mag}) did not survive the round trip: {got:?}"
            );
        }
    }

    fn sexagesimal_ra(hours: f64) -> String {
        let h = hours.trunc();
        let m = ((hours - h) * 60.0).trunc();
        format!(
            "{:02} {:02} {:05.2}",
            h as i64,
            m as i64,
            (hours - h - m / 60.0) * 3600.0
        )
    }

    fn sexagesimal_dec(degrees: f64) -> String {
        let sign = if degrees < 0.0 { '-' } else { '+' };
        let d = degrees.abs();
        let dd = d.trunc();
        let mm = ((d - dd) * 60.0).trunc();
        format!(
            "{}{:02} {:02} {:04.1}",
            sign,
            dd as i64,
            mm as i64,
            (d - dd - mm / 60.0) * 3600.0
        )
    }

    /// A minimal 16-bit FITS, which is what ASTAP reads.
    pub(crate) fn write_fits(
        path: &Path,
        pixels: &[u16],
        ra_hours: f64,
        dec_deg: f64,
        focal_mm: f64,
    ) {
        let cards: Vec<(String, String)> = vec![
            ("SIMPLE".into(), "T".into()),
            ("BITPIX".into(), "16".into()),
            ("NAXIS".into(), "2".into()),
            ("NAXIS1".into(), SIM_W.to_string()),
            ("NAXIS2".into(), SIM_H.to_string()),
            // 16-bit FITS is SIGNED, so an unsigned frame is stored offset by
            // half scale and BZERO puts it back.
            ("BZERO".into(), "32768".into()),
            ("BSCALE".into(), "1".into()),
            ("EXPTIME".into(), "10.000000".into()),
            ("XPIXSZ".into(), format!("{PIXEL_UM:.6}")),
            ("YPIXSZ".into(), format!("{PIXEL_UM:.6}")),
            ("FOCALLEN".into(), format!("{focal_mm:.6}")),
            (
                "OBJCTRA".into(),
                format!("'{:<8}'", sexagesimal_ra(ra_hours)),
            ),
            (
                "OBJCTDEC".into(),
                format!("'{:<8}'", sexagesimal_dec(dec_deg)),
            ),
        ];
        let mut header = Vec::new();
        for (key, value) in cards {
            header.extend_from_slice(format!("{:<8}= {:>20}", key, value).as_bytes());
            let pad = 80 - (header.len() % 80);
            if pad != 80 {
                header.extend(std::iter::repeat_n(b' ', pad));
            }
        }
        header.extend_from_slice(b"END");
        let pad = 80 - (header.len() % 80);
        if pad != 80 {
            header.extend(std::iter::repeat_n(b' ', pad));
        }
        let pad = (2880 - header.len() % 2880) % 2880;
        header.extend(std::iter::repeat_n(b' ', pad));

        let mut data = Vec::with_capacity(pixels.len() * 2);
        for value in pixels {
            data.extend_from_slice(&(i32::from(*value) - 32768).to_be_bytes()[2..]);
        }
        let pad = (2880 - data.len() % 2880) % 2880;
        data.extend(std::iter::repeat_n(0u8, pad));

        header.extend_from_slice(&data);
        std::fs::write(path, &header).expect("write fits");
    }

    /// ASTAP writes its solution as a FITS header: 80-byte cards with NO line
    /// terminators. Scanning it line-by-line finds one giant line and no
    /// `CRVAL1`, which reads as "no solve" while ASTAP is printing "Solution
    /// found" — the Python probe reported four focal lengths as failures on
    /// exactly this bug before it split on 80 bytes instead.
    ///
    /// This is the THIRD `.wcs` card reader in the repo, and it is deliberately
    /// not folded into the other two. The shared conformance fixture at
    /// `test_fixtures/wcs_conformance/` pins the production pair
    /// (`platesolve::fits_header_cards` and the Dart `_fitsHeaderCards`), which
    /// honour line terminators before card-splitting; this one chunks the raw
    /// bytes by 80 unconditionally and would therefore misread a
    /// newline-delimited header. That is correct for its one and only input —
    /// live `astap_cli -wcs` output, which never has terminators — and this
    /// module is `#[cfg(test)]` behind `#[ignore]`d hardware tests, so it is
    /// left alone rather than made to depend on a function private to another
    /// crate. If it ever reads a header from anywhere else, point it at the
    /// canonical splitter first.
    pub(crate) fn read_crval(base: &Path) -> Option<(f64, f64)> {
        let blob = std::fs::read(base.with_extension("wcs")).ok()?;
        let mut crval1 = None;
        let mut crval2 = None;
        for card in blob.chunks(80) {
            let text = String::from_utf8_lossy(card);
            let (key, value) = match text.split_once('=') {
                Some(parts) => parts,
                None => continue,
            };
            let parsed = value
                .split('/')
                .next()
                .and_then(|v| v.trim().parse::<f64>().ok());
            match key.trim() {
                "CRVAL1" => crval1 = parsed,
                "CRVAL2" => crval2 = parsed,
                _ => {}
            }
        }
        Some((crval1?, crval2?))
    }

    /// What the CAPTURE PATH actually pays per frame.
    ///
    /// The index build is cached, but [`SkyIndex::field`] re-reads the area files
    /// a pointing touches on every exposure, and that read is the cost that would
    /// sit between the shutter closing and the download returning. Measured here
    /// against the widest field the simulated rig can produce (135 mm, which
    /// touches the most area files) so the number is a worst case rather than a
    /// best one.
    ///
    /// Run it the same way as the solve test; see the module docs.
    #[test]
    #[ignore = "needs a star database; see the module docs to run it"]
    fn a_field_query_is_cheap_enough_for_the_capture_path() {
        let dir = astap_dir();
        let index = match index_for(&dir) {
            Some(index) => index,
            None => panic!("no *.1476 star database in {dir:?}"),
        };
        for focal_mm in [1000.0_f64, 400.0, 200.0, 135.0] {
            let arcsec_per_px = ARCSEC_PER_RADIAN * (PIXEL_UM / 1000.0) / focal_mm;
            let radius_deg = sim_sky_field_radius_deg(SIM_W, SIM_H, arcsec_per_px);
            // Averaged over several pointings, so one lucky page-cached area file
            // does not stand in for the whole sky.
            let mut worst = std::time::Duration::ZERO;
            let mut total = std::time::Duration::ZERO;
            let mut stars = 0;
            let pointings = [
                (83.8, -5.4),
                (0.1, 10.0),   // across the RA=0 wrap
                (299.0, 40.0), // Cygnus, a dense Milky Way field
                (45.0, 88.0),  // near the pole, where a box index degenerates
            ];
            for (ra_deg, dec_deg) in pointings {
                let started = std::time::Instant::now();
                let field = index.field(ra_deg, dec_deg, radius_deg, SIM_SKY_STAR_LIMIT);
                let elapsed = started.elapsed();
                worst = worst.max(elapsed);
                total += elapsed;
                stars += field.len();
            }
            let mean_ms = total.as_secs_f64() * 1000.0 / pointings.len() as f64;
            println!(
                "{focal_mm:5.0}mm  radius {radius_deg:4.2} deg  mean {mean_ms:6.2}ms  \
                 worst {:6.2}ms  stars/field {}",
                worst.as_secs_f64() * 1000.0,
                stars / pointings.len()
            );
            // A frame render is ~20 ms and the shortest exposure anything real
            // takes is measured in seconds. A field query that stayed under a
            // tenth of a second is invisible; one that did not would mean the
            // per-frame read needs its own cache.
            assert!(
                worst.as_secs_f64() < 0.1,
                "a {focal_mm:.0}mm field query took {:.1}ms, which is long enough to \
                 show up between the shutter and the download",
                worst.as_secs_f64() * 1000.0
            );
        }
    }

    #[test]
    #[ignore = "needs astap_cli and a star database; see the module docs to run it"]
    fn a_simulated_frame_solves_against_the_real_astap_binary() {
        let dir = astap_dir();
        let binary = dir.join("astap_cli");
        assert!(
            binary.exists(),
            "no astap_cli in {dir:?}; set SKOTIQ_SIM_SKY_ASTAP_DIR"
        );
        let prefix = choose_prefix(&dir).expect("no *.1476 star database installed");
        // Timed, because the capture path pays this cost exactly once: an index
        // rebuilt per frame would put a whole-database scan between the shutter
        // and the download.
        let started = std::time::Instant::now();
        let index = index_for(&dir).expect("star database did not index");
        println!(
            "indexed {} '{}' area files in {:.2}s",
            index.area_count(),
            prefix,
            started.elapsed().as_secs_f64()
        );
        let cached = std::time::Instant::now();
        index_for(&dir).unwrap();
        println!("cached lookup {:.6}s", cached.elapsed().as_secs_f64());

        // M42, the field the reference probe measures.
        let ra_hours = 5.59_f64;
        let dec_deg = -5.39_f64;
        let ra_deg = ra_hours * 15.0;
        let scratch = tempfile::TempDir::new().unwrap();

        let mut failures = Vec::new();
        // The four focal lengths the reference probe measures, plus the short
        // exposures a real Slew & Center actually captures at.
        for (focal_mm, exposure_secs) in [
            (1000.0_f64, 10.0_f64),
            (400.0, 10.0),
            (200.0, 10.0),
            (135.0, 10.0),
            (1000.0, 2.0),
            (400.0, 2.0),
        ] {
            let arcsec_per_px = ARCSEC_PER_RADIAN * (PIXEL_UM / 1000.0) / focal_mm;
            let radius_deg = sim_sky_field_radius_deg(SIM_W, SIM_H, arcsec_per_px);
            let stars = index.field(ra_deg, dec_deg, radius_deg, SIM_SKY_STAR_LIMIT);
            let sky = SimSkyView {
                centre_ra_deg: ra_deg,
                centre_dec_deg: dec_deg,
                rotation_deg: 0.0,
                arcsec_per_px,
                stars,
            };
            let on_sensor = sky
                .stars
                .iter()
                .filter_map(|star| project_star(&sky, SIM_W as f64, SIM_H as f64, star))
                .filter(|(x, y)| *x >= 0.0 && *y >= 0.0 && *x < SIM_W as f64 && *y < SIM_H as f64)
                .count();

            let pixels = synthesize_sim_frame(&SimFrameRequest {
                sky: Some(sky),
                exposure_secs,
                ..Default::default()
            });
            let path = scratch
                .path()
                .join(format!("sim_sky_{focal_mm:.0}_{exposure_secs:.0}s.fits"));
            write_fits(&path, &pixels, ra_hours, dec_deg, focal_mm);

            let base = path.with_extension("");
            let fov_h_deg = arcsec_per_px * SIM_H as f64 / 3600.0;
            let output = std::process::Command::new(&binary)
                .args([
                    "-f".into(),
                    path.to_string_lossy().to_string(),
                    "-r".into(),
                    "10".into(),
                    "-fov".into(),
                    format!("{fov_h_deg:.4}"),
                    "-ra".into(),
                    format!("{ra_hours:.5}"),
                    "-spd".into(),
                    format!("{:.5}", dec_deg + 90.0),
                    "-d".into(),
                    dir.to_string_lossy().to_string(),
                    "-D".into(),
                    prefix.clone(),
                    "-o".into(),
                    base.to_string_lossy().to_string(),
                    "-wcs".into(),
                ])
                .output()
                .expect("run astap_cli");

            match read_crval(&base) {
                Some((solved_ra, solved_dec)) => {
                    let error_arcsec = ((solved_ra - ra_deg) * dec_deg.to_radians().cos())
                        .hypot(solved_dec - dec_deg)
                        * 3600.0;
                    println!(
                        "{focal_mm:5.0}mm  {exposure_secs:4.0}s  {arcsec_per_px:5.2}\"/px  \
                         stars={on_sensor:4}  SOLVED  centre error {error_arcsec:.1}\""
                    );
                    // One output pixel. The reference probe measures 0.5" at
                    // 1000mm rising to 3.9" at 135mm, i.e. sub-pixel throughout.
                    if error_arcsec > arcsec_per_px {
                        failures.push(format!(
                            "{focal_mm:.0}mm/{exposure_secs:.0}s solved {error_arcsec:.1}\" off, over one \
                             {arcsec_per_px:.2}\" pixel"
                        ));
                    }
                }
                None => {
                    let stdout = String::from_utf8_lossy(&output.stdout);
                    println!(
                        "{focal_mm:5.0}mm  {exposure_secs:4.0}s  {arcsec_per_px:5.2}\"/px  \
                         stars={on_sensor:4}  NO SOLVE\n{}",
                        stdout.trim()
                    );
                    failures.push(format!(
                        "{focal_mm:.0}mm/{exposure_secs:.0}s did not solve: {}",
                        stdout.trim().lines().next_back().unwrap_or("(no output)")
                    ));
                }
            }
        }
        assert!(failures.is_empty(), "{}", failures.join("; "));
    }
}
