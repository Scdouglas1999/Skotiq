//! DepthLock on the host: durable goals, the analysis queue, and the hooks
//! that connect them to the capture path and the executor.
//!
//! Layering:
//! - `skotiq_imaging::depthlock` measures and decides (pure).
//! - [`store`] keeps goals and evidence durable and revision-checked.
//! - [`engine`] turns saved frames into evidence, commits analyses, and
//!   answers the executor's verdict queries.
//! - `crate::api::depthlock` exposes it to Dart; `crate::api::sequencer`'s
//!   event loop feeds it saved frames.

pub mod engine;
pub mod store;
#[cfg(test)]
mod tests;

use engine::DepthLockService;
use std::path::Path;
use std::sync::{Arc, OnceLock};

static SERVICE: OnceLock<Arc<DepthLockService>> = OnceLock::new();

/// Open the goal store under the settings directory and install the
/// service as the executor's verdict source. Called from settings-storage
/// initialization; idempotent.
pub fn init(settings_dir: &Path) -> Result<(), String> {
    if SERVICE.get().is_some() {
        return Ok(());
    }
    let runtime = crate::ensure_runtime().map_err(|e| e.to_string())?;
    let root = settings_dir.join("depthlock");
    let sink: engine::EventSink = Arc::new(|event| {
        crate::api::get_state().publish_event(event);
    });
    let service = DepthLockService::open(&root, sink, runtime.handle())?;
    let service = match SERVICE.set(service) {
        Ok(()) => SERVICE.get().expect("just set"),
        // Lost a race with another initializer; theirs is the one installed.
        Err(_) => SERVICE.get().expect("set by the winner"),
    };
    let verdicts: skotiq_sequencer::SharedDepthGoalOps = Arc::clone(service) as _;
    let executor = skotiq_sequencer::get_executor();
    match executor.try_write() {
        Ok(mut executor) => executor.set_depth_goal_ops(Some(verdicts)),
        // A run holds the executor; install as soon as it is free. Nothing
        // can start before the lock is released anyway.
        Err(_) => {
            runtime.spawn(async move {
                executor.write().await.set_depth_goal_ops(Some(verdicts));
            });
        }
    }
    tracing::info!("DepthLock goal store open at {}", root.display());
    Ok(())
}

pub fn service() -> Option<&'static Arc<DepthLockService>> {
    SERVICE.get()
}

/// Capture-path hook: a light the sequencer just saved. Cheap and
/// non-blocking; does nothing until the store is initialized.
pub fn notify_frame_saved(path: &str, frame_type: &str) {
    if !frame_type.eq_ignore_ascii_case("light") {
        return;
    }
    if let Some(service) = SERVICE.get() {
        service.notify_frame_saved(path);
    }
}
