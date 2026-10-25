//! Where a run goes when its target is behind an obstruction: the next target
//! in the plan that is up and clear now, or nowhere, which ends the night.

use super::config::FrameWatchConfig;
use crate::{NodeType, SequenceDefinition, TargetHeaderConfig};

/// Altitude a target must clear when its plan sets no minimum.
pub const DEFAULT_MIN_TARGET_ALTITUDE_DEG: f64 = 20.0;

/// The plan's enabled targets in the order the run reaches them.
pub fn targets_in_order(sequence: &SequenceDefinition) -> Vec<&TargetHeaderConfig> {
    let mut out = Vec::new();
    let Some(root) = sequence.root_node_id.as_ref() else {
        return out;
    };
    let mut stack = vec![root];
    while let Some(id) = stack.pop() {
        let Some(node) = sequence.nodes.iter().find(|n| &n.id == id) else {
            continue;
        };
        if !node.enabled {
            continue;
        }
        if let NodeType::TargetHeader(config) | NodeType::TargetGroup(config) = &node.node_type {
            out.push(config);
        }
        stack.extend(node.children.iter().rev());
    }
    out
}

/// What the run should do once `current` is obstructed.
#[derive(Debug, Clone, PartialEq)]
pub enum AfterObstruction {
    /// Skip to the next target; `Some` names the first later target that is
    /// up and clear now, `None` when the plan picks targets itself.
    NextTarget(Option<String>),
    /// No later target is up and clear: imaging is over for the night.
    EndOfNight,
}

/// Decide where to go after `current` is obstructed at time `now`. A later
/// target counts when it is above its minimum altitude (or
/// [`DEFAULT_MIN_TARGET_ALTITUDE_DEG`]) and outside every learned obstruction.
/// When `current` is not one of the plan's targets (a scheduler picks them)
/// the run skips to its next pick.
pub fn after_obstruction(
    sequence: Option<&SequenceDefinition>,
    current: Option<&str>,
    horizon: &FrameWatchConfig,
    latitude: f64,
    longitude: f64,
    now: chrono::DateTime<chrono::Utc>,
) -> AfterObstruction {
    let Some(sequence) = sequence else {
        return AfterObstruction::EndOfNight;
    };
    let targets = targets_in_order(sequence);
    let Some(position) = current.and_then(|name| {
        targets
            .iter()
            .position(|t| t.target_name.eq_ignore_ascii_case(name))
    }) else {
        return AfterObstruction::NextTarget(None);
    };
    targets[position + 1..]
        .iter()
        .find(|t| {
            let (alt, az) = crate::meridian::calculate_alt_az(
                t.ra_hours,
                t.dec_degrees,
                latitude,
                longitude,
                now,
            );
            alt > t.min_altitude.unwrap_or(DEFAULT_MIN_TARGET_ALTITUDE_DEG)
                && horizon.learned_obstruction_at(alt, az).is_none()
        })
        .map(|t| AfterObstruction::NextTarget(Some(t.target_name.clone())))
        .unwrap_or(AfterObstruction::EndOfNight)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{NodeDefinition, NodeId};
    use chrono::TimeZone;

    fn header(name: &str, ra_hours: f64, dec: f64) -> TargetHeaderConfig {
        serde_json::from_value(serde_json::json!({
            "target_name": name,
            "ra_hours": ra_hours,
            "dec_degrees": dec,
            "rotation": null,
            "priority": 0,
            "min_altitude": null,
            "max_altitude": null,
        }))
        .expect("a minimal target header")
    }

    fn node(id: &str, node_type: NodeType, children: &[&str]) -> NodeDefinition {
        serde_json::from_value(serde_json::json!({
            "id": id,
            "name": id,
            "node_type": serde_json::to_value(&node_type).unwrap(),
            "enabled": true,
            "children": children,
        }))
        .expect("a node definition")
    }

    fn plan(targets: &[(&str, f64, f64)]) -> SequenceDefinition {
        let mut seq = SequenceDefinition::new("plan".into());
        let ids: Vec<String> = (0..targets.len()).map(|i| format!("t{i}")).collect();
        let id_refs: Vec<&str> = ids.iter().map(String::as_str).collect();
        let root: NodeId = "root".into();
        seq.nodes.push(node(
            "root",
            NodeType::Loop(crate::LoopConfig::default()),
            &id_refs,
        ));
        for (i, (name, ra, dec)) in targets.iter().enumerate() {
            seq.nodes.push(node(
                &ids[i],
                NodeType::TargetHeader(header(name, *ra, *dec)),
                &[],
            ));
        }
        seq.root_node_id = Some(root);
        seq
    }

    /// The rig's site at 07:42 UTC on 2026-10-24, when the trees took NGC 891.
    fn at_the_trees() -> (f64, f64, chrono::DateTime<chrono::Utc>) {
        (
            39.9719,
            -75.3576,
            chrono::Utc
                .with_ymd_and_hms(2026, 10, 24, 7, 42, 0)
                .unwrap(),
        )
    }

    #[test]
    fn the_site_and_time_put_ngc_891_where_the_mount_recorded_it() {
        let (lat, lon, now) = at_the_trees();
        let (alt, az) = crate::meridian::calculate_alt_az(2.3759, 42.349, lat, lon, now);
        assert!(
            (alt - 62.8).abs() < 1.0 && (az - 286.4).abs() < 1.5,
            "{alt} {az}"
        );
    }

    #[test]
    fn a_single_target_plan_ends_the_night() {
        let (lat, lon, now) = at_the_trees();
        let seq = plan(&[("NGC0891", 2.3759, 42.349)]);
        assert_eq!(
            after_obstruction(
                Some(&seq),
                Some("NGC0891"),
                &FrameWatchConfig::default(),
                lat,
                lon,
                now
            ),
            AfterObstruction::EndOfNight
        );
    }

    #[test]
    fn a_later_target_that_is_up_is_next_and_one_that_is_down_is_not() {
        let (lat, lon, now) = at_the_trees();
        // M 57 is below the horizon then; M 42 is high in the south.
        let seq = plan(&[
            ("NGC0891", 2.3759, 42.349),
            ("M 57", 18.893, 33.03),
            ("M 42", 5.588, -5.39),
        ]);
        assert_eq!(
            after_obstruction(
                Some(&seq),
                Some("NGC0891"),
                &FrameWatchConfig::default(),
                lat,
                lon,
                now
            ),
            AfterObstruction::NextTarget(Some("M 42".to_string()))
        );
    }
}
