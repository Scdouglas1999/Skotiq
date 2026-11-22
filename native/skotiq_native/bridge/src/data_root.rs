//! The directory this host keeps its native files under (defect maps, camera
//! files kept when a download failed). The app resolves it, honoring the
//! operator's `SKOTIQ_DATA_DIR`, and hands it over in `api_init_host`.

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

/// The host's data root. Before `api_init_host` (unit tests, a start that
/// never names one) it is `skotiq` in the temp directory.
fn get_in(lock: &OnceLock<PathBuf>) -> PathBuf {
    lock.get()
        .cloned()
        .unwrap_or_else(|| std::env::temp_dir().join("skotiq"))
}

pub(crate) fn defect_maps() -> PathBuf {
    get_in(&DATA_ROOT).join("defect_maps")
}

pub(crate) fn retained_captures() -> PathBuf {
    get_in(&DATA_ROOT).join("retained_captures")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn files_sit_under_the_root_the_host_named() {
        let lock = OnceLock::new();
        set_in(&lock, PathBuf::from("/var/lib/skotiq/data")).unwrap();
        let root = get_in(&lock);
        assert_eq!(root, PathBuf::from("/var/lib/skotiq/data"));
        assert_eq!(
            root.join("defect_maps"),
            PathBuf::from("/var/lib/skotiq/data/defect_maps")
        );
    }

    #[test]
    fn without_a_root_files_go_to_the_temp_directory() {
        assert_eq!(
            get_in(&OnceLock::new()),
            std::env::temp_dir().join("skotiq")
        );
    }

    #[test]
    fn the_root_does_not_move_once_set() {
        let lock = OnceLock::new();
        set_in(&lock, PathBuf::from("/a")).unwrap();
        assert!(set_in(&lock, PathBuf::from("/a")).is_ok());
        assert!(set_in(&lock, PathBuf::from("/b")).is_err());
        assert_eq!(get_in(&lock), PathBuf::from("/a"));
    }
}
