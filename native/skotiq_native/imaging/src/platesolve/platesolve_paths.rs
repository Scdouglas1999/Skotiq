//! Pure-function platform-specific path enumeration for plate-solver
//! detection.
//!
//! Split out from `platesolve.rs` so the candidate-path logic can be
//! unit-tested without touching the real filesystem. The `Fs` trait
//! abstracts path-existence checks; tests inject a synthetic in-memory FS
//! and assert which candidate the probe selected.
//!
//! These functions return *all* candidates the caller should probe — they do
//! not stop at the first hit. That keeps the detector deterministic and lets
//! the settings UI show every place we looked when nothing was found.

use std::path::{Path, PathBuf};

/// File-system probe abstraction. The real implementation in
/// `platesolve.rs` uses `Path::exists()`; tests inject a synthetic FS so the
/// path-enumeration logic can be exercised without writing to disk.
pub trait Fs {
    fn exists(&self, path: &Path) -> bool;
}

/// Default filesystem probe — real `Path::exists()`.
pub struct RealFs;

impl Fs for RealFs {
    fn exists(&self, path: &Path) -> bool {
        path.exists()
    }
}

/// First-hit probe: walk `candidates` and return the first path whose
/// existence the supplied `fs` confirms. Pure with respect to `fs` so tests
/// can drive the entire detection path with an in-memory mock.
pub fn first_existing<F: Fs>(fs: &F, candidates: &[PathBuf]) -> Option<PathBuf> {
    candidates.iter().find(|p| fs.exists(p)).cloned()
}

/// Operating-system family for path candidate generation.
///
/// Why an explicit enum (instead of `cfg!(target_os)`): the tests need to
/// exercise *every* platform's candidate list on a single host, so the path
/// generators must take the target OS as a parameter rather than reading it
/// from compile-time `cfg`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OsFamily {
    Windows,
    MacOs,
    Linux,
}

impl OsFamily {
    /// The host OS family at compile time. `unknown` Unix flavours collapse
    /// to `Linux` because that's the closest path convention we have.
    pub fn host() -> Self {
        if cfg!(target_os = "windows") {
            OsFamily::Windows
        } else if cfg!(target_os = "macos") {
            OsFamily::MacOs
        } else {
            OsFamily::Linux
        }
    }
}

/// Inputs to the candidate enumerator. All fields are optional except the OS
/// family.
pub struct AstapPathInputs<'a> {
    pub os: OsFamily,
    /// User-configured ASTAP executable path. Probed first when present.
    pub configured: Option<&'a Path>,
    /// `%LOCALAPPDATA%` on Windows. Resolved once by the real entry point so
    /// the pure function does not have to read environment variables.
    pub local_app_data: Option<&'a Path>,
    /// User home directory (`$HOME` or `%USERPROFILE%`).
    pub home: Option<&'a Path>,
}

/// Enumerate every well-known ASTAP executable candidate for the requested
/// OS family. Order matters: the configured path is first, then per-OS
/// install locations in descending likelihood. Callers probe in order and
/// take the first hit.
pub fn astap_candidates(inputs: &AstapPathInputs<'_>) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();

    if let Some(cfg) = inputs.configured {
        out.push(cfg.to_path_buf());
    }

    match inputs.os {
        OsFamily::Windows => {
            if let Some(lad) = inputs.local_app_data {
                out.push(lad.join("Programs").join("astap").join("astap_cli.exe"));
                out.push(lad.join("Programs").join("astap").join("astap.exe"));
                out.push(lad.join("astap").join("astap_cli.exe"));
                out.push(lad.join("astap").join("astap.exe"));
            }
            out.push(PathBuf::from(r"C:\Program Files\astap\astap_cli.exe"));
            out.push(PathBuf::from(r"C:\Program Files\astap\astap.exe"));
            out.push(PathBuf::from(r"C:\Program Files (x86)\astap\astap_cli.exe"));
            out.push(PathBuf::from(r"C:\Program Files (x86)\astap\astap.exe"));
            out.push(PathBuf::from(r"C:\astap\astap_cli.exe"));
            out.push(PathBuf::from(r"C:\astap\astap.exe"));
        }
        OsFamily::MacOs => {
            out.push(PathBuf::from(
                "/Applications/ASTAP.app/Contents/MacOS/astap",
            ));
            if let Some(home) = inputs.home {
                out.push(
                    home.join("Applications")
                        .join("ASTAP.app")
                        .join("Contents")
                        .join("MacOS")
                        .join("astap"),
                );
            }
            out.push(PathBuf::from("/usr/local/bin/astap"));
            out.push(PathBuf::from("/opt/homebrew/bin/astap"));
        }
        OsFamily::Linux => {
            out.push(PathBuf::from("/opt/astap/astap"));
            out.push(PathBuf::from("/usr/local/bin/astap"));
            out.push(PathBuf::from("/usr/bin/astap"));
        }
    }
    out
}

/// Inputs for astrometry.net path candidate enumeration.
pub struct AstrometryPathInputs<'a> {
    pub os: OsFamily,
    pub configured: Option<&'a Path>,
}

/// Enumerate well-known `solve-field` candidate paths for the requested OS
/// family.
pub fn astrometry_candidates(inputs: &AstrometryPathInputs<'_>) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    if let Some(cfg) = inputs.configured {
        out.push(cfg.to_path_buf());
    }
    match inputs.os {
        OsFamily::Windows => {
            out.push(PathBuf::from(
                r"C:\Program Files\Astrometry\solve-field.exe",
            ));
            out.push(PathBuf::from(
                r"C:\Program Files (x86)\Astrometry\solve-field.exe",
            ));
        }
        OsFamily::MacOs => {
            out.push(PathBuf::from("/usr/local/bin/solve-field"));
            out.push(PathBuf::from("/opt/homebrew/bin/solve-field"));
            out.push(PathBuf::from("/usr/local/astrometry/bin/solve-field"));
        }
        OsFamily::Linux => {
            out.push(PathBuf::from("/usr/bin/solve-field"));
            out.push(PathBuf::from("/usr/local/bin/solve-field"));
            out.push(PathBuf::from("/opt/astrometry/bin/solve-field"));
        }
    }
    out
}

/// Inputs for catalog directory enumeration. The catalog (`.290`/`.1476`/
/// `.h17` files plus an `INDEX.290` or similar) typically lives next to the
/// ASTAP binary, but power users move it onto a fast drive or into their
/// home folder.
pub struct CatalogSearchInputs<'a> {
    pub os: OsFamily,
    /// The ASTAP executable we already located. Its parent directory is the
    /// first place to probe.
    pub exe_path: Option<&'a Path>,
    /// User-configured catalog directory override.
    pub configured: Option<&'a Path>,
    /// `%LOCALAPPDATA%` on Windows.
    pub local_app_data: Option<&'a Path>,
    /// User home directory.
    pub home: Option<&'a Path>,
}

/// Enumerate every directory the detector should walk looking for an ASTAP
/// catalog. Order matters; first hit wins.
pub fn catalog_dir_candidates(inputs: &CatalogSearchInputs<'_>) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();

    if let Some(cfg) = inputs.configured {
        out.push(cfg.to_path_buf());
    }

    if let Some(exe) = inputs.exe_path {
        if let Some(parent) = exe.parent() {
            out.push(parent.to_path_buf());
        }
    }

    if let Some(home) = inputs.home {
        out.push(home.join(".astap"));
    }

    match inputs.os {
        OsFamily::Windows => {
            if let Some(lad) = inputs.local_app_data {
                out.push(lad.join("astap"));
                out.push(lad.join("Programs").join("astap"));
            }
            out.push(PathBuf::from(r"C:\astap"));
        }
        OsFamily::MacOs => {
            out.push(PathBuf::from("/usr/local/share/astap"));
            out.push(PathBuf::from("/opt/homebrew/share/astap"));
        }
        OsFamily::Linux => {
            out.push(PathBuf::from("/usr/share/astap"));
            out.push(PathBuf::from("/opt/astap"));
        }
    }

    out
}

/// Identifying information about a detected ASTAP star catalog. Returned by
/// the catalog scanner in `platesolve.rs`; lives here so tests can build
/// instances without touching the filesystem.
#[derive(Debug, Clone, PartialEq)]
pub struct CatalogInfo {
    /// Short catalog name, e.g. `"V17"`, `"D80"`, `"V50"`, `"G18"`. Empty
    /// string if we found `.290` / `.1476` files but no recognisable
    /// magnitude marker.
    pub name: String,
    /// Approximate magnitude limit the catalog covers. `None` when we
    /// detected the catalog files but no documented mag limit is known.
    pub magnitude_limit: Option<f32>,
    /// Directory where the catalog lives.
    pub path: PathBuf,
}

/// Identify the catalog flavour from a list of filenames in a candidate
/// directory. Pure function so the test suite can drive every ASTAP catalog
/// variant without staging real catalog files.
///
/// Returns `None` if the directory contains no recognisable ASTAP catalog
/// files. ASTAP catalogs are split across many `.290` / `.1476` index files
/// (one per declination strip) plus a handful of marker files; we identify
/// the variant by:
///   - documented file-prefix marker (e.g. `V17_*.290`, `D80_*.290`)
///   - filename containing a known catalog tag (`v17`, `v50`, `d80`, `g18`)
///   - failing both, surfacing a generic "catalog files present" entry with
///     no magnitude metadata.
pub fn identify_catalog<I, S>(dir: &Path, filenames: I) -> Option<CatalogInfo>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut has_index_files = false;
    let mut detected: Option<(&'static str, Option<f32>)> = None;

    for name in filenames {
        let lower = name.as_ref().to_ascii_lowercase();
        if lower.ends_with(".290") || lower.ends_with(".1476") || lower.ends_with(".h17") {
            has_index_files = true;
        }
        // Prefer the most-discriminating marker. ASTAP catalog filenames
        // start with the catalog tag, e.g. `V17_0101.290`, so a `starts_with`
        // check on the lowercased name keeps this simple. Magnitude limits
        // come from the published ASTAP catalog documentation
        // (https://www.hnsky.org/star_databases.htm).
        if detected.is_none() {
            if lower.starts_with("v17") || lower.contains("_v17") {
                detected = Some(("V17", Some(17.0)));
            } else if lower.starts_with("v50") || lower.contains("_v50") {
                detected = Some(("V50", Some(18.5)));
            } else if lower.starts_with("d80") || lower.contains("_d80") {
                detected = Some(("D80", Some(12.0)));
            } else if lower.starts_with("g18") || lower.contains("_g18") {
                detected = Some(("G18", Some(18.0)));
            } else if lower.starts_with("h18") || lower.contains("_h18") {
                detected = Some(("H18", Some(18.0)));
            } else if lower.starts_with("h17") || lower.contains("_h17") {
                detected = Some(("H17", Some(17.0)));
            } else if lower.starts_with("w08") || lower.contains("_w08") {
                detected = Some(("W08", Some(8.0)));
            } else if lower.starts_with("d05") || lower.contains("_d05") {
                // The D-series deep databases ship as `d05_0101.1476`. Without
                // this arm a directory full of working D05 catalogs detects as
                // "catalog present, version unrecognized". No
                // magnitude limit is asserted: the published table does not
                // give one for D05, and inventing a number here would feed a
                // fabricated limit to the exposure planner.
                detected = Some(("D05", None));
            }
        }
    }

    if !has_index_files && detected.is_none() {
        return None;
    }

    // Why: at this point `has_index_files` is true (otherwise we returned
    // None above), so a catalog directory exists but its signature didn't
    // match any known V17/D80/V50 variant. Surface it as an "unknown catalog"
    // with an empty name so the UI can show "catalog present, version
    // unrecognized" rather than pretending no catalog was found.
    let (name, mag) = detected.unwrap_or(("", None));
    Some(CatalogInfo {
        name: name.to_string(),
        magnitude_limit: mag,
        path: dir.to_path_buf(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    /// In-memory FS for unit tests. Stores absolute paths that "exist".
    struct MockFs {
        present: HashSet<PathBuf>,
    }

    impl MockFs {
        fn new<I: IntoIterator<Item = PathBuf>>(present: I) -> Self {
            Self {
                present: present.into_iter().collect(),
            }
        }
    }

    impl Fs for MockFs {
        fn exists(&self, path: &Path) -> bool {
            self.present.contains(path)
        }
    }

    #[test]
    fn astap_windows_candidates_include_localappdata_and_program_files() {
        let lad = PathBuf::from(r"C:\Users\sam\AppData\Local");
        let candidates = astap_candidates(&AstapPathInputs {
            os: OsFamily::Windows,
            configured: None,
            local_app_data: Some(&lad),
            home: None,
        });
        assert!(candidates.contains(&lad.join("Programs").join("astap").join("astap.exe")));
        assert!(candidates.contains(&PathBuf::from(r"C:\Program Files\astap\astap.exe")));
        assert!(candidates.contains(&PathBuf::from(r"C:\Program Files (x86)\astap\astap.exe")));
        assert!(candidates.contains(&PathBuf::from(r"C:\astap\astap.exe")));
    }

    #[test]
    fn astap_configured_path_is_first() {
        let cfg = PathBuf::from(r"D:\tools\astap.exe");
        let candidates = astap_candidates(&AstapPathInputs {
            os: OsFamily::Windows,
            configured: Some(&cfg),
            local_app_data: None,
            home: None,
        });
        assert_eq!(candidates[0], cfg);
    }

    #[test]
    fn astap_macos_candidates_include_applications_and_homebrew() {
        let home = PathBuf::from("/Users/sam");
        let candidates = astap_candidates(&AstapPathInputs {
            os: OsFamily::MacOs,
            configured: None,
            local_app_data: None,
            home: Some(&home),
        });
        assert!(candidates.contains(&PathBuf::from(
            "/Applications/ASTAP.app/Contents/MacOS/astap"
        )));
        assert!(candidates.contains(&home.join("Applications/ASTAP.app/Contents/MacOS/astap")));
        assert!(candidates.contains(&PathBuf::from("/usr/local/bin/astap")));
        assert!(candidates.contains(&PathBuf::from("/opt/homebrew/bin/astap")));
    }

    #[test]
    fn astap_linux_candidates_match_spec() {
        let candidates = astap_candidates(&AstapPathInputs {
            os: OsFamily::Linux,
            configured: None,
            local_app_data: None,
            home: None,
        });
        assert_eq!(
            candidates,
            vec![
                PathBuf::from("/opt/astap/astap"),
                PathBuf::from("/usr/local/bin/astap"),
                PathBuf::from("/usr/bin/astap"),
            ]
        );
    }

    #[test]
    fn astrometry_linux_candidates_match_spec() {
        let candidates = astrometry_candidates(&AstrometryPathInputs {
            os: OsFamily::Linux,
            configured: None,
        });
        assert!(candidates.contains(&PathBuf::from("/usr/bin/solve-field")));
        assert!(candidates.contains(&PathBuf::from("/usr/local/bin/solve-field")));
    }

    #[test]
    fn mockfs_returns_only_inserted_paths() {
        let path = PathBuf::from(r"C:\Program Files\astap\astap.exe");
        let fs = MockFs::new([path.clone()]);
        assert!(fs.exists(&path));
        assert!(!fs.exists(&PathBuf::from(r"C:\astap\astap.exe")));
    }

    #[test]
    fn first_existing_returns_first_hit_when_later_candidates_also_exist() {
        let early = PathBuf::from(r"C:\Program Files\astap\astap.exe");
        let later = PathBuf::from(r"C:\astap\astap.exe");
        let fs = MockFs::new([early.clone(), later.clone()]);
        let candidates = vec![
            PathBuf::from(r"C:\not-here\astap.exe"),
            early.clone(),
            later,
        ];
        assert_eq!(first_existing(&fs, &candidates), Some(early));
    }

    #[test]
    fn first_existing_returns_none_when_nothing_exists() {
        let fs = MockFs::new(Vec::<PathBuf>::new());
        let candidates = vec![PathBuf::from(r"C:\nope.exe")];
        assert_eq!(first_existing(&fs, &candidates), None);
    }

    /// End-to-end against the path enumerator: synthesise a MockFs with only
    /// the Program Files install present and assert the same candidate list
    /// the real probe would walk picks it up.
    #[test]
    fn end_to_end_windows_picks_program_files() {
        let installed = PathBuf::from(r"C:\Program Files\astap\astap.exe");
        let fs = MockFs::new([installed.clone()]);
        let lad = PathBuf::from(r"C:\Users\sam\AppData\Local");
        let candidates = astap_candidates(&AstapPathInputs {
            os: OsFamily::Windows,
            configured: None,
            local_app_data: Some(&lad),
            home: None,
        });
        assert_eq!(first_existing(&fs, &candidates), Some(installed));
    }

    /// End-to-end against the path enumerator: on Linux, `/opt/astap/astap`
    /// is the first candidate even when `/usr/bin/astap` also exists.
    #[test]
    fn end_to_end_linux_prefers_opt_over_usr_bin() {
        let opt = PathBuf::from("/opt/astap/astap");
        let usr = PathBuf::from("/usr/bin/astap");
        let fs = MockFs::new([opt.clone(), usr]);
        let candidates = astap_candidates(&AstapPathInputs {
            os: OsFamily::Linux,
            configured: None,
            local_app_data: None,
            home: None,
        });
        assert_eq!(first_existing(&fs, &candidates), Some(opt));
    }

    // Windows-only: this exercises exe-path `.parent()` resolution on backslash
    // paths, which Rust's `Path` only splits on Windows hosts (on Unix a
    // backslash path is a single opaque component, so `.parent()` cannot yield
    // `C:\Program Files\astap`). The production `catalog_dir_candidates` logic is
    // host-agnostic via `OsFamily`; only this assertion depends on host path
    // semantics, so it is gated rather than weakened.
    #[cfg(windows)]
    #[test]
    fn catalog_dirs_include_exe_parent_and_home_dot_astap() {
        let exe = PathBuf::from(r"C:\Program Files\astap\astap.exe");
        let home = PathBuf::from(r"C:\Users\sam");
        let dirs = catalog_dir_candidates(&CatalogSearchInputs {
            os: OsFamily::Windows,
            exe_path: Some(&exe),
            configured: None,
            local_app_data: None,
            home: Some(&home),
        });
        assert!(dirs.contains(&PathBuf::from(r"C:\Program Files\astap")));
        assert!(dirs.contains(&home.join(".astap")));
    }

    #[test]
    fn catalog_dirs_prepend_configured_override() {
        let cfg = PathBuf::from(r"D:\catalogs\v17");
        let dirs = catalog_dir_candidates(&CatalogSearchInputs {
            os: OsFamily::Windows,
            exe_path: None,
            configured: Some(&cfg),
            local_app_data: None,
            home: None,
        });
        assert_eq!(dirs[0], cfg);
    }

    #[test]
    fn identify_v17_catalog_from_filename_marker() {
        let dir = PathBuf::from(r"C:\astap");
        let info = identify_catalog(
            &dir,
            ["V17_0101.290", "V17_0102.290", "INDEX.290"]
                .iter()
                .cloned(),
        )
        .expect("V17 catalog must be detected");
        assert_eq!(info.name, "V17");
        assert_eq!(info.magnitude_limit, Some(17.0));
        assert_eq!(info.path, dir);
    }

    #[test]
    fn identify_d80_catalog_from_filename_marker() {
        let dir = PathBuf::from("/usr/share/astap");
        let info = identify_catalog(&dir, ["d80_0101.1476"].iter().cloned())
            .expect("D80 catalog must be detected");
        assert_eq!(info.name, "D80");
        assert_eq!(info.magnitude_limit, Some(12.0));
    }

    #[test]
    fn identify_catalog_returns_none_when_directory_has_no_catalog_files() {
        let dir = PathBuf::from(r"C:\astap");
        let info = identify_catalog(&dir, ["README.txt", "astap.exe"].iter().cloned());
        assert!(info.is_none());
    }

    #[test]
    fn identify_unknown_catalog_still_reports_files_present() {
        // `.290` files present but no recognisable tag — surface a generic
        // entry rather than a hit-or-miss false negative.
        let dir = PathBuf::from(r"C:\astap");
        let info = identify_catalog(&dir, ["random_0101.290"].iter().cloned())
            .expect("generic .290 presence must be reported");
        assert_eq!(info.name, "");
        assert_eq!(info.magnitude_limit, None);
    }
}
