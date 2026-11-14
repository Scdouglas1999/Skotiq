//! `save_path` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

/// Q3: `ensure_unique_save_path` tested existence and then returned the
/// path without claiming it, so two callers racing on the same rendered
/// filename both got the same path — two `captured_images` rows, one file,
/// one frame's pixels gone. Allocation must be atomic.
#[test]
fn concurrent_save_path_allocation_never_hands_out_the_same_file_twice() {
    let dir = std::env::temp_dir().join(format!("sk-save-path-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let contended = dir.join("Dark_nofilter_0001.fits");

    let handles: Vec<_> = (0..8)
        .map(|_| {
            let candidate = contended.clone();
            std::thread::spawn(move || ensure_unique_save_path(candidate))
        })
        .collect();
    let allocated: Vec<PathBuf> = handles
        .into_iter()
        .map(|h| h.join().expect("allocation thread"))
        .collect();

    let distinct: std::collections::HashSet<&PathBuf> = allocated.iter().collect();
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(
        distinct.len(),
        allocated.len(),
        "every concurrent caller must get its own file; got {allocated:?}"
    );
}

/// A Take Exposures frame is a kept frame: with camera files kept, the
/// camera's file lands beside the frame's FITS name, byte for byte.
#[tokio::test]
async fn a_sequence_frame_keeps_the_camera_file_when_the_run_does() {
    let scratch = scratch_dir("camera-file");
    let mut scripted = ScriptedDomeRotatorOps::new();
    scripted.scripted_camera_file = Some(skotiq_device::CameraFile {
        file_name: "IMG_0001.CR3".to_string(),
        bytes: Arc::new(b"cr3 bytes".to_vec()),
    });
    let ops = Arc::new(scripted);
    let mut ec = expose_node_execution_ctx(ops.clone(), scratch.0.clone()).await;
    ec.run.camera_file_saving = crate::CameraFileSaving::Both;

    let status = run_expose_node(one_dark_no_filter(), &mut ec).await;
    assert_eq!(status, NodeStatus::Success);

    let paths = ops.saved_frame_paths();
    assert_eq!(paths.len(), 1);
    let camera_path = std::path::Path::new(&paths[0]).with_extension("CR3");
    assert_eq!(std::fs::read(&camera_path).unwrap(), b"cr3 bytes");
}
