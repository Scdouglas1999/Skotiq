use std::sync::atomic::{AtomicU64, Ordering};

static TEMP_FITS_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

/// A path in the temp directory no other call or process is handed.
pub(crate) fn create_unique_temp_fits_path(prefix: &str) -> std::path::PathBuf {
    let counter = TEMP_FITS_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
    // Why: timestamp `unwrap_or_default()` recovers
    // `Duration::ZERO` on a pre-1970 clock. The atomic `counter` and
    // `process::id()` still guarantee uniqueness — the timestamp is only
    // a secondary disambiguator, so a zero value in that case still
    // produces a valid unique path.
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!(
        "{}_{}_{}_{}.fits",
        prefix,
        std::process::id(),
        timestamp,
        counter
    ))
}
