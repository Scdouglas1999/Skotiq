//! Tests of the grading instructions; the shared fixtures are in the parent module.

use super::*;

// Image Grading: reject folder resolution

#[test]
fn reject_dir_defaults_to_reject_subfolder_of_save_path() {
    let base = std::path::Path::new("/captures/M31/L");
    let dir = resolve_reject_dir(base, None);
    assert_eq!(dir, std::path::Path::new("/captures/M31/L/Reject"));
}

#[test]
fn reject_dir_relative_override_resolves_against_save_path() {
    let base = std::path::Path::new("/captures/M31/L");
    let dir = resolve_reject_dir(base, Some("BadFrames"));
    assert_eq!(dir, std::path::Path::new("/captures/M31/L/BadFrames"));
}

#[test]
fn reject_dir_absolute_override_outside_the_target_stays_with_the_target() {
    // The IC 405 run wrote rejects into an older target's absolute folder.
    #[cfg(windows)]
    let abs = r"C:\Users\scdou\Documents\NGC7380\Reject";
    #[cfg(not(windows))]
    let abs = "/captures/NGC7380/Reject";

    let base = std::path::Path::new("/captures/IC405/Ha");
    let dir = resolve_reject_dir(base, Some(abs));
    assert_eq!(dir, base.join("Reject"));
}

#[test]
fn reject_dir_absolute_override_inside_the_target_is_kept() {
    let base = std::env::temp_dir().join("IC405").join("Ha");
    let abs = base.join("Bad");
    let dir = resolve_reject_dir(&base, Some(&abs.to_string_lossy()));
    assert_eq!(dir, abs);
}

/// The forensic history keeps the newest frames, at most
/// `FORENSIC_HISTORY_LEN` of them, however long the run.
#[tokio::test]
async fn the_forensic_history_keeps_only_the_newest_frames() {
    let ec = crate::node::context::ExecutionContext::new_for_test("test-node".to_string());
    let ctx = ec.to_instruction_context("test-node").await;
    let len = crate::quality::FORENSIC_HISTORY_LEN;
    for i in 0..len + 3 {
        let sample = crate::quality::RecentFrameSample {
            unix_secs: i as f64,
            ..Default::default()
        };
        push_forensic_sample(&ctx, sample).await;
    }
    let kept: Vec<f64> = ctx
        .run
        .grading
        .forensics_history
        .read()
        .await
        .iter()
        .map(|sample| sample.unix_secs)
        .collect();
    let newest: Vec<f64> = (3..len + 3).map(|i| i as f64).collect();
    assert_eq!(kept, newest);
}
