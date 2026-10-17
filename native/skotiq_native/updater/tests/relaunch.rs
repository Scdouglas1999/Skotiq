//! The real `updater` binary against a scratch install whose "app" is a shell
//! script, so what the updater starts afterwards, and with what, can be seen.
//!
//! These cover what happens after the swap, which the unit tests in main.rs
//! cannot reach: the app the updater starts, whether it proves it came up, and
//! what the operator is left with when it does not.
#![cfg(unix)]

use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

struct Rig {
    _tmp: tempfile::TempDir,
    install: PathBuf,
    staging: PathBuf,
    backup: PathBuf,
    pending: PathBuf,
    hashes: PathBuf,
    log: PathBuf,
}

fn write_exec(path: &Path, body: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, body).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn sha(path: &Path) -> String {
    let mut h = Sha256::new();
    h.update(fs::read(path).unwrap());
    h.finalize().iter().map(|b| format!("{:02x}", b)).collect()
}

/// An install whose launcher records each start in `log`. `new_launcher` is
/// the body of the staged (new) launcher.
fn rig(new_launcher: &str) -> Rig {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().to_path_buf();
    let install = root.join("install");
    let staging = root.join("updates/staging/extracted");
    let backup = root.join("updates/backup");
    let pending = root.join("updates/pending_install.json");
    let hashes = root.join("updates/staging/expected_hashes.json");
    let log = root.join("starts.log");

    // Shipped Linux layout: `skotiq` is the launcher script the updater
    // relaunches; `skotiq.bin` is the real binary it execs.
    let old = format!("#!/bin/sh\necho \"old $*\" >> '{}'\n", log.display());
    write_exec(&install.join("skotiq"), &old);
    write_exec(&install.join("skotiq.bin"), "old binary");
    fs::create_dir_all(install.join("lib")).unwrap();
    fs::write(install.join("lib/libskotiq_bridge.so"), "old bridge").unwrap();

    let new = new_launcher
        .replace("@LOG@", &log.display().to_string())
        .replace("@PENDING@", &pending.display().to_string());
    write_exec(&staging.join("skotiq"), &new);
    write_exec(&staging.join("skotiq.bin"), "new binary");
    fs::create_dir_all(staging.join("lib")).unwrap();
    fs::write(staging.join("lib/libskotiq_bridge.so"), "new bridge").unwrap();

    let mut files = HashMap::new();
    for rel in ["skotiq", "skotiq.bin", "lib/libskotiq_bridge.so"] {
        files.insert(rel.to_string(), sha(&staging.join(rel)));
    }
    fs::write(&hashes, serde_json::json!({ "files": files }).to_string()).unwrap();
    fs::write(
        &pending,
        r#"{"targetVersion":"2.0.0","previousVersion":"1.0.0"}"#,
    )
    .unwrap();

    Rig {
        _tmp: tmp,
        install,
        staging,
        backup,
        pending,
        hashes,
        log,
    }
}

/// A pid that has certainly exited.
fn dead_pid() -> u32 {
    let mut child = Command::new("true").spawn().unwrap();
    let pid = child.id();
    child.wait().unwrap();
    pid
}

fn run_updater(r: &Rig, extra: &[&str]) -> std::process::Output {
    let tmpdir = r._tmp.path().join("tmp");
    fs::create_dir_all(&tmpdir).unwrap();
    Command::new(env!("CARGO_BIN_EXE_updater"))
        .env("TMPDIR", &tmpdir)
        .args(["--parent-pid", &dead_pid().to_string()])
        .arg("--staging-dir")
        .arg(&r.staging)
        .arg("--install-dir")
        .arg(&r.install)
        .arg("--backup-dir")
        .arg(&r.backup)
        .arg("--pending-file")
        .arg(&r.pending)
        .arg("--expected-hashes")
        .arg(&r.hashes)
        .arg("--launch-after")
        .args(extra)
        .output()
        .unwrap()
}

fn wait_for_log(log: &Path, needle: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let text = fs::read_to_string(log).unwrap_or_default();
        if text.contains(needle) || Instant::now() > deadline {
            return text;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn a_new_build_that_dies_on_startup_is_rolled_back_and_the_old_one_started() {
    // The new build exits before it gets far enough to consume the pending
    // marker, the way a build that crashes on startup does.
    let r = rig("#!/bin/sh\necho \"new $*\" >> '@LOG@'\nexit 1\n");
    let out = run_updater(&r, &["--confirm-timeout-secs", "20"]);

    assert!(
        !out.status.success(),
        "a failed start must not report success"
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("before it finished starting"), "{}", stderr);
    assert!(
        fs::read_to_string(r.install.join("skotiq"))
            .unwrap()
            .contains("old"),
        "the previous launcher must be back"
    );
    assert_eq!(
        fs::read_to_string(r.install.join("skotiq.bin")).unwrap(),
        "old binary"
    );
    let log = wait_for_log(&r.log, "old");
    assert!(
        log.contains("new"),
        "the new build was tried first: {}",
        log
    );
    assert!(
        log.contains("old"),
        "the previous build was started: {}",
        log
    );
    assert!(
        r.pending.exists(),
        "the marker stays so the restored build can report the rollback"
    );
}

#[test]
fn a_new_build_that_comes_up_is_kept_and_started_with_the_same_arguments() {
    // Consuming the pending marker is how a real build says it came up.
    let r = rig("#!/bin/sh\necho \"new $*\" >> '@LOG@'\nrm -f '@PENDING@'\nsleep 1\n");
    let out = run_updater(
        &r,
        &[
            "--relaunch-arg=--headless",
            "--relaunch-arg=--port=18931",
            "--confirm-timeout-secs",
            "20",
        ],
    );

    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(
        fs::read_to_string(r.install.join("skotiq.bin")).unwrap(),
        "new binary"
    );
    let log = wait_for_log(&r.log, "new");
    assert!(
        log.contains("new --headless --port=18931"),
        "the app must come back with the arguments it had: {}",
        log
    );
    assert!(
        r.backup.join("rollback_log.json").exists(),
        "the restore point is kept until the app reclaims it"
    );
}

#[test]
fn a_failed_apply_starts_the_previous_build_again() {
    // A staged file that no longer matches its hash fails the updater's own
    // verification after the swap; it rolls back, and must not leave the
    // operator with nothing running.
    let r = rig("#!/bin/sh\necho \"new $*\" >> '@LOG@'\n");
    fs::write(r.staging.join("skotiq.bin"), "tampered after staging").unwrap();
    let out = run_updater(&r, &["--relaunch-arg=--headless"]);

    assert!(!out.status.success());
    assert_eq!(
        fs::read_to_string(r.install.join("skotiq.bin")).unwrap(),
        "old binary"
    );
    let log = wait_for_log(&r.log, "old");
    assert!(log.contains("old --headless"), "{}", log);
    assert!(!log.contains("new"), "{}", log);
}

#[test]
fn a_build_refused_by_the_single_instance_lock_is_not_rolled_back() {
    // Exit 75 means another instance already holds the lock. The new build
    // did not fail; rolling it back would undo a good update.
    let r = rig("#!/bin/sh\necho \"new $*\" >> '@LOG@'\nexit 75\n");
    let out = run_updater(&r, &["--confirm-timeout-secs", "20"]);

    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(
        fs::read_to_string(r.install.join("skotiq.bin")).unwrap(),
        "new binary"
    );
}
