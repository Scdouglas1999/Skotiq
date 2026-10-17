use super::{
    api_update_fits_keywords, save_fits_file_rich, FitsKeywordUpdate, FitsWriteHeaderRich,
};
use skotiq_imaging::read_fits;
use skotiq_sequencer::scheduling::FrameContext;
use std::path::{Path, PathBuf};

/// A scratch directory that deletes itself when the test ends. Cleanup runs
/// from `Drop`, so it happens even while a panic unwinds out of a failing test.
struct TempDir(PathBuf);

impl std::ops::Deref for TempDir {
    type Target = Path;
    fn deref(&self) -> &Path {
        &self.0
    }
}

// Deref alone does not satisfy a generic `AsRef<Path>` bound, which several
// call sites here rely on.
impl AsRef<Path> for TempDir {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        // Best-effort: a test asserting on a half-removed tree should fail
        // on its own assertion, not on cleanup.
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn temp_fits_dir(tag: &str) -> TempDir {
    let p = std::env::temp_dir().join(format!(
        "ns_kw_{}_{}_{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&p).unwrap();
    TempDir(p)
}

async fn write_baseline_fits(path: &std::path::Path) {
    let width = 4u32;
    let height = 4u32;
    let pixels = vec![0u16; (width * height) as usize];
    let ctx = FrameContext::new_light("sess", 1, 1, 10.0, 1);
    let header = FitsWriteHeaderRich::from_frame_context(&ctx);
    save_fits_file_rich(
        path.to_string_lossy().to_string(),
        width,
        height,
        pixels,
        header,
    )
    .await
    .expect("baseline FITS save should succeed");
}

#[tokio::test]
async fn injects_science_keywords_round_trip() {
    let scratch = temp_fits_dir("inject");
    let path = scratch.join("frame.fits");
    write_baseline_fits(&path).await;

    let updates = vec![
        FitsKeywordUpdate {
            keyword: "MAGZP".to_string(),
            comment: Some("Photometric zero point [mag]".to_string()),
            string_value: None,
            int_value: None,
            float_value: Some(24.317),
        },
        FitsKeywordUpdate {
            keyword: "MAGZPERR".to_string(),
            comment: Some("MAGZP 1-sigma uncertainty".to_string()),
            string_value: None,
            int_value: None,
            float_value: Some(0.041),
        },
        FitsKeywordUpdate {
            keyword: "MAGZPSRC".to_string(),
            comment: Some("Catalog used for MAGZP".to_string()),
            string_value: Some("GAIA-DR3".to_string()),
            int_value: None,
            float_value: None,
        },
        FitsKeywordUpdate {
            keyword: "TRANSPAR".to_string(),
            comment: Some("Atmospheric transparency [%]".to_string()),
            string_value: None,
            int_value: None,
            float_value: Some(92.0),
        },
    ];

    api_update_fits_keywords(path.to_string_lossy().to_string(), updates)
        .await
        .expect("keyword update should succeed");

    let (_image, parsed) = read_fits(&path).expect("FITS read-back");
    assert_eq!(parsed.get_float("MAGZP"), Some(24.317));
    assert_eq!(parsed.get_float("MAGZPERR"), Some(0.041));
    assert_eq!(parsed.get_string("MAGZPSRC"), Some("GAIA-DR3"));
    assert_eq!(parsed.get_float("TRANSPAR"), Some(92.0));
    // Existing keywords are preserved.
    assert_eq!(
        parsed.get_string("IMAGETYP").map(str::to_uppercase),
        Some("LIGHT".to_string())
    );
}

#[tokio::test]
async fn overwrites_existing_keyword_value() {
    let scratch = temp_fits_dir("overwrite");
    let path = scratch.join("frame.fits");
    write_baseline_fits(&path).await;

    // First write 1.0, then overwrite with 24.5; the second value must win.
    for value in &[1.0_f64, 24.5_f64] {
        api_update_fits_keywords(
            path.to_string_lossy().to_string(),
            vec![FitsKeywordUpdate {
                keyword: "MAGZP".to_string(),
                comment: None,
                string_value: None,
                int_value: None,
                float_value: Some(*value),
            }],
        )
        .await
        .expect("update should succeed");
    }
    let (_image, parsed) = read_fits(&path).expect("FITS read-back");
    assert_eq!(parsed.get_float("MAGZP"), Some(24.5));
}

#[tokio::test]
async fn rejects_keywords_with_multiple_value_types() {
    let scratch = temp_fits_dir("multi");
    let path = scratch.join("frame.fits");
    write_baseline_fits(&path).await;

    let result = api_update_fits_keywords(
        path.to_string_lossy().to_string(),
        vec![FitsKeywordUpdate {
            keyword: "MAGZP".to_string(),
            comment: None,
            string_value: Some("bad".to_string()),
            int_value: None,
            float_value: Some(1.0),
        }],
    )
    .await;
    assert!(result.is_err(), "must reject ambiguous value");
}

#[tokio::test]
async fn rejects_oversize_keyword() {
    let scratch = temp_fits_dir("oversize");
    let path = scratch.join("frame.fits");
    write_baseline_fits(&path).await;

    let result = api_update_fits_keywords(
        path.to_string_lossy().to_string(),
        vec![FitsKeywordUpdate {
            keyword: "TOOLONGKEY".to_string(), // 10 chars; FITS max 8
            comment: None,
            string_value: None,
            int_value: None,
            float_value: Some(1.0),
        }],
    )
    .await;
    assert!(result.is_err(), "must reject >8 char keyword");
}

#[tokio::test]
async fn missing_file_returns_io_error() {
    let result = api_update_fits_keywords(
        "/definitely/not/a/real/file.fits".to_string(),
        vec![FitsKeywordUpdate {
            keyword: "MAGZP".to_string(),
            comment: None,
            string_value: None,
            int_value: None,
            float_value: Some(1.0),
        }],
    )
    .await;
    assert!(result.is_err(), "missing file must surface an error");
}
