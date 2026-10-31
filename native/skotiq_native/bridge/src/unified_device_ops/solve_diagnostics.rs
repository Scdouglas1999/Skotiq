//! Bounded evidence for failed utility solves. Successful solve files stay temporary.
use serde_json::Value;
use std::{
    fs, io,
    path::{Path, PathBuf},
};

const MAX_FAILURES: usize = 8;
const MAX_BYTES: u64 = 256 * 1024 * 1024;

pub(super) async fn retain_failed_solve(source: PathBuf, metadata: Value) {
    let Some(logs) = crate::get_log_directory() else {
        tracing::warn!("Failed solve image cannot be retained: log directory is unavailable");
        return;
    };
    let root = PathBuf::from(logs).join("failed-solves");
    let result = tokio::task::spawn_blocking(move || {
        static WRITER: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _writer = WRITER
            .lock()
            .map_err(|_| io::Error::other("diagnostic writer poisoned"))?;
        retain(&root, &source, &metadata, MAX_FAILURES, MAX_BYTES)
    })
    .await;
    match result {
        Ok(Ok(path)) => {
            tracing::warn!(path = %path.display(), "Retained failed solve image and context")
        }
        other => tracing::warn!(?other, "Could not retain failed solve evidence"),
    }
}

fn retain(
    root: &Path,
    source: &Path,
    metadata: &Value,
    max_count: usize,
    max_bytes: u64,
) -> io::Result<PathBuf> {
    let json = serde_json::to_vec_pretty(metadata)?;
    let needed = fs::metadata(source)?.len() + json.len() as u64;
    if needed > max_bytes || max_count == 0 {
        return Err(io::Error::other(
            "failed solve exceeds diagnostic storage budget",
        ));
    }
    fs::create_dir_all(root)?;
    let mut entries = Vec::new();
    for item in fs::read_dir(root)? {
        let item = item?;
        if !item.file_type()?.is_dir() || !item.file_name().to_string_lossy().starts_with("solve-")
        {
            continue;
        }
        let mut bytes = 0;
        for file in fs::read_dir(item.path())? {
            bytes += file?.metadata()?.len();
        }
        entries.push((item.file_name(), item.path(), bytes));
    }
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    let mut total: u64 = entries.iter().map(|e| e.2).sum();
    let mut count = entries.len();
    for (_, path, bytes) in entries {
        if count < max_count && total + needed <= max_bytes {
            break;
        }
        fs::remove_dir_all(path)?;
        total -= bytes;
        count -= 1;
    }
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_nanos();
    let destination = root.join(format!("solve-{stamp}"));
    fs::create_dir(&destination)?;
    let written = (|| {
        fs::copy(source, destination.join("frame.fits"))?;
        fs::write(destination.join("context.json"), json)
    })();
    if let Err(error) = written {
        let _ = fs::remove_dir_all(&destination);
        return Err(error);
    }
    Ok(destination)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_pixels_and_context_and_rotates_only_owned_evidence() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("failed-solves");
        fs::create_dir_all(root.join("unrelated")).unwrap();
        let frame = dir.path().join("input.fits");
        fs::write(&frame, b"actual sensor bytes").unwrap();
        let context = serde_json::json!({"error": "No stars", "exposure_secs": 15});
        let first = retain(&root, &frame, &context, 2, 1024).unwrap();
        assert_eq!(
            fs::read(first.join("frame.fits")).unwrap(),
            fs::read(&frame).unwrap()
        );
        assert_eq!(
            serde_json::from_slice::<Value>(&fs::read(first.join("context.json")).unwrap())
                .unwrap(),
            context
        );
        let second = retain(&root, &frame, &context, 2, 1024).unwrap();
        let third = retain(&root, &frame, &context, 2, 1024).unwrap();
        assert!(!first.exists());
        assert!(second.exists() && third.exists() && root.join("unrelated").exists());
        assert!(frame.exists());
    }
    #[test]
    fn byte_budget_evicts_old_frames_and_rejects_oversized_input() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("evidence");
        let frame = dir.path().join("input.fits");
        fs::write(&frame, vec![7; 60]).unwrap();
        let first = retain(&root, &frame, &Value::Null, 8, 100).unwrap();
        let second = retain(&root, &frame, &Value::Null, 8, 100).unwrap();
        assert!(!first.exists() && second.exists());
        fs::write(&frame, vec![7; 101]).unwrap();
        assert!(retain(&root, &frame, &Value::Null, 8, 100).is_err());
        assert!(second.exists());
    }
}
