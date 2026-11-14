use std::ffi::OsStr;
use std::path::{Component, Path, PathBuf};

/// Cargo uses either `build/<package>-<hash>/out` or
/// `build/<package>/<hash>/out` beneath the target's profile directory.
/// Match only those suffixes: a custom target root may itself contain `build`.
pub fn target_profile_dir(out_dir: &Path, package_name: &str) -> Option<PathBuf> {
    if out_dir.file_name() != Some(OsStr::new("out"))
        || out_dir
            .components()
            .any(|part| part == Component::ParentDir)
    {
        return None;
    }
    let artifact = out_dir.parent()?;
    let name = artifact.file_name()?.to_str()?;
    let build_dir = if let Some(hash) = name.strip_prefix(&format!("{package_name}-")) {
        if !is_cargo_hash(hash) {
            return None;
        }
        artifact.parent()?
    } else {
        if !is_cargo_hash(name) {
            return None;
        }
        let package_dir = artifact.parent()?;
        if package_dir.file_name() != Some(OsStr::new(package_name)) {
            return None;
        }
        package_dir.parent()?
    };
    if build_dir.file_name() != Some(OsStr::new("build")) {
        return None;
    }
    let profile_dir = build_dir.parent()?;
    profile_dir.file_name()?;
    Some(profile_dir.to_path_buf())
}

fn is_cargo_hash(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}
