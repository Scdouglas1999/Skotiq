//! `save_path.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

/// Claim `path` for this caller by creating it, failing if it already exists.
///
/// `exists()`-then-return left a window in which two concurrent frames both
/// saw a free path and both wrote to it; `create_new` collapses the check and
/// the claim into one filesystem operation.
pub(crate) fn claim_save_path(path: &std::path::Path) -> std::io::Result<()> {
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map(|_| ())
}

pub(crate) fn ensure_unique_save_path(path: PathBuf) -> PathBuf {
    match claim_save_path(&path) {
        Ok(()) => return path,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => {
            // Not a collision — the directory is unwritable, full, or gone.
            // Suffixing cannot help; hand the path back so the FITS save
            // surfaces the real error.
            tracing::warn!(
                "[FS] could not claim save path {}: {}. Handing it to the writer unclaimed.",
                path.display(),
                e
            );
            return path;
        }
    }

    // parent and stem fallbacks here are defensive — by the time
    // we enter this function the caller has already passed a fully-formed
    // path. If the parent is None (file at filesystem root) we keep using an
    // empty PathBuf so `.join()` writes into the cwd; that mirrors the
    // pre-audit behaviour but is now explicit. If the stem is missing we
    // fall back to "image" but log so the operator can audit how a stemless
    // path was constructed.
    let parent = match path.parent() {
        Some(p) => p.to_path_buf(),
        None => {
            tracing::warn!(
                "[FS] ensure_unique_save_path: path has no parent component ({}). \
                 Suffixed candidates will be written to the current working directory.",
                path.display()
            );
            PathBuf::new()
        }
    };
    let stem = match path.file_stem().and_then(|v| v.to_str()) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => {
            tracing::warn!(
                "[FS] ensure_unique_save_path: path has no usable file stem ({}); \
                 falling back to \"image\" for suffix generation.",
                path.display()
            );
            "image".to_string()
        }
    };
    let extension = path.extension().and_then(|value| value.to_str());

    let mut suffix = 1;
    loop {
        let candidate_name = match extension {
            Some(ext) if !ext.is_empty() => format!("{}_{:03}.{}", stem, suffix, ext),
            _ => format!("{}_{:03}", stem, suffix),
        };
        let candidate = parent.join(candidate_name);
        match claim_save_path(&candidate) {
            Ok(()) => return candidate,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => suffix += 1,
            Err(e) => {
                tracing::warn!(
                    "[FS] could not claim save path {}: {}. Handing it to the writer unclaimed.",
                    candidate.display(),
                    e
                );
                return candidate;
            }
        }
    }
}
