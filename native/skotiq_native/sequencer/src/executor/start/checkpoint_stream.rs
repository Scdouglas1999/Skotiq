//! The checkpoint streamer: saves the run's checkpoint on a fixed cadence
//! while the run executes.

use super::*;

const CHECKPOINT_INTERVAL: std::time::Duration = std::time::Duration::from_secs(30);

/// Runs until the run is cancelled. Never returns for a run that keeps no
/// checkpoint, so the run's `select!` does not read it as a finished task.
pub(super) async fn run_checkpoint_stream(run: Arc<Run>) {
    let Some(writer) = run.checkpoint.as_ref() else {
        return std::future::pending::<()>().await;
    };
    let run_state = &run.control.state;
    let is_cancelled = &run.control.is_cancelled;
    let mut park_and_abort_done = run.teardown.park_done();

    let mut interval = tokio::time::interval(CHECKPOINT_INTERVAL);
    loop {
        interval.tick().await;

        if is_cancelled.load(Ordering::Acquire) {
            if run.teardown.parked_by_trigger() {
                if let Err(error) = park_and_abort_done.wait_for(|done| *done).await {
                    tracing::warn!(
                        "Checkpoint stream: the park-and-abort completion signal was dropped \
                         before the safe-state sweep reported done ({}); stopping checkpoints \
                         without the handshake",
                        error
                    );
                }
            }
            break;
        }

        // A run in recovery is saved too, so a crash during a long recovery
        // keeps the frames accepted before the failure.
        if !matches!(
            run_state.get(),
            ExecutorState::Running | ExecutorState::Paused | ExecutorState::Recovering
        ) {
            continue;
        }

        if let Err(e) = writer.save().await {
            tracing::warn!("Streaming checkpoint save failed: {}", e);
        }
    }
}
