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
