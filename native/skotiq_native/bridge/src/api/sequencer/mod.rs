use skotiq_sequencer::SequenceProgress;

pub mod event_bridge;
pub mod event_translation;
pub mod lifecycle;
pub mod mosaic;
pub mod runtime_config;

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
    /// A manual action holds the run paused: only its own release resumes or
    /// skips it.
    pub held_by_action: bool,
}

impl SequencerState {
    fn new(p: SequenceProgress, held_by_action: bool) -> Self {
        let state_str = p.state.as_wire();
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
            held_by_action,
        }
    }
}
