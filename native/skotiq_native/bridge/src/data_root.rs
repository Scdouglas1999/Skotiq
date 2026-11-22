//! The directory this host keeps its native files under (defect maps, camera
//! files kept when a download failed). The app resolves it, honoring the
//! operator's `SKOTIQ_DATA_DIR`, and hands it over in `api_init_host`; until
//! then there is none.

use std::path::PathBuf;
use std::sync::OnceLock;

static DATA_ROOT: OnceLock<PathBuf> = OnceLock::new();

/// Record the host's data root. A second call with the same directory is
/// accepted; a different one is refused, since files already written would
/// be left behind in the first.
pub(crate) fn set(root: PathBuf) -> Result<(), String> {
    set_in(&DATA_ROOT, root)
}

fn set_in(lock: &OnceLock<PathBuf>, root: PathBuf) -> Result<(), String> {
    let stored = lock.get_or_init(|| root.clone());
    if *stored == root {
        Ok(())
    } else {
        Err(format!(
            "The data directory is already {}; it cannot change to {} while the app runs",
            stored.display(),
            root.display()
        ))
    }
}

/// The host's data root, or why there is none: before `api_init_host`
/// names one, nothing is written anywhere.
fn get_in(lock: &OnceLock<PathBuf>) -> Result<PathBuf, String> {
    lock.get().cloned().ok_or_else(|| {
        "No data directory: the host has not named one yet (api_init_host)".to_string()
    })
}

pub(crate) fn defect_maps() -> Result<PathBuf, String> {
    Ok(get_in(&DATA_ROOT)?.join("defect_maps"))
}

pub(crate) fn retained_captures() -> Result<PathBuf, String> {
    Ok(get_in(&DATA_ROOT)?.join("retained_captures"))
}

/// A data root for this test process, as a host names one.
#[cfg(test)]
pub(crate) fn set_for_tests() -> PathBuf {
    let root = std::env::temp_dir().join(format!("skotiq-bridge-tests-{}", std::process::id()));
    let _ = DATA_ROOT.set(root);
    DATA_ROOT.get().cloned().expect("set above")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn files_sit_under_the_root_the_host_named() {
        let lock = OnceLock::new();
        set_in(&lock, PathBuf::from("/var/lib/skotiq/data")).unwrap();
        let root = get_in(&lock).unwrap();
        assert_eq!(root, PathBuf::from("/var/lib/skotiq/data"));
        assert_eq!(
            root.join("defect_maps"),
            PathBuf::from("/var/lib/skotiq/data/defect_maps")
        );
    }

    /// P12-2: before a host names its data root there is none; nothing
    /// is written to the temp directory.
    #[test]
    fn without_a_root_there_is_no_data_directory() {
        let error = get_in(&OnceLock::new()).expect_err("no root");
        assert!(error.contains("api_init_host"), "{error}");
    }

    #[test]
    fn the_root_does_not_move_once_set() {
        let lock = OnceLock::new();
        set_in(&lock, PathBuf::from("/a")).unwrap();
        assert!(set_in(&lock, PathBuf::from("/a")).is_ok());
        assert!(set_in(&lock, PathBuf::from("/b")).is_err());
        assert_eq!(get_in(&lock).unwrap(), PathBuf::from("/a"));
    }
}
