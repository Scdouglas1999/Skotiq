//! Absolute end times a plan carries over from an earlier night.
//!
//! A plan built for one night keeps that night's absolute stop time. Started
//! on a later evening, the time is already past, the target's end condition
//! is met at entry, and the run skips every target and goes straight to its
//! shutdown steps at dusk. Before a run starts, an end time more than
//! [`STALE_AFTER_SECS`] in the past is moved forward by whole days to the same
//! clock time tonight; one that passed more recently ended tonight's imaging,
//! and a run whose every target has such an end refuses to start.

use crate::scheduling::TargetTrigger;
use crate::{NodeType, SequenceDefinition, TargetHeaderConfig};

/// An end time this far in the past belongs to an earlier night.
pub(crate) const STALE_AFTER_SECS: i64 = 12 * 3600;
const DAY_SECS: i64 = 24 * 3600;

/// One end time moved forward, for the operator.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct RolledEndTime {
    pub target: String,
    pub from: i64,
    pub to: i64,
}

impl RolledEndTime {
    pub(crate) fn message(&self) -> String {
        format!(
            "The end time on \"{}\" was {}, an earlier night. It now ends at {}, the \
             same clock time tonight.",
            self.target,
            format_utc(self.from),
            format_utc(self.to)
        )
    }
}

fn format_utc(timestamp: i64) -> String {
    chrono::DateTime::from_timestamp(timestamp, 0)
        .map(|t| t.format("%Y-%m-%d %H:%M UTC").to_string())
        .unwrap_or_else(|| timestamp.to_string())
}

/// `t` moved forward by whole days until it is no longer stale at `now`.
fn rolled(t: i64, now: i64) -> i64 {
    if t > now - STALE_AFTER_SECS {
        return t;
    }
    let days = (now - STALE_AFTER_SECS - t) / DAY_SECS + 1;
    t + days * DAY_SECS
}

fn roll_trigger(trigger: &mut TargetTrigger, now: i64, found: &mut Vec<(i64, i64)>) {
    match trigger {
        TargetTrigger::TimeAfter(t) => {
            let new = rolled(*t, now);
            if new != *t {
                found.push((*t, new));
                *t = new;
            }
        }
        TargetTrigger::And(children) | TargetTrigger::Or(children) => {
            for child in children {
                roll_trigger(child, now, found);
            }
        }
        _ => {}
    }
}

fn targets_mut(sequence: &mut SequenceDefinition) -> impl Iterator<Item = &mut TargetHeaderConfig> {
    sequence
        .nodes
        .iter_mut()
        .filter(|node| node.enabled)
        .filter_map(|node| match &mut node.node_type {
            NodeType::TargetHeader(config) | NodeType::TargetGroup(config) => Some(config),
            _ => None,
        })
}

/// Move every stale absolute end time in `sequence` forward to tonight.
/// Start times are left alone: a past start time is already satisfied.
pub(crate) fn roll_forward(sequence: &mut SequenceDefinition, now: i64) -> Vec<RolledEndTime> {
    let mut rolled_times = Vec::new();
    for config in targets_mut(sequence) {
        let mut found = Vec::new();
        if let Some(end) = config.end_when.as_mut() {
            roll_trigger(end, now, &mut found);
        }
        if let Some(t) = config.end_before {
            let new = rolled(t, now);
            if new != t {
                config.end_before = Some(new);
                // The legacy field only counts when there is no explicit end.
                if config.end_when.is_none() {
                    found.push((t, new));
                }
            }
        }
        let target = config.display_name();
        rolled_times.extend(found.into_iter().map(|(from, to)| RolledEndTime {
            target: target.clone(),
            from,
            to,
        }));
    }
    rolled_times
}

/// Whether `trigger` is decided by the clock alone at `now`: `Some(met)`, or
/// `None` when it depends on the sky.
fn met_by_clock(trigger: &TargetTrigger, now: i64) -> Option<bool> {
    match trigger {
        TargetTrigger::TimeAfter(t) => Some(now >= *t),
        TargetTrigger::TimeBefore(t) => Some(now < *t),
        TargetTrigger::Or(children) => {
            let results: Vec<_> = children.iter().map(|c| met_by_clock(c, now)).collect();
            if results.contains(&Some(true)) {
                Some(true)
            } else if results.iter().all(|r| *r == Some(false)) {
                Some(false)
            } else {
                None
            }
        }
        TargetTrigger::And(children) => {
            let results: Vec<_> = children.iter().map(|c| met_by_clock(c, now)).collect();
            if results.contains(&Some(false)) {
                Some(false)
            } else if !results.is_empty() && results.iter().all(|r| *r == Some(true)) {
                Some(true)
            } else {
                None
            }
        }
        _ => None,
    }
}

/// The refusal for a plan whose every target's end time has already passed
/// tonight, so a run would image nothing and go straight to its shutdown
/// steps. None when any target can still image.
pub(crate) fn nothing_left_to_image(sequence: &SequenceDefinition, now: i64) -> Option<String> {
    let mut ended = Vec::new();
    for node in sequence.nodes.iter().filter(|n| n.enabled) {
        let (NodeType::TargetHeader(config) | NodeType::TargetGroup(config)) = &node.node_type
        else {
            continue;
        };
        let end = config.effective_end_when()?;
        if met_by_clock(&end, now) != Some(true) {
            return None;
        }
        ended.push(config.display_name());
    }
    if ended.is_empty() {
        return None;
    }
    Some(format!(
        "Nothing to image: the end time of every target has already passed tonight ({}). \
         Change or remove the end conditions, then start again.",
        ended.join(", ")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{LoopCondition, LoopConfig, NodeDefinition};

    /// 2026-10-22 09:48 UTC, the stop time the owner's plan kept.
    const STALE_STOP: i64 = 1_792_662_480;
    /// 2026-10-23 23:55 UTC, the next evening's start.
    const NEXT_DUSK: i64 = 1_792_799_700;

    fn target(name: &str, end_when: Option<TargetTrigger>) -> TargetHeaderConfig {
        serde_json::from_value(serde_json::json!({
            "target_name": name,
            "ra_hours": 2.376,
            "dec_degrees": 42.35,
            "rotation": null,
            "priority": 0,
            "min_altitude": null,
            "max_altitude": null,
        }))
        .map(|mut config: TargetHeaderConfig| {
            config.end_when = end_when;
            config
        })
        .unwrap()
    }

    fn plan(targets: Vec<TargetHeaderConfig>) -> SequenceDefinition {
        let mut sequence = SequenceDefinition::new("Night".into());
        sequence.root_node_id = Some("root".into());
        let children: Vec<NodeDefinition> = targets
            .into_iter()
            .enumerate()
            .map(|(i, config)| NodeDefinition {
                id: format!("t{i}"),
                name: config.target_name.clone(),
                enabled: true,
                node_type: NodeType::TargetHeader(config),
                children: vec![],
            })
            .collect();
        let root = NodeDefinition {
            id: "root".into(),
            name: "Night".into(),
            enabled: true,
            node_type: NodeType::Loop(LoopConfig {
                iterations: Some(1),
                condition: LoopCondition::Count,
                ..Default::default()
            }),
            children: children.iter().map(|n| n.id.clone()).collect(),
        };
        sequence.nodes = std::iter::once(root).chain(children).collect();
        sequence
    }

    fn end_of(sequence: &SequenceDefinition, index: usize) -> Option<TargetTrigger> {
        match &sequence.nodes[index + 1].node_type {
            NodeType::TargetHeader(config) => config.end_when.clone(),
            _ => None,
        }
    }

    #[test]
    fn last_nights_stop_time_moves_to_the_same_time_tonight() {
        let mut sequence = plan(vec![target(
            "NGC0891",
            Some(TargetTrigger::Or(vec![
                TargetTrigger::AltitudeBelow(30.0),
                TargetTrigger::TimeAfter(STALE_STOP),
            ])),
        )]);
        let rolled = roll_forward(&mut sequence, NEXT_DUSK);
        assert_eq!(rolled.len(), 1);
        assert_eq!(rolled[0].to, STALE_STOP + DAY_SECS * 2);
        assert!(rolled[0].message().contains("2026-10-24 09:48 UTC"));
        assert_eq!(
            end_of(&sequence, 0),
            Some(TargetTrigger::Or(vec![
                TargetTrigger::AltitudeBelow(30.0),
                TargetTrigger::TimeAfter(STALE_STOP + DAY_SECS * 2),
            ]))
        );
        assert!(nothing_left_to_image(&sequence, NEXT_DUSK).is_none());
    }

    #[test]
    fn an_end_time_that_passed_tonight_is_kept_and_refuses_the_start() {
        let passed_an_hour_ago = NEXT_DUSK - 3600;
        let mut sequence = plan(vec![target(
            "NGC0891",
            Some(TargetTrigger::TimeAfter(passed_an_hour_ago)),
        )]);
        assert!(roll_forward(&mut sequence, NEXT_DUSK).is_empty());
        let refusal = nothing_left_to_image(&sequence, NEXT_DUSK).expect("refused");
        assert!(refusal.contains("NGC0891"), "{refusal}");
    }

    #[test]
    fn a_target_the_sky_decides_lets_the_run_start() {
        let sequence = plan(vec![
            target("Ended", Some(TargetTrigger::TimeAfter(NEXT_DUSK - 3600))),
            target("Open", Some(TargetTrigger::AltitudeBelow(30.0))),
        ]);
        assert!(nothing_left_to_image(&sequence, NEXT_DUSK).is_none());
        let unbounded = plan(vec![target("Unbounded", None)]);
        assert!(nothing_left_to_image(&unbounded, NEXT_DUSK).is_none());
    }

    #[test]
    fn a_future_end_time_is_left_alone() {
        let tonight = NEXT_DUSK + 6 * 3600;
        let mut sequence = plan(vec![target(
            "NGC0891",
            Some(TargetTrigger::TimeAfter(tonight)),
        )]);
        assert!(roll_forward(&mut sequence, NEXT_DUSK).is_empty());
        assert_eq!(
            end_of(&sequence, 0),
            Some(TargetTrigger::TimeAfter(tonight))
        );
    }
}
