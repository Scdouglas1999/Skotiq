#[path = "../build_support.rs"]
mod build_support;

use build_support::target_profile_dir;
use std::path::{Path, PathBuf};

const PACKAGE: &str = "skotiq_imaging";
const HASH: &str = "09a33ac4d11a0ae0";

fn out_dir(profile: &Path, split: bool) -> PathBuf {
    let build = profile.join("build");
    if split {
        build.join(PACKAGE).join(HASH).join("out")
    } else {
        build.join(format!("{PACKAGE}-{HASH}")).join("out")
    }
}

#[test]
fn resolves_both_cargo_layouts_without_assuming_the_target_directory_or_profile() {
    for profile in [
        Path::new("workspace/target/debug"),
        Path::new("workspace/target/release"),
        Path::new("workspace/target/x86_64-pc-windows-msvc/release"),
        Path::new("workspace/target/aarch64-pc-windows-msvc/custom-profile"),
        Path::new("cache/native-artifacts/optimized"),
        Path::new("cache/build/native-artifacts/build"),
        Path::new("cache/build/native-artifacts/x86_64-pc-windows-gnu/custom-profile"),
    ] {
        for split in [false, true] {
            let output = out_dir(profile, split);
            assert_eq!(
                target_profile_dir(&output, PACKAGE),
                Some(profile.to_path_buf()),
                "{}",
                output.display()
            );
        }
    }
}

#[test]
fn rejects_unknown_suffixes_instead_of_searching_for_an_ancestor_named_build() {
    for output in [
        "workspace/target/release/build/skotiq_imaging-09a33ac4d11a0ae0/cache",
        "workspace/target/release/build/skotiq_imaging/09a33ac4d11a0ae0/cache",
        "workspace/target/release/build/another_crate-09a33ac4d11a0ae0/out",
        "workspace/target/release/build/another_crate/09a33ac4d11a0ae0/out",
        "workspace/target/release/build/skotiq_imaging-/out",
        "workspace/target/release/build/skotiq_imaging/not-a-hash/out",
        "workspace/target/release/build/skotiq_imaging/extra/09a33ac4d11a0ae0/out",
        "workspace/target/release/build/skotiq_imaging/09a33ac4d11a0ae0/out/nested/out",
        "workspace/target/release/not-build/skotiq_imaging-09a33ac4d11a0ae0/out",
        "workspace/target/release/build/../skotiq_imaging/09a33ac4d11a0ae0/out",
        "build/skotiq_imaging-09a33ac4d11a0ae0/out",
        "out",
    ] {
        assert_eq!(
            target_profile_dir(Path::new(output), PACKAGE),
            None,
            "{output}"
        );
    }
}

#[cfg(windows)]
#[test]
fn resolves_the_mixed_separator_path_reported_by_windows_ci() {
    let output = Path::new(
        r"D:\a\Skotiq\Skotiq\native\skotiq_native\target\release\build\skotiq_imaging/09a33ac4d11a0ae0\out",
    );
    assert_eq!(
        target_profile_dir(output, PACKAGE),
        Some(PathBuf::from(
            r"D:\a\Skotiq\Skotiq\native\skotiq_native\target\release"
        ))
    );
}
