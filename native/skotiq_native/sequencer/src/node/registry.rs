//! Which code runs a leaf node: one exhaustive match from `NodeType` to its
//! instruction node.
//!
//! Container nodes (TargetHeader, Loop, Parallel, Conditional, Recovery,
//! TargetScheduler) walk `&mut self.children` and are run by
//! [`crate::node::runtime::RuntimeNode`] itself; every other variant has an
//! instruction node here. Adding a `NodeType` variant fails to compile until
//! it is placed in this match and in [`NodeType::wire_name`] and
//! [`NodeType::display_name`].

use crate::node::context::ExecutionContext;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

/// A leaf node's run: the instruction it performs and what the run records
/// around it.
#[async_trait]
pub trait InstructionNode: Send + Sync {
    /// Run against the live context. `node_id` is the node being executed;
    /// `node_type` carries its configuration.
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus;
}

/// The instruction node that runs `node_type`, or `None` for a container.
pub fn instruction_for(node_type: &NodeType) -> Option<&'static dyn InstructionNode> {
    use super::instructions as i;
    Some(match node_type {
        NodeType::TargetHeader(_)
        | NodeType::TargetGroup(_)
        | NodeType::Loop(_)
        | NodeType::Parallel(_)
        | NodeType::Conditional(_)
        | NodeType::Recovery(_)
        | NodeType::TargetScheduler(_) => return None,

        NodeType::SlewToTarget(_) => &i::slew::SlewInstruction,
        NodeType::CenterTarget(_) => &i::center::CenterInstruction,
        NodeType::TakeExposure(_) => &i::expose::ExposeInstruction,
        NodeType::Autofocus(_) => &i::autofocus::AutofocusInstruction,
        NodeType::TemperatureCompensation(_) => {
            &i::temperature_compensation::TemperatureCompensationInstruction
        }
        NodeType::Dither(_) => &i::dither::DitherInstruction,
        NodeType::StartGuiding(_) => &i::start_guiding::StartGuidingInstruction,
        NodeType::StopGuiding => &i::stop_guiding::StopGuidingInstruction,
        NodeType::ChangeFilter(_) => &i::change_filter::ChangeFilterInstruction,
        NodeType::CoolCamera(_) => &i::cool_camera::CoolCameraInstruction,
        NodeType::WarmCamera(_) => &i::warm_camera::WarmCameraInstruction,
        NodeType::MoveRotator(_) => &i::move_rotator::MoveRotatorInstruction,
        NodeType::Park => &i::park::ParkInstruction,
        NodeType::Unpark => &i::unpark::UnparkInstruction,
        NodeType::HomeMount => &i::home_mount::HomeMountInstruction,
        NodeType::WaitForTime(_) => &i::wait_for_time::WaitForTimeInstruction,
        NodeType::Delay(_) => &i::delay::DelayInstruction,
        NodeType::Notification(_) => &i::notification::NotificationInstruction,
        NodeType::RunScript(_) => &i::run_script::RunScriptInstruction,
        NodeType::PolarAlignment(_) => &i::polar_alignment::PolarAlignmentInstruction,
        NodeType::MeridianFlip(_) => &i::meridian_flip::MeridianFlipInstruction,
        NodeType::OpenDome(_) => &i::open_dome::OpenDomeInstruction,
        NodeType::CloseDome(_) => &i::close_dome::CloseDomeInstruction,
        NodeType::ParkDome(_) => &i::park_dome::ParkDomeInstruction,
        NodeType::FlatWizard(_) => &i::flat_wizard::FlatWizardInstruction,
        NodeType::OpenCover(_) => &i::open_cover::OpenCoverInstruction,
        NodeType::CloseCover(_) => &i::close_cover::CloseCoverInstruction,
        NodeType::CalibratorOn(_) => &i::calibrator_on::CalibratorOnInstruction,
        NodeType::CalibratorOff(_) => &i::calibrator_off::CalibratorOffInstruction,
        NodeType::SmartExposure(_) => &i::smart_exposure::SmartExposureInstruction,
        NodeType::PluginNode { .. } => &i::plugin_node::PluginNodeInstruction,
        NodeType::LiveStacking(_) => &i::live_stacking::LiveStackingInstruction,
        NodeType::SciencePhotometry(_) => &i::science_photometry::SciencePhotometryInstruction,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One value of every `NodeType` variant, with its wire tag and display name.
    fn every_variant() -> Vec<(NodeType, &'static str, &'static str)> {
        vec![
            (
                NodeType::TargetHeader(Default::default()),
                "TargetHeader",
                "Target",
            ),
            (
                NodeType::TargetGroup(Default::default()),
                "TargetGroup",
                "Target",
            ),
            (NodeType::Loop(Default::default()), "Loop", "Loop"),
            (
                NodeType::Parallel(Default::default()),
                "Parallel",
                "Parallel",
            ),
            (
                NodeType::Conditional(Default::default()),
                "Conditional",
                "Conditional",
            ),
            (
                NodeType::Recovery(Default::default()),
                "Recovery",
                "Recovery",
            ),
            (
                NodeType::SlewToTarget(Default::default()),
                "SlewToTarget",
                "Slew",
            ),
            (
                NodeType::CenterTarget(Default::default()),
                "CenterTarget",
                "Center",
            ),
            (
                NodeType::TakeExposure(Default::default()),
                "TakeExposure",
                "Exposure",
            ),
            (
                NodeType::Autofocus(Default::default()),
                "Autofocus",
                "Autofocus",
            ),
            (
                NodeType::TemperatureCompensation(Default::default()),
                "TemperatureCompensation",
                "Temp Comp",
            ),
            (NodeType::Dither(Default::default()), "Dither", "Dither"),
            (
                NodeType::StartGuiding(Default::default()),
                "StartGuiding",
                "Start Guiding",
            ),
            (NodeType::StopGuiding, "StopGuiding", "Stop Guiding"),
            (
                NodeType::ChangeFilter(Default::default()),
                "ChangeFilter",
                "Filter",
            ),
            (
                NodeType::CoolCamera(Default::default()),
                "CoolCamera",
                "Cool Camera",
            ),
            (
                NodeType::WarmCamera(Default::default()),
                "WarmCamera",
                "Warm Camera",
            ),
            (
                NodeType::MoveRotator(Default::default()),
                "MoveRotator",
                "Move Rotator",
            ),
            (NodeType::Park, "Park", "Park"),
            (NodeType::Unpark, "Unpark", "Unpark"),
            (NodeType::HomeMount, "HomeMount", "Home Mount"),
            (
                NodeType::WaitForTime(Default::default()),
                "WaitForTime",
                "Wait",
            ),
            (NodeType::Delay(Default::default()), "Delay", "Delay"),
            (
                NodeType::Notification(Default::default()),
                "Notification",
                "Notification",
            ),
            (
                NodeType::RunScript(Default::default()),
                "RunScript",
                "Run Script",
            ),
            (
                NodeType::PolarAlignment(Default::default()),
                "PolarAlignment",
                "Polar Alignment",
            ),
            (
                NodeType::MeridianFlip(Default::default()),
                "MeridianFlip",
                "Meridian Flip",
            ),
            (
                NodeType::OpenDome(Default::default()),
                "OpenDome",
                "Open Dome",
            ),
            (
                NodeType::CloseDome(Default::default()),
                "CloseDome",
                "Close Dome",
            ),
            (
                NodeType::ParkDome(Default::default()),
                "ParkDome",
                "Park Dome",
            ),
            (
                NodeType::FlatWizard(Default::default()),
                "FlatWizard",
                "Flat Wizard",
            ),
            (
                NodeType::OpenCover(Default::default()),
                "OpenCover",
                "Open Cover",
            ),
            (
                NodeType::CloseCover(Default::default()),
                "CloseCover",
                "Close Cover",
            ),
            (
                NodeType::CalibratorOn(Default::default()),
                "CalibratorOn",
                "Calibrator On",
            ),
            (
                NodeType::CalibratorOff(Default::default()),
                "CalibratorOff",
                "Calibrator Off",
            ),
            (
                NodeType::TargetScheduler(Default::default()),
                "TargetScheduler",
                "Target Scheduler",
            ),
            (
                NodeType::SmartExposure(Default::default()),
                "SmartExposure",
                "Smart Exposure",
            ),
            (
                NodeType::PluginNode {
                    plugin_id: "com.example.test".to_string(),
                    node_type_id: "noop".to_string(),
                    config_json: String::new(),
                    display_name: None,
                    timeout_secs: None,
                },
                "PluginNode",
                "Plugin Node",
            ),
            (
                NodeType::LiveStacking(Default::default()),
                "LiveStacking",
                "Live Stacking",
            ),
            (
                NodeType::SciencePhotometry(Default::default()),
                "SciencePhotometry",
                "Science Photometry",
            ),
        ]
    }

    /// Saved sequences and the app's JSON carry these tags; they must not
    /// change, and `wire_name` must say what serde writes.
    #[test]
    fn wire_names_are_the_serialized_type_tags() {
        for (node_type, wire, _) in every_variant() {
            assert_eq!(node_type.wire_name(), wire);
            let json = serde_json::to_value(&node_type).expect("node type serializes");
            assert_eq!(json["type"], wire, "{wire}");
            let back: NodeType = serde_json::from_value(json).expect("node type deserializes");
            assert_eq!(back.wire_name(), wire);
        }
    }

    /// The progress events the app receives carry these names.
    #[test]
    fn display_names_are_pinned() {
        for (node_type, wire, display) in every_variant() {
            assert_eq!(node_type.display_name(), display, "{wire}");
        }
    }

    /// Every leaf variant has an instruction node; containers have none.
    #[test]
    fn every_instruction_variant_has_an_instruction_node() {
        for (node_type, wire, _) in every_variant() {
            assert_eq!(
                instruction_for(&node_type).is_none(),
                node_type.accepts_children(),
                "{wire}"
            );
        }
    }
}
