//! Instruction-node trait + registry.
//!
//! ## Why this exists
//!
//! A single `match node_type` arm covering every instruction would have to be
//! touched by each new one, alongside the totals walker in `executor.rs` and
//! checkpoint serialization. This module replaces that match with a
//! per-instruction trait `InstructionNode` and a static registry keyed by
//! `NodeType` discriminant name.
//!
//! ## Migration path for new instructions
//!
//! 1. Add a config struct + variant in `crate::NodeType` (file-format compat).
//! 2. Add an `execute_*` function in `crate::instructions` for the device-side
//!    work.
//! 3. Create `node/instructions/<name>.rs` implementing [`InstructionNode`].
//! 4. Register the new struct in [`InstructionRegistry::new`].
//!
//! ## What this trait does NOT cover
//!
//! Container / logic nodes (TargetHeader, Loop, Parallel, Conditional,
//! Recovery) hold `&mut self.children` and `&mut self.current_iteration` —
//! they cannot be cleanly dispatched through a trait without splitting
//! RuntimeNode's state ownership. They live in `node::logic` and are still
//! dispatched via a small explicit match on the container variants.
//! Everything else (the 27 instruction variants) goes through this registry.

use crate::node::context::ExecutionContext;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::OnceLock;

/// Trait implemented by every leaf instruction node.
#[async_trait]
pub trait InstructionNode: Send + Sync {
    /// Display name (e.g. "Filter", "Autofocus") used in progress events.
    fn type_name(&self) -> &'static str;

    /// Execute the instruction against the live context. `node_id` is passed
    /// explicitly because the dispatch site owns the NodeId; the
    /// instruction's `&NodeType` config does not.
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus;
}

/// Build an instance of an InstructionNode for the given NodeType variant.
/// Returns `None` for container/logic variants (TargetHeader, Loop, etc.)
/// and for `TargetGroup` (alias handled by container layer).
type Factory = fn() -> Box<dyn InstructionNode>;

/// Static registry of `NodeType`-discriminant → factory.
///
/// Keys are stable discriminant names produced by [`node_type_discriminant`].
/// Lookup is `O(1)` after the first build (registry is a `OnceLock`).
pub struct InstructionRegistry {
    factories: HashMap<&'static str, Factory>,
}

impl InstructionRegistry {
    fn new() -> Self {
        let mut factories: HashMap<&'static str, Factory> = HashMap::new();

        // Why a function table instead of `inventory`: `inventory` requires
        // global linker tricks that don't play well with cdylibs (FRB ships
        // skotiq_bridge as cdylib + staticlib; static init order matters).
        // A hand-rolled registry is explicit, debuggable, and easy to extend.
        use super::instructions as i;

        factories.insert("SlewToTarget", || Box::new(i::slew::SlewInstruction));
        factories.insert("CenterTarget", || Box::new(i::center::CenterInstruction));
        factories.insert("TakeExposure", || Box::new(i::expose::ExposeInstruction));
        factories.insert("Autofocus", || Box::new(i::autofocus::AutofocusInstruction));
        factories.insert("TemperatureCompensation", || {
            Box::new(i::temperature_compensation::TemperatureCompensationInstruction)
        });
        factories.insert("Dither", || Box::new(i::dither::DitherInstruction));
        factories.insert("StartGuiding", || {
            Box::new(i::start_guiding::StartGuidingInstruction)
        });
        factories.insert("StopGuiding", || {
            Box::new(i::stop_guiding::StopGuidingInstruction)
        });
        factories.insert("ChangeFilter", || {
            Box::new(i::change_filter::ChangeFilterInstruction)
        });
        factories.insert("CoolCamera", || {
            Box::new(i::cool_camera::CoolCameraInstruction)
        });
        factories.insert("WarmCamera", || {
            Box::new(i::warm_camera::WarmCameraInstruction)
        });
        factories.insert("MoveRotator", || {
            Box::new(i::move_rotator::MoveRotatorInstruction)
        });
        factories.insert("Park", || Box::new(i::park::ParkInstruction));
        factories.insert("Unpark", || Box::new(i::unpark::UnparkInstruction));
        factories.insert("WaitForTime", || {
            Box::new(i::wait_for_time::WaitForTimeInstruction)
        });
        factories.insert("Delay", || Box::new(i::delay::DelayInstruction));
        factories.insert("Notification", || {
            Box::new(i::notification::NotificationInstruction)
        });
        factories.insert("RunScript", || {
            Box::new(i::run_script::RunScriptInstruction)
        });
        factories.insert("PolarAlignment", || {
            Box::new(i::polar_alignment::PolarAlignmentInstruction)
        });
        factories.insert("MeridianFlip", || {
            Box::new(i::meridian_flip::MeridianFlipInstruction)
        });
        factories.insert("OpenDome", || Box::new(i::open_dome::OpenDomeInstruction));
        factories.insert("CloseDome", || {
            Box::new(i::close_dome::CloseDomeInstruction)
        });
        factories.insert("ParkDome", || Box::new(i::park_dome::ParkDomeInstruction));
        factories.insert("Mosaic", || Box::new(i::mosaic::MosaicInstruction));
        factories.insert("FlatWizard", || {
            Box::new(i::flat_wizard::FlatWizardInstruction)
        });
        factories.insert("OpenCover", || {
            Box::new(i::open_cover::OpenCoverInstruction)
        });
        factories.insert("CloseCover", || {
            Box::new(i::close_cover::CloseCoverInstruction)
        });
        factories.insert("CalibratorOn", || {
            Box::new(i::calibrator_on::CalibratorOnInstruction)
        });
        factories.insert("CalibratorOff", || {
            Box::new(i::calibrator_off::CalibratorOffInstruction)
        });
        // SmartExposure.
        factories.insert("SmartExposure", || {
            Box::new(i::smart_exposure::SmartExposureInstruction)
        });
        // PluginNode — dispatches into Dart via the
        // request/response protocol implemented in `plugin_node.rs`.
        factories.insert("PluginNode", || {
            Box::new(i::plugin_node::PluginNodeInstruction)
        });
        // LiveStacking — broadcast / EAA node.
        factories.insert("LiveStacking", || {
            Box::new(i::live_stacking::LiveStackingInstruction)
        });
        // Science: SciencePhotometry — cadence-enforced photometric capture.
        factories.insert("SciencePhotometry", || {
            Box::new(i::science_photometry::SciencePhotometryInstruction)
        });

        Self { factories }
    }

    /// Look up a factory by `NodeType` variant. Returns `None` for container/
    /// logic variants which the container layer handles directly.
    pub fn build(&self, node_type: &NodeType) -> Option<Box<dyn InstructionNode>> {
        let key = node_type_discriminant(node_type)?;
        self.factories.get(key).map(|factory| factory())
    }
}

/// Map a `NodeType` to its discriminant string. Returns `None` for the
/// container/logic variants so callers can fall through to the logic path.
pub fn node_type_discriminant(node_type: &NodeType) -> Option<&'static str> {
    match node_type {
        // Container / logic variants are NOT in the registry.
        NodeType::TargetHeader(_)
        | NodeType::TargetGroup(_)
        | NodeType::Loop(_)
        | NodeType::Parallel(_)
        | NodeType::Conditional(_)
        | NodeType::Recovery(_)
        // TargetScheduler — container variant; logic dispatch.
        | NodeType::TargetScheduler(_) => None,

        NodeType::SlewToTarget(_) => Some("SlewToTarget"),
        NodeType::CenterTarget(_) => Some("CenterTarget"),
        NodeType::TakeExposure(_) => Some("TakeExposure"),
        NodeType::Autofocus(_) => Some("Autofocus"),
        NodeType::TemperatureCompensation(_) => Some("TemperatureCompensation"),
        NodeType::Dither(_) => Some("Dither"),
        NodeType::StartGuiding(_) => Some("StartGuiding"),
        NodeType::StopGuiding => Some("StopGuiding"),
        NodeType::ChangeFilter(_) => Some("ChangeFilter"),
        NodeType::CoolCamera(_) => Some("CoolCamera"),
        NodeType::WarmCamera(_) => Some("WarmCamera"),
        NodeType::MoveRotator(_) => Some("MoveRotator"),
        NodeType::Park => Some("Park"),
        NodeType::Unpark => Some("Unpark"),
        NodeType::WaitForTime(_) => Some("WaitForTime"),
        NodeType::Delay(_) => Some("Delay"),
        NodeType::Notification(_) => Some("Notification"),
        NodeType::RunScript(_) => Some("RunScript"),
        NodeType::PolarAlignment(_) => Some("PolarAlignment"),
        NodeType::MeridianFlip(_) => Some("MeridianFlip"),
        NodeType::OpenDome(_) => Some("OpenDome"),
        NodeType::CloseDome(_) => Some("CloseDome"),
        NodeType::ParkDome(_) => Some("ParkDome"),
        NodeType::Mosaic(_) => Some("Mosaic"),
        NodeType::FlatWizard(_) => Some("FlatWizard"),
        NodeType::OpenCover(_) => Some("OpenCover"),
        NodeType::CloseCover(_) => Some("CloseCover"),
        NodeType::CalibratorOn(_) => Some("CalibratorOn"),
        NodeType::CalibratorOff(_) => Some("CalibratorOff"),
        // SmartExposure.
        NodeType::SmartExposure(_) => Some("SmartExposure"),
        // PluginNode.
        NodeType::PluginNode { .. } => Some("PluginNode"),
        // LiveStacking.
        NodeType::LiveStacking(_) => Some("LiveStacking"),
        // (Science): SciencePhotometry — owned by the
        // Science agent. We hand back the canonical discriminator so
        // the registry stays exhaustive in the interim; the Science
        // agent owns the actual factory registration when they wire
        // their instruction file in.
        NodeType::SciencePhotometry(_) => Some("SciencePhotometry"),
    }
}

/// Lazy-initialised global registry. Built once on first use; thereafter the
/// `OnceLock` is read-only.
pub fn registry() -> &'static InstructionRegistry {
    static REGISTRY: OnceLock<InstructionRegistry> = OnceLock::new();
    REGISTRY.get_or_init(InstructionRegistry::new)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        DelayConfig, LiveStackingConfig, NodeType, TargetHeaderConfig, TargetSchedulerConfig,
    };

    #[test]
    fn registry_resolves_every_instruction_variant() {
        let reg = registry();
        // Smoke-test: every non-container variant must produce a factory.
        let variants: Vec<NodeType> = vec![
            NodeType::SlewToTarget(Default::default()),
            NodeType::CenterTarget(Default::default()),
            NodeType::TakeExposure(Default::default()),
            NodeType::Autofocus(Default::default()),
            NodeType::TemperatureCompensation(Default::default()),
            NodeType::Dither(Default::default()),
            NodeType::StartGuiding(Default::default()),
            NodeType::StopGuiding,
            NodeType::ChangeFilter(Default::default()),
            NodeType::CoolCamera(Default::default()),
            NodeType::WarmCamera(Default::default()),
            NodeType::MoveRotator(Default::default()),
            NodeType::Park,
            NodeType::Unpark,
            NodeType::WaitForTime(Default::default()),
            NodeType::Delay(DelayConfig::default()),
            NodeType::Notification(Default::default()),
            NodeType::RunScript(Default::default()),
            NodeType::PolarAlignment(Default::default()),
            NodeType::MeridianFlip(Default::default()),
            NodeType::OpenDome(Default::default()),
            NodeType::CloseDome(Default::default()),
            NodeType::ParkDome(Default::default()),
            NodeType::Mosaic(Default::default()),
            NodeType::FlatWizard(Default::default()),
            NodeType::OpenCover(Default::default()),
            NodeType::CloseCover(Default::default()),
            NodeType::CalibratorOn(Default::default()),
            NodeType::CalibratorOff(Default::default()),
            // SmartExposure.
            NodeType::SmartExposure(Default::default()),
            // PluginNode — registry must resolve it the
            // same as every other instruction variant. Discriminant-only
            // check; the actual execute() path is exercised by
            // plugin_node.rs's own tests.
            NodeType::PluginNode {
                plugin_id: "com.example.test".to_string(),
                node_type_id: "noop".to_string(),
                config_json: String::new(),
                display_name: None,
                timeout_secs: None,
            },
            // LiveStacking — broadcast / EAA node.
            NodeType::LiveStacking(LiveStackingConfig::default()),
        ];
        for variant in &variants {
            let built = reg.build(variant);
            assert!(
                built.is_some(),
                "expected registry to resolve variant {:?}",
                variant
            );
        }
    }

    #[test]
    fn registry_returns_none_for_container_variants() {
        let reg = registry();
        let containers: Vec<NodeType> = vec![
            NodeType::TargetHeader(TargetHeaderConfig::default()),
            NodeType::TargetGroup(TargetHeaderConfig::default()),
            NodeType::Loop(Default::default()),
            NodeType::Parallel(Default::default()),
            NodeType::Conditional(Default::default()),
            NodeType::Recovery(Default::default()),
            // TargetScheduler.
            NodeType::TargetScheduler(TargetSchedulerConfig::default()),
        ];
        for variant in &containers {
            assert!(
                reg.build(variant).is_none(),
                "container variant must NOT be in the instruction registry: {:?}",
                variant
            );
            assert!(
                node_type_discriminant(variant).is_none(),
                "container variant must NOT have a discriminant string: {:?}",
                variant
            );
        }
    }

    #[test]
    fn type_name_matches_discriminant_for_every_instruction() {
        // Wiring sanity: registry key == InstructionNode::type_name().
        let reg = registry();
        let cases: Vec<(NodeType, &str)> = vec![
            (NodeType::SlewToTarget(Default::default()), "Slew"),
            (NodeType::CenterTarget(Default::default()), "Center"),
            (NodeType::TakeExposure(Default::default()), "Exposure"),
            (NodeType::Autofocus(Default::default()), "Autofocus"),
            (
                NodeType::TemperatureCompensation(Default::default()),
                "Temp Comp",
            ),
            (NodeType::Dither(Default::default()), "Dither"),
            (NodeType::StartGuiding(Default::default()), "Start Guiding"),
            (NodeType::StopGuiding, "Stop Guiding"),
            (NodeType::ChangeFilter(Default::default()), "Filter"),
            (NodeType::CoolCamera(Default::default()), "Cool Camera"),
            (NodeType::WarmCamera(Default::default()), "Warm Camera"),
            (NodeType::MoveRotator(Default::default()), "Move Rotator"),
            (NodeType::Park, "Park"),
            (NodeType::Unpark, "Unpark"),
            (NodeType::WaitForTime(Default::default()), "Wait"),
            (NodeType::Delay(Default::default()), "Delay"),
            (NodeType::Notification(Default::default()), "Notification"),
            (NodeType::RunScript(Default::default()), "Run Script"),
            (
                NodeType::PolarAlignment(Default::default()),
                "Polar Alignment",
            ),
            (NodeType::MeridianFlip(Default::default()), "Meridian Flip"),
            (NodeType::OpenDome(Default::default()), "Open Dome"),
            (NodeType::CloseDome(Default::default()), "Close Dome"),
            (NodeType::ParkDome(Default::default()), "Park Dome"),
            (NodeType::Mosaic(Default::default()), "Mosaic"),
            (NodeType::FlatWizard(Default::default()), "Flat Wizard"),
            (NodeType::OpenCover(Default::default()), "Open Cover"),
            (NodeType::CloseCover(Default::default()), "Close Cover"),
            (NodeType::CalibratorOn(Default::default()), "Calibrator On"),
            (
                NodeType::CalibratorOff(Default::default()),
                "Calibrator Off",
            ),
            // SmartExposure.
            (
                NodeType::SmartExposure(Default::default()),
                "Smart Exposure",
            ),
            // PluginNode — the type_name is the same for
            // every plugin (the actual plugin/node identifiers are
            // surfaced via the structured progress payload, not the
            // legacy `instruction` label).
            (
                NodeType::PluginNode {
                    plugin_id: "com.example.test".to_string(),
                    node_type_id: "noop".to_string(),
                    config_json: String::new(),
                    display_name: None,
                    timeout_secs: None,
                },
                "Plugin Node",
            ),
            // LiveStacking.
            (
                NodeType::LiveStacking(LiveStackingConfig::default()),
                "Live Stacking",
            ),
        ];
        for (variant, expected) in cases {
            let built = reg.build(&variant).expect("variant must resolve");
            assert_eq!(
                built.type_name(),
                expected,
                "instruction type_name() mismatch for {:?}",
                variant
            );
        }
    }
}
