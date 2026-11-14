use skotiq_sequencer::{ExecutorState, SequenceProgress};

pub mod event_bridge;
pub mod event_translation;
pub mod lifecycle;
pub mod mosaic;
pub mod runtime_config;

/// Get the global sequence executor instance
pub(crate) fn get_sequence_executor(
) -> &'static std::sync::Arc<tokio::sync::RwLock<skotiq_sequencer::SequenceExecutor>> {
    skotiq_sequencer::get_executor()
}

/// Sequencer state for Flutter
#[derive(Debug, Clone)]
pub struct SequencerState {
    pub state: String,
    pub current_node_id: Option<String>,
    pub current_node_name: Option<String>,
    pub total_exposures: u32,
    pub completed_exposures: u32,
    pub total_integration_secs: f64,
    pub elapsed_secs: f64,
    pub estimated_remaining_secs: Option<f64>,
    pub current_target: Option<String>,
    pub current_filter: Option<String>,
    pub message: Option<String>,
}

impl From<SequenceProgress> for SequencerState {
    fn from(p: SequenceProgress) -> Self {
        let state_str = match p.state {
            ExecutorState::Idle => "idle",
            ExecutorState::Running => "running",
            ExecutorState::Paused => "paused",
            ExecutorState::Stopping => "stopping",
            ExecutorState::Cancelled => "cancelled",
            ExecutorState::Completed => "completed",
            ExecutorState::Failed => "failed",
            // Recovery Mode — new first-class state. The string
            // mirror is kept stable so any subscriber that switches on
            // `state.state == "recovering"` can render the Run Dashboard
            // LED without a typed enum import.
            ExecutorState::Recovering => "recovering",
        };
        Self {
            state: state_str.to_string(),
            current_node_id: p.current_node_id,
            current_node_name: p.current_node_name,
            total_exposures: p.total_exposures,
            completed_exposures: p.completed_exposures,
            total_integration_secs: p.total_integration_secs,
            elapsed_secs: p.elapsed_secs,
            estimated_remaining_secs: p.estimated_remaining_secs,
            current_target: p.current_target,
            current_filter: p.current_filter,
            message: p.message,
        }
    }
}
