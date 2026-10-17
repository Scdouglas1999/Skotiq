//! `script.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Script instruction

/// Effective timeout applied to a Run Script node that carries no explicit
/// `timeout_secs`.
///
/// This is the single source of truth for "how long may an unconfigured script
/// run". The Dart node editor renders the same 300 s as the field's value, so
/// the number the operator reads is the number the executor enforces; the
/// duration estimator and the node's Timing card must use this value too.
pub const DEFAULT_SCRIPT_TIMEOUT_SECS: u32 = 300;

/// Execute script. expanded the env-var contract: every variable
/// declared in `expressions::catalog` is exposed as `SKOTIQ_<NAME>`
/// where `NAME` is the dotted variable converted to UPPER_SNAKE
/// (e.g. `target.alt` → `SKOTIQ_TARGET_ALT`). Variables that fail to
/// resolve are simply omitted (a missing env var is a normal "no data"
/// signal to a shell script, unlike a `${...}` template inside an
/// argument which is a hard failure).
pub async fn execute_script(
    config: &ScriptConfig,
    ctx: &InstructionContext,
    exec_ctx: &crate::node::context::ExecutionContext,
    frame: &crate::expressions::EvaluationFrame,
) -> InstructionResult {
    tracing::info!(
        "Running script: {} {:?}",
        config.script_path,
        config.arguments
    );

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    // Build the command
    let mut cmd = tokio::process::Command::new(&config.script_path);
    cmd.args(&config.arguments);

    // Expose every catalog variable as an env var. Anything that does not
    // resolve (e.g. `target.alt` without an observer location) is silently
    // skipped — the script can detect missing data via `env -u` semantics.
    // We deliberately do NOT propagate InterpolationError here: an env-var
    // contract is "this MAY be present", whereas an argument template's
    // contract is "this MUST resolve".
    for entry in crate::expressions::variable_catalog() {
        if let Ok(value) = crate::expressions::resolve_variable(entry.name, 0, exec_ctx, frame) {
            let env_name = format!(
                "SKOTIQ_{}",
                crate::expressions::catalog_name_to_env(entry.name)
            );
            cmd.env(
                env_name,
                crate::expressions::format_variable_for_env(&value),
            );
        }
    }

    // Set timeout. An absent timeout is NOT an unsafe state: the bounded
    // [`DEFAULT_SCRIPT_TIMEOUT_SECS`] fallback is itself fail-closed (the child
    // is still killed and reaped), and it is the value the node editor shows as
    // the effective timeout. Rejecting `None` outright — as the 2026-02
    // fail-closed sweep did — made every freshly added Run Script node refuse to
    // run with "timeout_secs is required" while the panel displayed 300, so the
    // node was unusable until the operator retyped the number it already showed.
    // An explicit zero stays an error: that is a real contradiction (run the
    // script, but kill it immediately), not a missing value.
    let timeout = match config.timeout_secs {
        // Why: u32 -> u64 widening is lossless.
        Some(v) if v > 0 => u64::from(v),
        Some(_) => {
            return InstructionResult::failure(
                "Script timeout_secs must be greater than zero".to_string(),
            )
        }
        None => u64::from(DEFAULT_SCRIPT_TIMEOUT_SECS),
    };

    // Reap the child when the spawned future is dropped (timeout / cancel).
    // Without this, racing `cmd.output()` against a timeout abandons the OS
    // process still running and unreaped → orphaned/zombie. `kill_on_drop`
    // makes the dropped future SIGKILL and `wait()` the child for us. The
    // piped stdio mirrors what `cmd.output()` set implicitly so the success
    // path still captures stdout/stderr.
    cmd.kill_on_drop(true);
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());

    // Isolate the child in its OWN process group (pgid == child pid).
    // `kill_on_drop` SIGKILLs only the *direct* child, so a script that
    // backgrounds work (`some_cmd &`) leaves those grandchildren running after a
    // timeout/cancel. With the child in its own group we can SIGKILL `-pgid` on
    // abort to tear the whole group down without ever touching the sequencer's
    // own process group. The happy path is unaffected — group isolation changes
    // neither stdio capture nor the child's exit status.
    #[cfg(unix)]
    cmd.process_group(0);

    let child = match cmd.spawn() {
        Ok(child) => child,
        Err(e) => return InstructionResult::failure(format!("Failed to run script: {}", e)),
    };
    // Capture the pid (== pgid under `process_group(0)`) before `wait_with_output`
    // consumes `child`, so the abort path can signal the whole group.
    #[cfg(unix)]
    let child_pid = child.id();

    // Race the script against its timeout and the cancellation token. When a
    // non-output arm wins, the `wait_with_output` future (which owns `child`)
    // is dropped, and `kill_on_drop` kills+reaps the process.
    let result = tokio::select! {
        output = child.wait_with_output() => Ok(output),
        _ = tokio::time::sleep(Duration::from_secs(timeout)) => Err(Abort::Timeout),
        _ = wait_for_cancellation(ctx.cancellation_token.clone()) => Err(Abort::Cancelled),
    };

    match result {
        Ok(Ok(output)) => {
            if output.status.success() {
                let stdout = String::from_utf8_lossy(&output.stdout);
                tracing::info!("Script output: {}", stdout);
                InstructionResult {
                    status: NodeStatus::Success,
                    message: Some(format!("Script {} completed", config.script_path)),
                    data: Some(serde_json::json!({
                        "stdout": stdout.to_string(),
                        "stderr": String::from_utf8_lossy(&output.stderr).to_string(),
                        "exit_code": output.status.code(),
                    })),
                    hfr_values: Vec::new(),
                }
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                InstructionResult::failure(format!("Script failed: {}", stderr))
            }
        }
        Ok(Err(e)) => InstructionResult::failure(format!("Failed to run script: {}", e)),
        Err(abort) => {
            // The losing `wait_with_output` future has been dropped, so
            // `kill_on_drop` already SIGKILLed the direct child; now reap the rest
            // of its process group (any backgrounded grandchildren) so nothing the
            // script spawned survives the abort. Unix-only; elsewhere we
            // retain the existing direct-child `kill_on_drop` behaviour.
            #[cfg(unix)]
            kill_script_process_group(child_pid);
            match abort {
                Abort::Timeout => InstructionResult::failure(format!(
                    "Script timed out after {} seconds",
                    timeout
                )),
                Abort::Cancelled => InstructionResult::cancelled("Script cancelled"),
            }
        }
    }
}

/// SIGKILL a timed-out/cancelled script's entire process group (Unix only).
///
/// `execute_script` spawns the child with `process_group(0)`, so `pgid == pid`.
/// `kill(2)` with a NEGATIVE pid delivers the signal to that whole process
/// group, reaching backgrounded grandchildren (`some_cmd &`) that a
/// `kill_on_drop` of the direct child alone would orphan. Reparented descendants
/// are reaped by the subreaper/init once signalled. A no-op when the pid is
/// unknown.
///
/// We call `kill(2)` directly rather than shelling out to `kill -KILL -<pgid>`:
/// the negative-pgid group syntax is parsed inconsistently across `kill(1)`
/// implementations (the bash builtin accepts it; some standalone util-linux
/// `kill` binaries — e.g. on CI runners — reject `-<pgid>` as a bad option), and
/// a misparse there silently leaks the group because the non-zero exit is
/// ignored. The syscall has no such ambiguity.
#[cfg(unix)]
pub(crate) fn kill_script_process_group(pid: Option<u32>) {
    let Some(pid) = pid else {
        return;
    };
    let pgid = pid as libc::pid_t;
    // SAFETY: `kill(2)` is async-signal-safe and takes no pointers. A negative
    // target signals the process group `pgid`. The only expected failure is
    // ESRCH (the group already fully exited — a benign abort/exit race), which
    // needs no handling, so the return value is intentionally ignored.
    unsafe {
        libc::kill(-pgid, libc::SIGKILL);
    }
}

/// Reason a running script was aborted before it could exit on its own.
pub(crate) enum Abort {
    Timeout,
    Cancelled,
}
