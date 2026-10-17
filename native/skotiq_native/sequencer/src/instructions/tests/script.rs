//! `script` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

/// A Run Script node created from the palette carries no `timeout_secs`
/// (the Dart `ScriptNode.timeoutSecs` is a nullable field with no default)
/// while the editor displays 300, so refusing to run in that state makes
/// every freshly added Run Script node dead on arrival: "Script timeout_secs
/// is required in fail-closed mode", script never spawned.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn script_without_timeout_runs_under_the_default_timeout() {
    let marker = std::env::temp_dir().join(format!(
        "skotiq_script_default_timeout_{}.txt",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&marker);

    let cfg = ScriptConfig {
        script_path: "/bin/sh".to_string(),
        arguments: vec!["-c".to_string(), format!("echo ran > {}", marker.display())],
        timeout_secs: None,
    };

    let ctx = script_ctx().await;
    let ec = crate::node::context::ExecutionContext::new_for_test("test-node".to_string());
    let result = execute_script(&cfg, &ctx, &ec, &empty_frame()).await;

    let ran =
        std::fs::read_to_string(&marker).expect("the script must create its completion marker");
    let _ = std::fs::remove_file(&marker);

    assert_eq!(
        result.status,
        NodeStatus::Success,
        "a script with no explicit timeout must run under the default; got {:?}",
        result.message
    );
    assert_eq!(
        ran.trim(),
        "ran",
        "the script must actually execute, not be refused before spawn"
    );
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn script_timeout_returns_failure_and_kills_child() {
    let dir = std::env::temp_dir();
    let pidfile = dir.join(format!("skotiq_script_test_{}.pid", std::process::id()));
    let _ = std::fs::remove_file(&pidfile);

    // sh records its own PID, then sleeps far past the 1s timeout.
    let cfg = ScriptConfig {
        script_path: "/bin/sh".to_string(),
        arguments: vec![
            "-c".to_string(),
            format!("echo $$ > {}; sleep 60", pidfile.display()),
        ],
        timeout_secs: Some(1),
    };

    let ctx = script_ctx().await;
    let ec = crate::node::context::ExecutionContext::new_for_test("test-node".to_string());
    let frame = empty_frame();

    let result = execute_script(&cfg, &ctx, &ec, &frame).await;

    // Invariant: identical timeout failure message.
    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(
        result.message.as_deref(),
        Some("Script timed out after 1 seconds"),
        "timeout must surface the exact existing failure text"
    );

    // The child must no longer be running once the call returns.
    let pid: u32 = std::fs::read_to_string(&pidfile)
        .expect("script should have written its PID before sleeping")
        .trim()
        .parse()
        .expect("PID file should contain a number");

    // kill_on_drop reaps via the runtime's background reaper; give it a
    // brief, bounded window to observe the process leave the run queue.
    let mut alive = true;
    for _ in 0..50 {
        if !pid_is_running(pid) {
            alive = false;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let _ = std::fs::remove_file(&pidfile);
    assert!(
        !alive,
        "child PID {pid} is still running after the script timed out — process was orphaned"
    );
}

/// A script that backgrounds work (`some_cmd &`) and then times out must
/// leave NO descendant running. `kill_on_drop` reaps only the direct child, so
/// the child is spawned in its own process group and the group is SIGKILLed,
/// taking the backgrounded grandchild with it.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn script_timeout_kills_backgrounded_grandchild() {
    let dir = std::env::temp_dir();
    let gcfile = dir.join(format!("skotiq_script_gc_{}.pid", std::process::id()));
    let _ = std::fs::remove_file(&gcfile);

    // sh backgrounds a 60s sleep (the grandchild), records its PID, then
    // `wait`s past the 1s timeout. The grandchild shares sh's process group.
    let cfg = ScriptConfig {
        script_path: "/bin/sh".to_string(),
        arguments: vec![
            "-c".to_string(),
            format!("sleep 60 & echo $! > {}; wait", gcfile.display()),
        ],
        timeout_secs: Some(1),
    };

    let ctx = script_ctx().await;
    let ec = crate::node::context::ExecutionContext::new_for_test("test-node".to_string());
    let frame = empty_frame();

    let result = execute_script(&cfg, &ctx, &ec, &frame).await;

    // Invariant: identical timeout failure message.
    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(
        result.message.as_deref(),
        Some("Script timed out after 1 seconds"),
        "timeout must surface the exact existing failure text"
    );

    let gc_pid: u32 = std::fs::read_to_string(&gcfile)
        .expect("script should have written its backgrounded grandchild PID")
        .trim()
        .parse()
        .expect("grandchild PID file should contain a number");

    // The group kill races a reparent+reap; give it a brief bounded window.
    let mut alive = true;
    for _ in 0..50 {
        if !pid_is_running(gc_pid) {
            alive = false;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let _ = std::fs::remove_file(&gcfile);
    assert!(
        !alive,
        "backgrounded grandchild PID {gc_pid} survived the timeout — the script's \
             process group was not torn down"
    );
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn script_success_surfaces_stdout_stderr_exit_code() {
    // The success path must surface stdout/stderr/exit_code.
    let cfg = ScriptConfig {
        script_path: "/bin/sh".to_string(),
        arguments: vec![
            "-c".to_string(),
            "echo out; echo err 1>&2; exit 0".to_string(),
        ],
        timeout_secs: Some(10),
    };
    let ctx = script_ctx().await;
    let ec = crate::node::context::ExecutionContext::new_for_test("test-node".to_string());
    let frame = empty_frame();

    let result = execute_script(&cfg, &ctx, &ec, &frame).await;
    assert_eq!(result.status, NodeStatus::Success);
    let data = result.data.expect("success must carry script output data");
    assert_eq!(data["stdout"].as_str().unwrap().trim(), "out");
    assert_eq!(data["stderr"].as_str().unwrap().trim(), "err");
    assert_eq!(data["exit_code"].as_i64(), Some(0));
}
