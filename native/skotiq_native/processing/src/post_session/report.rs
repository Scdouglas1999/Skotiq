//! What a post-session run reports while it runs, and who hears it.
//!
//! The pipeline is one synchronous descent, so progress leaves it as calls to
//! the process's listener instead of a return value. The host installs the
//! listener once ([`report_to`]); without one a report is dropped.

use std::sync::OnceLock;

/// One report from a running pass.
#[derive(Debug, Clone, PartialEq)]
pub enum PassReport {
    /// How far the integration is: the stage, the overall fraction in `0..=1`,
    /// and the frame count inside a per-frame stage.
    Progress {
        phase: String,
        fraction: f32,
        frames_done: Option<u32>,
        frames_total: Option<u32>,
    },
    /// A measurement for the pass view: the caller's run id, a kind from the
    /// vocabulary in [`super::telemetry`], and its details as a JSON object.
    Telemetry {
        run_id: String,
        kind: String,
        detail_json: String,
    },
}

static LISTENER: OnceLock<fn(PassReport)> = OnceLock::new();

/// Sends every report of this process to `listener`. The first listener
/// installed stays.
pub fn report_to(listener: fn(PassReport)) {
    LISTENER.get_or_init(|| listener);
}

pub(crate) fn report(report: PassReport) {
    if let Some(listener) = LISTENER.get() {
        listener(report);
    }
}
