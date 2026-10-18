use crate::scheduling::TargetTrigger;
use crate::{LoopCondition, NodeType, SequenceDefinition};

/// A simple sequence with an explicit time limit on every target owns its
/// finish time. The standard 30-min-before-dawn rule must not preempt either
/// those limits or the shutdown instructions that follow them.
pub(super) fn owns_dawn_end(sequence: &SequenceDefinition) -> bool {
    let Some(root) = sequence
        .root_node_id
        .as_ref()
        .and_then(|id| sequence.nodes.iter().find(|n| &n.id == id && n.enabled))
    else {
        return false;
    };
    if !matches!(&root.node_type, NodeType::Loop(c) if c.condition == LoopCondition::Count && c.iterations == Some(1))
    {
        return false;
    }
    let mut targets = 0;
    for id in &root.children {
        let Some(node) = sequence.nodes.iter().find(|n| &n.id == id) else {
            return false;
        };
        if !node.enabled {
            continue;
        }
        match &node.node_type {
            NodeType::TargetHeader(config) | NodeType::TargetGroup(config) => {
                if !config
                    .effective_end_when()
                    .as_ref()
                    .is_some_and(time_bounded)
                {
                    return false;
                }
                targets += 1;
            }
            NodeType::CoolCamera(_)
            | NodeType::WarmCamera(_)
            | NodeType::Unpark
            | NodeType::Park
            | NodeType::HomeMount
            | NodeType::StopGuiding
                if node.children.is_empty() => {}
            // Exposures or repeating containers outside bounded targets still
            // need the normal dawn rule.
            _ => return false,
        }
    }
    targets > 0
}

fn time_bounded(trigger: &TargetTrigger) -> bool {
    match trigger {
        TargetTrigger::TimeAfter(t) => *t > 0,
        TargetTrigger::Or(children) => children.iter().any(time_bounded),
        TargetTrigger::And(children) => !children.is_empty() && children.iter().all(time_bounded),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{LoopConfig, NodeDefinition, TargetHeaderConfig, WarmConfig};

    fn plan(end: TargetTrigger) -> SequenceDefinition {
        let mut sequence = SequenceDefinition::new("Until nautical dawn".into());
        sequence.root_node_id = Some("root".into());
        sequence.nodes = vec![
            NodeDefinition {
                id: "root".into(),
                name: "Night".into(),
                enabled: true,
                node_type: NodeType::Loop(LoopConfig {
                    iterations: Some(1),
                    condition: LoopCondition::Count,
                    ..Default::default()
                }),
                children: vec!["target".into(), "warm".into(), "park".into()],
            },
            NodeDefinition {
                id: "target".into(),
                name: "Target".into(),
                enabled: true,
                node_type: NodeType::TargetHeader(TargetHeaderConfig {
                    end_when: Some(end),
                    ..Default::default()
                }),
                children: vec![],
            },
            NodeDefinition {
                id: "warm".into(),
                name: "Warm".into(),
                enabled: true,
                node_type: NodeType::WarmCamera(WarmConfig::default()),
                children: vec![],
            },
            NodeDefinition {
                id: "park".into(),
                name: "Park".into(),
                enabled: true,
                node_type: NodeType::Park,
                children: vec![],
            },
        ];
        sequence
    }

    #[test]
    fn explicit_time_or_altitude_owns_dawn_and_shutdown() {
        let sequence = plan(TargetTrigger::Or(vec![
            TargetTrigger::TimeAfter(1800000000),
            TargetTrigger::AltitudeBelow(30.0),
        ]));
        assert!(owns_dawn_end(&sequence));
        // JSON round-trip exercises the exact definition consumed at start.
        let decoded = serde_json::from_str(&serde_json::to_string(&sequence).unwrap()).unwrap();
        assert!(owns_dawn_end(&decoded));
    }

    #[test]
    fn altitude_only_or_time_and_altitude_keeps_standard_dawn() {
        assert!(!owns_dawn_end(&plan(TargetTrigger::AltitudeBelow(30.0))));
        assert!(!owns_dawn_end(&plan(TargetTrigger::And(vec![
            TargetTrigger::TimeAfter(1800000000),
            TargetTrigger::AltitudeBelow(30.0)
        ]))));
    }

    #[test]
    fn unbounded_root_or_missing_child_keeps_standard_dawn() {
        let mut sequence = plan(TargetTrigger::TimeAfter(1800000000));
        sequence.nodes[0].children.push("missing".into());
        assert!(!owns_dawn_end(&sequence));
        sequence.nodes[0].children.pop();
        if let NodeType::Loop(c) = &mut sequence.nodes[0].node_type {
            c.condition = LoopCondition::Forever;
        }
        assert!(!owns_dawn_end(&sequence));
    }
}
