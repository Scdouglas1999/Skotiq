//! `grading` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

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
fn reject_dir_absolute_override_used_verbatim() {
    // Use platform-appropriate absolute path.
    #[cfg(windows)]
    let abs = r"C:\skotiq\rejects";
    #[cfg(not(windows))]
    let abs = "/var/skotiq/rejects";

    let base = std::path::Path::new("/captures/M31/L");
    let dir = resolve_reject_dir(base, Some(abs));
    assert_eq!(dir, std::path::Path::new(abs));
}
