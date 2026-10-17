//! Live-stacking broadcast service.
//!
//! Process-wide rendezvous between the [`crate::NodeType::LiveStacking`]
//! instruction (writer) and the Dart-side broadcast endpoints
//! (readers). The instruction arms a [`BroadcastSession`] in this
//! module's static slot; the bridge's `api_broadcast_*` functions read
//! the slot to answer HTTP requests served by the Dart headless API.
//!
//! Why a single global session rather than a registry keyed by node id:
//!
//!   * Only one broadcast can be active at a time (a single TCP port
//!     is bound by the Dart-side broadcast handler).
//!   * The brief explicitly says "two LiveStacking nodes in the same
//!     sequence is a warning, not an error" — last-one-wins matches
//!     that.
//!   * The bridge layer activates / deactivates the slot on
//!     sequence start / stop, matching the lifecycle of every other
//!     active-state singleton in `skotiq_sequencer`.
//!
//! Thread-safety: the active-session slot is guarded by a parking_lot
//! [`Mutex`]. Reads are short (clone a small struct out and release),
//! writes are infrequent (one per sequence). The whole module is a
//! `OnceLock<Mutex<...>>` so the first access lazy-initialises the
//! state without an `unsafe` static initialiser.

use crate::{LiveStackingConfig, LiveStackingMode, StackMethod};
use parking_lot::Mutex;
use std::sync::OnceLock;

/// A live broadcast handoff between the sequencer instruction and the
/// Dart-side endpoints. Carries the originating node id (for telemetry)
/// plus the full config so HTTP handlers do not need to look anything
/// else up.
#[derive(Debug, Clone)]
pub struct BroadcastSession {
    /// `NodeDefinition.id` of the LiveStacking node that armed the
    /// session. Surfaced in logs and the broadcast `/info` endpoint.
    pub node_id: String,
    /// Configuration of the active broadcast (mode, port, watermark,
    /// stack method, …).
    pub config: LiveStackingConfig,
    /// Monotonic activation timestamp. Used by the broadcast `/info`
    /// endpoint to render "Broadcasting since 22:14:03".
    pub activated_at: chrono::DateTime<chrono::Utc>,
}

impl BroadcastSession {
    /// Build a fresh session from a node id and config.
    pub fn from_config(node_id: &str, config: &LiveStackingConfig) -> Self {
        Self {
            node_id: node_id.to_string(),
            config: config.clone(),
            activated_at: chrono::Utc::now(),
        }
    }

    /// Convenience: human-friendly stack-method label for the broadcast
    /// HTML page.
    pub fn stack_method_label(&self) -> &'static str {
        match self.config.stack_method {
            StackMethod::Average => "Average",
            StackMethod::MedianRej => "Median+Rej",
            StackMethod::Sigma => "Sigma-clipped",
        }
    }

    /// Convenience: human-friendly mode label.
    pub fn mode_label(&self) -> &'static str {
        match self.config.mode {
            LiveStackingMode::BroadcastOnly => "Broadcast only",
            LiveStackingMode::RecordAndBroadcast => "Record + broadcast",
        }
    }
}

fn slot() -> &'static Mutex<Option<BroadcastSession>> {
    static SLOT: OnceLock<Mutex<Option<BroadcastSession>>> = OnceLock::new();
    SLOT.get_or_init(|| Mutex::new(None))
}

/// Install a new broadcast session, returning the previously-active
/// session (if any) so the caller can log the replacement.
pub fn activate(session: BroadcastSession) -> Option<BroadcastSession> {
    let mut guard = slot().lock();
    let prev = guard.take();
    *guard = Some(session);
    prev
}

/// Snapshot of the currently active broadcast session, or `None`.
pub fn current() -> Option<BroadcastSession> {
    slot().lock().clone()
}

/// Tear down the active session. Called by the bridge on
/// `api_sequencer_stop` so a stopped sequence doesn't leave a stale
/// `/broadcast` page advertising itself as live.
pub fn deactivate() -> Option<BroadcastSession> {
    slot().lock().take()
}

/// Process-wide serialization for tests that touch the broadcast slot.
///
/// The slot is a single global; concurrent tests in `cargo test` interleave
/// `activate`/`current`/`deactivate` and trip each other's assertions
/// (e.g. test A's `current()` sees test B's session id). Every broadcast-
/// touching test in this crate takes this guard at function entry.
///
/// Test-only — production callers do not need it because the bridge only
/// drives broadcast lifecycle from a single sequence executor task.
#[cfg(test)]
pub(crate) fn test_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn activate_then_current_then_deactivate() {
        let _guard = test_lock();
        deactivate();
        let session = BroadcastSession::from_config(
            "node-1",
            &LiveStackingConfig {
                broadcast_port: 8081,
                ..LiveStackingConfig::default()
            },
        );
        assert!(activate(session.clone()).is_none());
        let now = current().expect("active session exists");
        assert_eq!(now.node_id, "node-1");
        assert_eq!(now.config.broadcast_port, 8081);

        let after = deactivate().expect("deactivate returns the previous");
        assert_eq!(after.node_id, "node-1");
        assert!(current().is_none());
    }

    #[test]
    fn activate_returns_previous_session_for_replacement_warning() {
        let _guard = test_lock();
        deactivate();
        activate(BroadcastSession::from_config(
            "node-A",
            &LiveStackingConfig::default(),
        ));
        let prev = activate(BroadcastSession::from_config(
            "node-B",
            &LiveStackingConfig::default(),
        ));
        assert!(prev.is_some());
        assert_eq!(prev.unwrap().node_id, "node-A");
        let cur = current().unwrap();
        assert_eq!(cur.node_id, "node-B");
        deactivate();
    }
}
