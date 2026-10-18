// split from monolithic api.rs
#![allow(unused_imports)]
// Shared imports inherited from the monolithic api.rs.
use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::error::*;
use crate::event::*;
use crate::state::*;
use crate::storage::{AppSettings, ObserverLocation};
use crate::unified_device_ops::create_unified_device_ops;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use skotiq_imaging::{
    calculate_airmass, validate_fits_header, validate_image, write_fits, BayerPattern,
    DebayerAlgorithm, FitsHeader, ImageData,
};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use tokio::sync::RwLock;
// Sibling-module items via the parent's pub use re-exports.
use super::*;

use skotiq_sequencer::{
    mosaic::calculate_mosaic_panels, mosaic::MosaicPanel, AutofocusConfig, AutofocusMethod,
    Binning, CenterConfig, CoolConfig, DelayConfig, DitherConfig, DitherPattern, ExecutorEvent,
    ExecutorState, ExposureConfig, FilterConfig, LoopCondition, LoopConfig, MosaicConfig,
    NodeDefinition, NodeStatus, NodeType, NotificationConfig, NotificationLevel, RotatorConfig,
    ScriptConfig, SequenceDefinition, SequenceProgress, SlewConfig, TargetGroupConfig,
    TargetHeaderConfig, TwilightType, WaitTimeConfig, WarmConfig,
};

pub mod event_bridge;
pub use event_bridge::*;
mod event_translation;
pub use event_translation::*;
pub mod lifecycle;
pub use lifecycle::*;
pub mod mosaic;
pub use mosaic::*;
pub mod node_factory;
pub use node_factory::*;
pub mod runtime_config;
pub use runtime_config::*;

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

/// Sequence definition for Flutter
#[derive(Debug, Clone)]
pub struct SequenceDefinitionApi {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    pub nodes: Vec<NodeDefinitionApi>,
    pub root_node_id: Option<String>,
}

/// Node definition for Flutter
#[derive(Debug, Clone)]
pub struct NodeDefinitionApi {
    pub id: String,
    pub name: String,
    pub node_type: String,
    pub enabled: bool,
    pub children: Vec<String>,
    pub config_json: String,
}

impl From<&NodeDefinition> for NodeDefinitionApi {
    fn from(n: &NodeDefinition) -> Self {
        let node_type = match &n.node_type {
            NodeType::TargetGroup(_) => "target_group",
            NodeType::TargetHeader(_) => "target_header",
            NodeType::Loop(_) => "loop",
            NodeType::Parallel(_) => "parallel",
            NodeType::Conditional(_) => "conditional",
            NodeType::Recovery(_) => "recovery",
            NodeType::SlewToTarget(_) => "slew",
            NodeType::CenterTarget(_) => "center",
            NodeType::TakeExposure(_) => "exposure",
            NodeType::Autofocus(_) => "autofocus",
            NodeType::Dither(_) => "dither",
            NodeType::ChangeFilter(_) => "filter_change",
            NodeType::CoolCamera(_) => "cool_camera",
            NodeType::WarmCamera(_) => "warm_camera",
            NodeType::PolarAlignment(_) => "polar_alignment",
            NodeType::MoveRotator(_) => "rotator",
            NodeType::Park => "park",
            NodeType::Unpark => "unpark",
            NodeType::HomeMount => "home_mount",
            NodeType::WaitForTime(_) => "wait_time",
            NodeType::Delay(_) => "delay",
            NodeType::Notification(_) => "notification",
            NodeType::RunScript(_) => "script",
            NodeType::MeridianFlip(_) => "meridian_flip",
            NodeType::OpenDome(_) => "open_dome",
            NodeType::CloseDome(_) => "close_dome",
            NodeType::ParkDome(_) => "park_dome",
            NodeType::StartGuiding(_) => "start_guiding",
            NodeType::StopGuiding => "stop_guiding",
            NodeType::TemperatureCompensation(_) => "temperature_compensation",
            NodeType::Mosaic(_) => "mosaic",
            NodeType::FlatWizard(_) => "flat_wizard",
            NodeType::OpenCover(_) => "open_cover",
            NodeType::CloseCover(_) => "close_cover",
            NodeType::CalibratorOn(_) => "calibrator_on",
            NodeType::CalibratorOff(_) => "calibrator_off",
            // TargetScheduler — dynamic target picker container.
            NodeType::TargetScheduler(_) => "target_scheduler",
            // SmartExposure — multi-filter container instruction.
            NodeType::SmartExposure(_) => "smart_exposure",
            // PluginNode — plugin-dispatched instruction.
            NodeType::PluginNode { .. } => "plugin_node",
            // LiveStacking — broadcast / EAA node.
            NodeType::LiveStacking(_) => "live_stacking",
            // Science: SciencePhotometry — cadence-enforced
            // photometric capture for variable-star / exoplanet
            // timing.
            NodeType::SciencePhotometry(_) => "science_photometry",
        };

        let config_json = match serde_json::to_string(&n.node_type) {
            Ok(json) => json,
            Err(e) => {
                tracing::error!("Failed to serialize node type for node '{}': {}", n.id, e);
                format!("{{\"error\":\"serialization failed: {}\"}}", e)
            }
        };

        Self {
            id: n.id.clone(),
            name: n.name.clone(),
            node_type: node_type.to_string(),
            enabled: n.enabled,
            children: n.children.clone(),
            config_json,
        }
    }
}
