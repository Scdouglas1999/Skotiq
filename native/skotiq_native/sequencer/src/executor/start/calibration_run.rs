use crate::executor::RECOVERY_NODE_TRIGGER_PREFIX;
use crate::{NodeType, SequenceDefinition};

/// A sequence that only takes calibration frames — darks, bias, flats — and
/// otherwise only cools, warms, parks or homes. None of it points at the sky.
///
/// Such a run is exempt from the standard triggers: their actions (dither,
/// autofocus, meridian flip, recenter, guiding recovery, the dawn and weather
/// parks) all serve light frames, and acting on any of them moves hardware a
/// dark run needs to stay still, or ends a run that daylight cannot spoil.
/// Triggers the sequence declares itself through Recovery nodes still apply.
pub(super) fn is_calibration_only(sequence: &SequenceDefinition) -> bool {
    let mut calibration_frames = false;
    for node in sequence.nodes.iter().filter(|n| n.enabled) {
        match &node.node_type {
            NodeType::TakeExposure(config) => {
                if !is_calibration_frame_type(&config.frame_type) {
                    return false;
                }
                calibration_frames = true;
            }
            NodeType::FlatWizard(_) => calibration_frames = true,
            NodeType::Loop(_)
            | NodeType::Parallel(_)
            | NodeType::Recovery(_)
            | NodeType::StopGuiding
            | NodeType::ChangeFilter(_)
            | NodeType::CoolCamera(_)
            | NodeType::WarmCamera(_)
            | NodeType::Park
            | NodeType::HomeMount
            | NodeType::WaitForTime(_)
            | NodeType::Delay(_)
            | NodeType::Notification(_)
            | NodeType::CloseDome(_)
            | NodeType::ParkDome(_)
            | NodeType::CloseCover(_)
            | NodeType::OpenCover(_)
            | NodeType::CalibratorOn(_)
            | NodeType::CalibratorOff(_) => {}
            _ => return false,
        }
    }
    calibration_frames
}

pub(super) fn is_calibration_frame_type(frame_type: &str) -> bool {
    matches!(
        frame_type.trim().to_ascii_lowercase().as_str(),
        "dark" | "bias" | "flat" | "darkflat"
    )
}

/// Whether a fired trigger may act in a calibration-only run.
pub(super) fn acts_in_calibration_run(trigger_id: &str) -> bool {
    trigger_id.starts_with(RECOVERY_NODE_TRIGGER_PREFIX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        CoolConfig, ExposureConfig, LoopCondition, LoopConfig, NodeDefinition, WarmConfig,
    };

    fn node(id: &str, node_type: NodeType) -> NodeDefinition {
        NodeDefinition {
            id: id.into(),
            name: id.into(),
            enabled: true,
            node_type,
            children: vec![],
        }
    }

    fn exposure(frame_type: &str) -> NodeType {
        NodeType::TakeExposure(ExposureConfig {
            frame_type: frame_type.into(),
            ..Default::default()
        })
    }

    fn plan(children: Vec<NodeDefinition>) -> SequenceDefinition {
        let mut sequence = SequenceDefinition::new("End of night calibration".into());
        sequence.root_node_id = Some("root".into());
        let mut root = node(
            "root",
            NodeType::Loop(LoopConfig {
                iterations: Some(1),
                condition: LoopCondition::Count,
                ..Default::default()
            }),
        );
        root.children = children.iter().map(|n| n.id.clone()).collect();
        sequence.nodes = std::iter::once(root).chain(children).collect();
        sequence
    }

    #[test]
    fn darks_and_bias_with_cooling_are_a_calibration_run() {
        let sequence = plan(vec![
            node("cool", NodeType::CoolCamera(CoolConfig::default())),
            node("dark", exposure("Dark")),
            node("bias", exposure("Bias")),
            node("warm", NodeType::WarmCamera(WarmConfig::default())),
        ]);
        assert!(is_calibration_only(&sequence));
        let decoded = serde_json::from_str(&serde_json::to_string(&sequence).unwrap()).unwrap();
        assert!(is_calibration_only(&decoded));
    }

    #[test]
    fn a_light_frame_or_a_slew_makes_it_an_imaging_run() {
        assert!(!is_calibration_only(&plan(vec![
            node("dark", exposure("Dark")),
            node("light", exposure("Light")),
        ])));
        assert!(!is_calibration_only(&plan(vec![
            node("dark", exposure("Dark")),
            node("unpark", NodeType::Unpark),
        ])));
        assert!(!is_calibration_only(&plan(vec![node(
            "cool",
            NodeType::CoolCamera(CoolConfig::default())
        )])));
    }

    #[test]
    fn a_disabled_light_node_does_not_count() {
        let mut light = node("light", exposure("Light"));
        light.enabled = false;
        assert!(is_calibration_only(&plan(vec![
            node("dark", exposure("Dark")),
            light
        ])));
    }

    #[test]
    fn only_sequence_recovery_triggers_act_in_a_calibration_run() {
        for standard in [
            "dither_interval",
            "autofocus_interval",
            "dawn_approaching",
            "meridian_flip",
            "weather_unsafe",
            "temperature_shift",
            "guide_star_lost",
        ] {
            assert!(!acts_in_calibration_run(standard), "{standard}");
        }
        assert!(acts_in_calibration_run(&format!(
            "{RECOVERY_NODE_TRIGGER_PREFIX}node-1"
        )));
    }
}
