//! Polled cancellation for the post-session pipeline.
//!
//! A post-session call is a single synchronous FFI descent: once Dart has
//! entered [`integrate_session`] there is no await point to cancel and no
//! task to abort. Safing therefore needs a flag the native loops read, which is
//! the one piece of shared state this module owns — the pipeline itself stays
//! stateless per call.
//!
//! Tokens are keyed by the caller's run id so a cancellation aimed at one run
//! can never stop the next one. A run started without a run id is not
//! cancellable, and says so rather than pretending otherwise.
//!
//! Cancellation is checked at every stage boundary and inside the per-frame
//! loops, and always **before** the master is written. Once the master exists on
//! disk the run finishes normally: reporting a cancelled run while a complete
//! master sits beside it would misdescribe what is on disk.

use crate::run_cancel::CancelRegistry;
pub(crate) use crate::run_cancel::CancelToken;
use serde::{Deserialize, Serialize};

/// The `kind` discriminator every cancelled post-session call carries.
pub(crate) const CANCELLED_KIND: &str = "cancelled";

/// The cancellation flags of post-session runs, keyed by run id.
pub(crate) static RUNS: CancelRegistry = CancelRegistry::new("post-session run");

/// The typed outcome a cancelled run returns as its `Err` payload: the JSON
/// encoding of this struct, so a caller decodes it instead of matching on prose.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CancelledOutcome {
    /// Always [`CANCELLED_KIND`].
    pub(crate) kind: String,
    pub(crate) run_id: String,
    /// The pipeline stage the run stopped at, from the same vocabulary the
    /// integration progress events publish.
    pub(crate) stage: String,
    /// Frames finished in that stage when it is a per-frame loop.
    pub(crate) frames_done: Option<u32>,
    pub(crate) frames_total: Option<u32>,
}

/// `Err` carrying the encoded [`CancelledOutcome`] when the run holding
/// `token` has been cancelled, `Ok(())` otherwise. Called at every stage
/// boundary and inside the per-frame loops.
pub(crate) fn check_stage(
    token: &CancelToken,
    stage: &str,
    frames_done: Option<u32>,
    frames_total: Option<u32>,
) -> Result<(), String> {
    if !token.is_cancelled() {
        return Ok(());
    }
    let outcome = CancelledOutcome {
        kind: CANCELLED_KIND.to_string(),
        run_id: token.id().to_string(),
        stage: stage.to_string(),
        frames_done,
        frames_total,
    };
    // The encoding cannot fail for this shape; if it somehow did, the run
    // must still stop, so fall back to the discriminator alone.
    Err(serde_json::to_string(&outcome).unwrap_or_else(|_| CANCELLED_KIND.to_string()))
}

/// Request for [`post_session_cancel`].
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub(crate) struct PostSessionCancelArgs {
    /// `"cancel"` (default) | `"status"` | `"clear"`.
    pub(crate) op: String,
    /// The run id the caller passed to the post-session entry point.
    pub(crate) run_id: String,
}

/// Response for [`post_session_cancel`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PostSessionCancelResult {
    pub(crate) run_id: String,
    /// The op that ran.
    pub(crate) op: String,
    /// `true` when a post-session call is executing under this id right now.
    /// `false` after a `cancel` means the flag is pre-armed for a run that has
    /// not started (or has already finished) — not that the request was lost.
    pub(crate) running: bool,
    /// The run's cancellation flag after the op.
    pub(crate) cancel_requested: bool,
}

/// Dispatch one cancellation op. See [`post_session_cancel`].
pub(crate) fn cancel_op(args: PostSessionCancelArgs) -> Result<PostSessionCancelResult, String> {
    let id = args.run_id.trim();
    if id.is_empty() {
        return Err("runId is required".to_string());
    }
    let op = match args.op.trim() {
        "" => "cancel",
        other => other,
    };
    let state = match op {
        "cancel" => RUNS.request_cancel(id)?,
        "status" => RUNS.status(id),
        "clear" => RUNS.clear(id)?,
        other => {
            return Err(format!(
                "unknown cancel op '{other}'; expected cancel/status/clear"
            ))
        }
    };

    Ok(PostSessionCancelResult {
        run_id: id.to_string(),
        op: op.to_string(),
        running: state.running,
        cancel_requested: state.cancel_requested,
    })
}
