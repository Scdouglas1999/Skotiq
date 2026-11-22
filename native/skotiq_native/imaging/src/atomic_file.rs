//! Putting a file in place so no reader sees half of it: write a sibling,
//! then rename it over the destination.
//!
//! `write_fits` has its own stronger form (a reserved unique scratch name, the
//! old file's permissions, read-only refusal) because it writes through the
//! handle it reserved.

use std::path::Path;

/// What a replacement does besides the rename.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Replace {
    /// Flush the staged file to disk before it takes the destination's name.
    pub sync: bool,
    /// Remove the staged file when writing it fails.
    pub clean_after_write_error: bool,
    /// Remove the staged file when flushing or renaming it fails.
    pub clean_after_place_error: bool,
}

impl Replace {
    /// Flushed, and no staged file left behind on any failure.
    pub const DURABLE: Self = Self {
        sync: true,
        clean_after_write_error: true,
        clean_after_place_error: true,
    };
}

/// Why a replacement failed. A caller that keeps a log reports `cleanup`;
/// imaging itself has none, so its own callers fold it into their error or
/// leave it, as their messages did before.
#[derive(Debug)]
pub enum ReplaceError<E> {
    /// The writer failed on the staged file. `cleanup` is the error removing
    /// it gave, when removal was asked for and failed.
    Write {
        error: E,
        cleanup: Option<std::io::Error>,
    },
    /// The staged file was written but could not be flushed or renamed.
    /// `cleanup` is the error removing it gave, when removal was asked for
    /// and failed.
    Place {
        error: std::io::Error,
        cleanup: Option<std::io::Error>,
    },
}

/// Write `path` through `staged`: `write` fills `staged`, which then replaces
/// `path` in one rename.
pub fn replace_file<E>(
    path: &Path,
    staged: &Path,
    how: Replace,
    write: impl FnOnce(&Path) -> Result<(), E>,
) -> Result<(), ReplaceError<E>> {
    if let Err(error) = write(staged) {
        let cleanup = how
            .clean_after_write_error
            .then(|| remove_staged(staged))
            .flatten();
        return Err(ReplaceError::Write { error, cleanup });
    }
    let placed = if how.sync {
        // Opened for writing: Windows flushes only a handle that may write.
        std::fs::OpenOptions::new()
            .write(true)
            .open(staged)
            .and_then(|file| file.sync_all())
    } else {
        Ok(())
    }
    .and_then(|()| std::fs::rename(staged, path));
    match placed {
        Ok(()) => Ok(()),
        Err(error) => {
            let cleanup = how
                .clean_after_place_error
                .then(|| remove_staged(staged))
                .flatten();
            Err(ReplaceError::Place { error, cleanup })
        }
    }
}

/// Remove a staged file; one never written is already gone.
fn remove_staged(staged: &Path) -> Option<std::io::Error> {
    match std::fs::remove_file(staged) {
        Ok(()) => None,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => Some(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_staged_file_takes_the_destination_name() {
        let scratch = tempfile::tempdir().unwrap();
        let dir = scratch.path();
        let path = dir.join("a.bin");
        let staged = dir.join(".a.bin.tmp");
        std::fs::write(&path, b"old").unwrap();
        replace_file(&path, &staged, Replace::DURABLE, |p| {
            std::fs::write(p, b"new")
        })
        .unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"new");
        assert!(!staged.exists());
    }

    #[test]
    fn a_failure_keeps_the_old_file_and_cleans_up_only_when_asked() {
        let scratch = tempfile::tempdir().unwrap();
        let dir = scratch.path();
        let path = dir.join("taken");
        std::fs::create_dir_all(path.join("inside")).unwrap();
        let staged = dir.join(".taken.tmp");
        let kept = Replace {
            clean_after_place_error: false,
            ..Replace::DURABLE
        };
        let err = replace_file(&path, &staged, kept, |p| std::fs::write(p, b"new")).unwrap_err();
        assert!(matches!(err, ReplaceError::Place { cleanup: None, .. }));
        assert!(staged.exists(), "left in place when not asked to clean up");
        let err = replace_file(&path, &staged, Replace::DURABLE, |p| {
            std::fs::write(p, b"new")
        })
        .unwrap_err();
        assert!(matches!(err, ReplaceError::Place { cleanup: None, .. }));
        assert!(!staged.exists());
        assert!(path.join("inside").exists());

        let err = replace_file(&dir.join("b"), &staged, Replace::DURABLE, |p| {
            std::fs::write(p, b"half")?;
            Err::<(), _>(std::io::Error::other("writer gave up"))
        })
        .unwrap_err();
        assert!(matches!(err, ReplaceError::Write { cleanup: None, .. }));
        assert!(!staged.exists());
    }
}
