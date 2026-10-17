use std::env;
#[cfg(target_os = "windows")]
use std::path::Path;
use std::path::PathBuf;

fn main() {
    cc::Build::new()
        .file("src/libraw_shim.c")
        .include("vendor/libraw")
        .warnings(false)
        .compile("skotiq_libraw_shim");

    println!("cargo:rerun-if-changed=src/libraw_shim.c");
    println!("cargo:rerun-if-changed=vendor/libraw/libraw_const.h");
    println!("cargo:rerun-if-changed=vendor/libraw/libraw_types.h");
    println!("cargo:rerun-if-changed=vendor/libraw/libraw_version.h");
    println!("cargo:rerun-if-changed=build.rs");

    // Get the workspace root (where libraw.dll/.lib lives)
    // CARGO_MANIFEST_DIR is native/skotiq_native/imaging
    // We need to go up 3 levels to reach the workspace root
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set");
    let workspace_root = PathBuf::from(&manifest_dir)
        .parent() // native/skotiq_native
        .and_then(|p| p.parent()) // native
        .and_then(|p| p.parent()) // workspace root
        .expect("Failed to find workspace root")
        .to_path_buf();

    // Why: version.yaml is the single source of truth for the user-facing
    // product version. Cargo.toml is pinned at 0.1.0 and would mislead
    // downstream consumers (XISF Creator field, FITS history, etc.).
    let version_yaml = workspace_root.join("version.yaml");
    println!("cargo:rerun-if-changed={}", version_yaml.display());
    let skotiq_version = read_skotiq_version(&version_yaml).unwrap_or_else(|err| {
        // Refuse to silently fall back to a fake version.
        panic!(
            "build.rs: unable to determine Skotiq version from {}: {}",
            version_yaml.display(),
            err
        );
    });
    println!("cargo:rustc-env=SKOTIQ_VERSION={}", skotiq_version);

    // Platform-specific library configuration
    #[cfg(target_os = "windows")]
    {
        // Windows: use bundled libraw.dll/.lib
        let libraw_dir = env::var("LIBRAW_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| workspace_root.join("lib").join("libraw"));

        let search_dir = if libraw_dir.exists() {
            libraw_dir
        } else {
            workspace_root.clone()
        };

        println!("cargo:rustc-link-search=native={}", search_dir.display());
        println!("cargo:rustc-link-lib=dylib=libraw");
        let libraw_dll = search_dir.join("libraw.dll");
        println!("cargo:rerun-if-changed={}", libraw_dll.display());
        println!("cargo:rerun-if-env-changed=LIBRAW_DIR");

        let libraw_lib = search_dir.join("libraw.lib");
        if !libraw_lib.exists() {
            println!(
                "cargo:warning=libraw.lib not found at: {}",
                libraw_lib.display()
            );
            println!("cargo:warning=Set LIBRAW_DIR environment variable or place libraw.lib in workspace root");
        } else {
            println!("cargo:rustc-env=LIBRAW_PATH={}", search_dir.display());
        }

        // Auto-deploy libraw.dll next to the test/binary outputs so that
        // `cargo test --package skotiq_bridge` (and other workspace
        // crates that link libraw transitively) finds the DLL without
        // requiring a manual `scripts\copy_libraw.ps1` run.
        //
        // Windows resolves DLLs from the directory of the loading binary.
        // Cargo places binaries here:
        //   * Unit tests   -> target/<profile>/deps/<crate>-<hash>.exe
        //   * Integration  -> target/<profile>/deps/<test>-<hash>.exe
        //   * Examples     -> target/<profile>/examples/<name>.exe
        //   * Main binary  -> target/<profile>/<name>.exe
        //
        // A missing source DLL panics so a misconfigured checkout fails
        // loudly at build time rather than surfacing as an opaque
        // STATUS_DLL_NOT_FOUND at test runtime.
        if !libraw_dll.exists() {
            panic!(
                "build.rs: libraw.dll not found at {}. \
                 Run scripts\\copy_libraw.ps1 or set LIBRAW_DIR to point at \
                 the directory containing libraw.dll/libraw.lib.",
                libraw_dll.display()
            );
        }

        let target_profile_dir = resolve_target_profile_dir()
            .expect("build.rs: unable to locate cargo target/<profile> directory from OUT_DIR");

        for dest_dir in [
            target_profile_dir.clone(),
            target_profile_dir.join("deps"),
            target_profile_dir.join("examples"),
        ] {
            copy_dll_to(&libraw_dll, &dest_dir);
        }
    }

    #[cfg(target_os = "linux")]
    {
        // Linux: use system libraw from package manager
        // The library is named libraw.so, so we link with -lraw
        println!("cargo:rustc-link-lib=dylib=raw");

        // Also check common system library paths. The multiarch dir is
        // arch-specific (`x86_64-linux-gnu` on a PC, `aarch64-linux-gnu` on a
        // Raspberry Pi / arm64 box), so derive it from the build target rather
        // than hardcoding x86_64 — otherwise an arm64 appliance build looks in
        // the wrong directory and only links by luck via the fallback paths.
        println!("cargo:rustc-link-search=native=/usr/lib");
        println!("cargo:rustc-link-search=native=/usr/local/lib");
        if let Ok(arch) = std::env::var("CARGO_CFG_TARGET_ARCH") {
            // CARGO_CFG_TARGET_ARCH is `x86_64` / `aarch64` / `arm`; the Debian
            // multiarch tuple is `<arch>-linux-gnu` (arm uses the gnueabihf abi).
            let multiarch = if arch == "arm" {
                "arm-linux-gnueabihf".to_string()
            } else {
                format!("{arch}-linux-gnu")
            };
            println!("cargo:rustc-link-search=native=/usr/lib/{multiarch}");
        } else {
            // Fallback for the common desktop case if the env var is missing.
            println!("cargo:rustc-link-search=native=/usr/lib/x86_64-linux-gnu");
        }
    }

    #[cfg(target_os = "macos")]
    {
        // macOS: use system libraw (via Homebrew or similar)
        println!("cargo:rustc-link-lib=dylib=raw");

        // Homebrew paths
        println!("cargo:rustc-link-search=native=/usr/local/lib");
        println!("cargo:rustc-link-search=native=/opt/homebrew/lib");
    }
}

/// Resolve the cargo `target/<profile>` directory from `OUT_DIR`.
///
/// `OUT_DIR` is of the form
/// `<target_dir>/<profile>/build/<crate>-<hash>/out`
/// (and gets an extra `<triple>` segment when `--target` is used).
/// We walk up from `out` until we find an ancestor whose own parent is a
/// directory named `build`; that ancestor's grandparent is the
/// `<profile>` directory we want.
///
/// Why: hard-coding `target/debug` fails for release builds, `--target`
/// triple builds, and workspaces that override `target-dir`. Walking up
/// from `OUT_DIR` is the canonical way to find the profile dir.
#[cfg(target_os = "windows")]
fn resolve_target_profile_dir() -> Option<PathBuf> {
    let out_dir = env::var_os("OUT_DIR")?;
    let out_dir = PathBuf::from(out_dir);
    // out_dir = .../target/<profile>/build/<crate>-<hash>/out
    //                  ^^^^^^^^^^^^^^^^^ what we want is two parents above `build`
    let build_dir = out_dir.parent()?.parent()?; // .../target/<profile>/build
    if build_dir.file_name().and_then(|s| s.to_str()) != Some("build") {
        return None;
    }
    Some(build_dir.parent()?.to_path_buf())
}

#[cfg(target_os = "windows")]
fn copy_dll_to(source: &Path, dest_dir: &Path) {
    // Why: cargo creates target/<profile>/ eagerly but `deps/` and
    // `examples/` only appear once the corresponding artifacts are built.
    // Pre-creating them here is harmless and makes the copy idempotent.
    if let Err(err) = std::fs::create_dir_all(dest_dir) {
        panic!(
            "build.rs: failed to create directory {}: {}",
            dest_dir.display(),
            err
        );
    }
    let dest_path = dest_dir.join(
        source
            .file_name()
            .expect("build.rs: source DLL path has no file name"),
    );

    // Skip the copy if the destination already matches the source byte-for-byte.
    // `cargo:rerun-if-changed` covers most cases, but build scripts re-execute
    // whenever any cargo-tracked dependency changes, so this short-circuit
    // avoids needless disk churn and avoids racing with a concurrently-running
    // test binary that has the DLL memory-mapped.
    if dlls_match(source, &dest_path) {
        return;
    }

    if let Err(err) = std::fs::copy(source, &dest_path) {
        // Surface the failure rather than letting the test binary hit
        // STATUS_DLL_NOT_FOUND at runtime. The one exception
        // is ERROR_SHARING_VIOLATION (32) / ERROR_ACCESS_DENIED (5), which
        // means the DLL is currently loaded by another process (e.g. a
        // running test). In that case the existing copy is already correct
        // because `dlls_match` short-circuited if it matched, so a mismatch
        // here is a real problem — but if the on-disk file already exists
        // we emit a warning instead of failing the build, since the next
        // clean invocation will refresh it.
        if dest_path.exists() {
            println!(
                "cargo:warning=build.rs: could not refresh {} ({}). \
                 Existing copy left in place; run `cargo clean` if you \
                 updated libraw.dll.",
                dest_path.display(),
                err
            );
        } else {
            panic!(
                "build.rs: failed to copy {} -> {}: {}",
                source.display(),
                dest_path.display(),
                err
            );
        }
    }
}

/// Returns true if the two paths exist and have identical length + mtime.
///
/// Why not byte-compare? libraw.dll is ~1 MiB and this runs on every
/// build script invocation. Length + mtime is the same heuristic cargo
/// itself uses for staleness tracking and is more than sufficient when
/// the source is a tracked binary that only changes via git.
#[cfg(target_os = "windows")]
fn dlls_match(a: &Path, b: &Path) -> bool {
    let (Ok(am), Ok(bm)) = (std::fs::metadata(a), std::fs::metadata(b)) else {
        return false;
    };
    if am.len() != bm.len() {
        return false;
    }
    match (am.modified(), bm.modified()) {
        (Ok(at), Ok(bt)) => at == bt,
        _ => false,
    }
}

/// Extract the `version: "X.Y.Z"` field from `version.yaml`.
///
/// Why: avoid pulling a YAML dependency into build.rs for one scalar string.
/// The format is fixed by the project (see `version.yaml` in repo root).
fn read_skotiq_version(path: &std::path::Path) -> Result<String, String> {
    let contents = std::fs::read_to_string(path)
        .map_err(|err| format!("failed to read {}: {}", path.display(), err))?;
    for raw_line in contents.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some(rest) = line.strip_prefix("version:") else {
            continue;
        };
        let value = rest.trim();
        // Tolerate both `"2.5.0"` and `2.5.0` (YAML allows unquoted scalars).
        let stripped = value
            .strip_prefix('"')
            .and_then(|s| s.strip_suffix('"'))
            .or_else(|| value.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')))
            .unwrap_or(value);
        if stripped.is_empty() {
            return Err(format!("`version:` key in {} is empty", path.display()));
        }
        return Ok(stripped.to_string());
    }
    Err(format!("`version:` key not found in {}", path.display()))
}
