//! Builds fake vendor SDKs and runs a test binary's fake-SDK tests against them.
//!
//! A vendor SDK is a process-wide library the driver finds on the loader
//! path. So the tests that drive a driver against a fake are `#[ignore]`d,
//! and a plain test of the same binary builds the fake into a folder of its
//! own and runs them in a child process with that folder first on
//! `LD_LIBRARY_PATH`. `cargo test` then runs every one of them on Linux.
//!
//! A traced build makes every function the fake exports append
//! `Name(scalar arguments)` to the file `$FAKE_SDK_TRACE` names, which is the
//! SDK call sequence a camera session records.

#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::process::Command;

/// One library of a fake SDK: its source under `tests/` and the file name
/// the driver loads.
#[derive(Clone, Copy)]
pub struct Library {
    pub source: &'static str,
    pub file_name: &'static str,
}

const fn library(source: &'static str, file_name: &'static str) -> Library {
    Library { source, file_name }
}

pub const ASI: Library = library("fake_sdk/asi.rs", "libASICamera2.so");
pub const EAF: Library = library("fake_sdk/eaf.rs", "libEAF_focuser.so");
pub const EFW: Library = library("fake_sdk/efw.rs", "libEFW_filter.so");
pub const ATIK: Library = library("fake_sdk/atik.rs", "libatikcameras.so");
pub const SVBONY: Library = library("fake_sdk/svbony.rs", "libSVBCameraSDK.so");
pub const PLAYER_ONE: Library = library("fake_sdk/player_one.rs", "libPlayerOneCamera.so");
pub const PLAYER_ONE_PW: Library = library("fake_sdk/player_one_pw.rs", "libPlayerOnePW.so");
pub const QHY: Library = library("fake_sdk/qhy.rs", "libqhyccd.so");
pub const TOUPTEK: Library = library("fake_sdk/touptek.rs", "libogmacam.so");
pub const FLI: Library = library("fake_sdk/fli.rs", "libfli.so");
pub const MORAVIAN: Library = library("fake_sdk/moravian.rs", "libgxccd.so");
pub const QHY_CONTRACT: Library = library("qhy_fake_sdk/libqhyccd.rs", "libqhyccd.so");
pub const QHY_VENDOR_MODEL: Library = library("qhy_vendor_model/libqhyccd.rs", "libqhyccd.so");
pub const GPHOTO2: Library = library("fake_sdk/gphoto2.rs", "libgphoto2.so");
pub const FLI_MODEL: Library = library("fake_sdk/libfli_model.c", "libfli.so");
pub const GPHOTO2_INDEPENDENT: Library =
    library("fake_sdk_linux/gphoto2_independent.c", "libgphoto2.so");
pub const TOUPTEK_INDEPENDENT: Library =
    library("fake_sdk_linux/touptek_independent.c", "libtoupcam.so");

/// The fake SDKs a camera driver's session loads, by vendor.
pub const CAMERA_FAKES: [(&str, &[Library]); 8] = [
    ("zwo", &[ASI, EAF, EFW]),
    ("atik", &[ATIK]),
    ("svbony", &[SVBONY]),
    ("player_one", &[PLAYER_ONE, PLAYER_ONE_PW]),
    ("qhy", &[QHY]),
    ("touptek", &[TOUPTEK]),
    ("fli", &[FLI]),
    ("moravian", &[MORAVIAN]),
];

/// A folder holding built fake libraries; removed when dropped.
pub struct FakeSdk {
    dir: PathBuf,
}

impl FakeSdk {
    /// Builds `libraries` into a new folder named after `name`.
    pub fn build(name: &str, libraries: &[Library]) -> Self {
        Self::build_with(name, libraries, false)
    }

    /// As [`Self::build`], with every exported function traced.
    pub fn build_traced(name: &str, libraries: &[Library]) -> Self {
        Self::build_with(name, libraries, true)
    }

    fn build_with(name: &str, libraries: &[Library], traced: bool) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "skotiq-fake-sdk-{}-{}-{}",
            name,
            std::process::id(),
            unique()
        ));
        std::fs::create_dir_all(&dir).expect("create the fake SDK folder");
        let fake = Self { dir };
        for library in libraries {
            fake.compile(library, traced);
        }
        fake
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    fn compile(&self, library: &Library, traced: bool) {
        let tests = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests");
        let source = tests.join(library.source);
        let output = self.dir.join(library.file_name);
        let built = if library.source.ends_with(".c") {
            Command::new(std::env::var("CC").unwrap_or_else(|_| "cc".to_string()))
                .args(["-O1", "-shared", "-fPIC", "-o"])
                .arg(&output)
                .arg(&source)
                .arg("-lpthread")
                .output()
        } else {
            let text = std::fs::read_to_string(&source)
                .unwrap_or_else(|e| panic!("read {}: {e}", source.display()));
            let text = if traced { traced_source(&text) } else { text };
            let staged = self
                .dir
                .join(format!("{}.rs", library.file_name.trim_end_matches(".so")));
            std::fs::write(&staged, text).expect("write the fake SDK source");
            Command::new(std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string()))
                .args(["--crate-type", "cdylib", "--edition", "2021", "-O"])
                .args(["-A", "warnings", "-o"])
                .arg(&output)
                .arg(&staged)
                .output()
        }
        .unwrap_or_else(|e| panic!("run the compiler for {}: {e}", library.source));
        assert!(
            built.status.success(),
            "the fake {} did not build:\n{}",
            library.source,
            String::from_utf8_lossy(&built.stderr)
        );
    }

    /// Runs the ignored tests of this test binary whose names contain
    /// `filter`, one at a time in one child process, with this fake first on
    /// the loader path. Panics with the child's output unless at least one
    /// test ran and all passed.
    pub fn run_ignored(&self, filter: &str, env: &[(&str, &str)]) {
        self.run(&["--ignored", "--test-threads", "1", filter], env);
    }

    /// Runs the ignored test named exactly `name` in a child process of its
    /// own.
    pub fn run_one(&self, name: &str, env: &[(&str, &str)]) {
        self.run(&["--ignored", "--exact", "--test-threads", "1", name], env);
    }

    /// Runs each ignored test whose name contains `filter` in a child
    /// process of its own, for fakes that keep one session per process.
    pub fn run_each(&self, filter: &str, env: &[(&str, &str)]) {
        let names = ignored_tests(filter);
        assert!(!names.is_empty(), "no ignored test matches {filter:?}");
        for name in names {
            self.run_one(&name, env);
        }
    }

    fn run(&self, args: &[&str], env: &[(&str, &str)]) {
        let run = Command::new(std::env::current_exe().expect("the test binary"))
            .args(args)
            .env("LD_LIBRARY_PATH", &self.dir)
            .envs(env.iter().copied())
            .output()
            .expect("run the fake-SDK tests");
        let report = format!(
            "{}{}",
            String::from_utf8_lossy(&run.stdout),
            String::from_utf8_lossy(&run.stderr)
        );
        assert!(
            run.status.success(),
            "fake-SDK tests {args:?} failed:\n{report}"
        );
        assert!(
            !report.contains("running 0 tests"),
            "no fake-SDK test matched {args:?}:\n{report}"
        );
    }
}

impl Drop for FakeSdk {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn unique() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

/// The names of this binary's ignored tests that contain `filter`.
fn ignored_tests(filter: &str) -> Vec<String> {
    let listed = Command::new(std::env::current_exe().expect("the test binary"))
        .args(["--ignored", "--list", filter])
        .output()
        .expect("list the ignored tests");
    String::from_utf8_lossy(&listed.stdout)
        .lines()
        .filter_map(|line| line.strip_suffix(": test"))
        .map(str::to_string)
        .collect()
}

/// The argument types a trace line prints.
const SCALARS: [&str; 20] = [
    "c_int", "c_long", "c_uint", "c_ulong", "c_double", "c_float", "bool", "f32", "f64", "i32",
    "u32", "i64", "u64", "c_uchar", "c_ushort", "c_short", "u8", "u16", "i16", "usize",
];

const TRACE_WRITER: &str = r#"
fn __trace(line: String) {
    use std::io::Write;
    if let Ok(path) = std::env::var("FAKE_SDK_TRACE") {
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{}", line);
        }
    }
}
"#;

/// `source` with a trace line at the start of every exported function: the
/// function's name and its scalar arguments, in order.
fn traced_source(source: &str) -> String {
    const EXPORT: &str = "#[no_mangle] pub ";
    let mut out = String::with_capacity(source.len() * 2);
    let mut rest = source;
    while let Some(at) = rest.find(EXPORT) {
        let (before, from) = rest.split_at(at);
        out.push_str(before);
        let Some(body) = from.find('{') else {
            break;
        };
        let signature = &from[..body];
        out.push_str(signature);
        out.push('{');
        if let Some(call) = trace_call(signature) {
            out.push_str(&call);
        }
        rest = &from[body + 1..];
    }
    out.push_str(rest);
    out.push_str(TRACE_WRITER);
    out
}

/// `__trace(...)` for an exported `extern "C" fn` signature.
fn trace_call(signature: &str) -> Option<String> {
    let after_fn = &signature[signature.find("extern \"C\" fn ")? + "extern \"C\" fn ".len()..];
    let open = after_fn.find('(')?;
    let name = after_fn[..open].trim();
    let close = after_fn.find(')')?;
    let mut format = Vec::new();
    let mut values = Vec::new();
    for argument in after_fn[open + 1..close].split(',') {
        let Some((argument, ty)) = argument.split_once(':') else {
            continue;
        };
        let argument = argument.trim().trim_start_matches("mut ").trim();
        if SCALARS.contains(&ty.trim()) {
            format.push("{:?}");
            values.push(format!(", {argument}"));
        }
    }
    Some(format!(
        " __trace(format!(\"{}({})\"{})); ",
        name,
        format.join(","),
        values.concat()
    ))
}
