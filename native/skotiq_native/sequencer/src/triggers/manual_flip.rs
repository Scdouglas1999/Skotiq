//! An operator's request for the running sequence to flip now.
//!
//! The meridian trigger normally fires when its configured window opens. A
//! request lets the operator bring that forward, for example to flip before a
//! long frame rather than wait out the threshold, while the flip itself still
//! runs through the trigger's own action: it waits for the frame in flight,
//! stops guiding, flips, re-centers, refocuses if configured, restarts guiding
//! and settles, exactly as an automatic flip does.
//!
//! What a request cannot do is flip a target the trigger itself would never
//! flip. An east target never flips (see [`super::on_pre_flip_side`]), and a
//! mount that is parked, not tracking, or already on the post-flip side is
//! refused with the reason, so the operator learns why nothing happened
//! instead of watching a request sit there.

use super::TriggerState;
use crate::PierSide;

impl TriggerState {
    /// Why a manual flip cannot run now, or `None` when it can.
    ///
    /// The same preconditions the meridian trigger applies before any of its
    /// methods, without the window threshold: the target must be past the
    /// meridian on the pre-flip side, but how far past is the operator's call.
    pub fn manual_flip_refusal(&self) -> Option<String> {
        let target = self
            .current_target_name
            .as_deref()
            .map(|name| format!("'{name}'"))
            .unwrap_or_else(|| "the target".to_string());
        if self.target_ra.is_none() || self.target_dec.is_none() {
            return Some(
                "The run has no target set yet, so there is nothing to flip for.".to_string(),
            );
        }
        if self.has_flipped_this_target {
            return Some(format!("The mount has already flipped for {target}."));
        }
        if self.mount_parked == Some(true) {
            return Some("The mount is parked.".to_string());
        }
        if self.mount_is_tracking == Some(false) {
            return Some("The mount is not tracking.".to_string());
        }
        let Some(hour_angle) = self.current_hour_angle.filter(|ha| ha.is_finite()) else {
            return Some(format!(
                "The hour angle of {target} is not known yet (is the observing site set?)."
            ));
        };
        if hour_angle <= 0.0 {
            return Some(format!(
                "{} has not crossed the meridian yet; it transits in about {:.0} min. \
                 A target east of the meridian is never flipped.",
                capitalize(&target),
                -hour_angle * 60.0
            ));
        }
        if matches!(self.pier_side, Some(PierSide::East)) {
            return Some(
                "The mount already reports pier side East, the side a flip moves it to."
                    .to_string(),
            );
        }
        None
    }
}

fn capitalize(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn past_meridian_state() -> TriggerState {
        let mut state = TriggerState::new();
        state.current_target_name = Some("M31".to_string());
        state.target_ra = Some(10.68);
        state.target_dec = Some(41.27);
        state.current_hour_angle = Some(0.25);
        state.pier_side = Some(PierSide::West);
        state.mount_parked = Some(false);
        state.mount_is_tracking = Some(true);
        state
    }

    #[test]
    fn a_target_past_the_meridian_on_the_pre_flip_side_can_flip() {
        assert_eq!(past_meridian_state().manual_flip_refusal(), None);
    }

    /// The window threshold is the operator's to waive; the meridian is not.
    #[test]
    fn a_target_east_of_the_meridian_is_refused_with_its_transit_time() {
        let mut state = past_meridian_state();
        state.current_hour_angle = Some(-0.5);
        let reason = state
            .manual_flip_refusal()
            .expect("east target must be refused");
        assert!(reason.contains("has not crossed the meridian"), "{reason}");
        assert!(reason.contains("30 min"), "{reason}");
        assert!(reason.starts_with("'M31'"), "{reason}");
    }

    type Mutation = fn(&mut TriggerState);

    #[test]
    fn every_trigger_precondition_is_a_refusal() {
        let cases: [(&str, Mutation); 6] = [
            ("already flipped", |s| s.has_flipped_this_target = true),
            ("parked", |s| s.mount_parked = Some(true)),
            ("not tracking", |s| s.mount_is_tracking = Some(false)),
            ("pier side East", |s| s.pier_side = Some(PierSide::East)),
            ("not known", |s| s.current_hour_angle = None),
            ("no target", |s| s.target_ra = None),
        ];
        for (expected, mutate) in cases {
            let mut state = past_meridian_state();
            mutate(&mut state);
            let reason = state
                .manual_flip_refusal()
                .unwrap_or_else(|| panic!("{expected}: must be refused"));
            assert!(reason.contains(expected), "{expected}: {reason}");
        }
    }

    /// Unknown pier side suppresses nothing, as for the automatic trigger.
    #[test]
    fn an_unknown_pier_side_does_not_block_a_flip_past_the_meridian() {
        let mut state = past_meridian_state();
        state.pier_side = Some(PierSide::Unknown);
        assert_eq!(state.manual_flip_refusal(), None);
    }

    /// A request fires the trigger at once, inside the configured threshold,
    /// and only while the request stands.
    #[tokio::test]
    async fn a_request_fires_the_trigger_before_its_window_opens() {
        let config = crate::MeridianFlipConfig {
            trigger_method: crate::MeridianTriggerMethod::MinutesPastMeridian,
            minutes_past_meridian: 30.0,
            ..Default::default()
        };
        let mut trigger = super::super::Trigger::new(
            "meridian_flip",
            "Meridian Flip",
            crate::TriggerType::MeridianFlip {
                config: config.clone(),
            },
            crate::RecoveryAction::MeridianFlip(config),
        );
        let mut state = past_meridian_state();
        assert!(
            !trigger.check(&state).await,
            "15 min past a 30 min threshold must not fire on its own"
        );
        state.meridian_flip_requested = true;
        assert!(trigger.check(&state).await, "a standing request fires it");

        let mut east = past_meridian_state();
        east.current_hour_angle = Some(-0.1);
        east.meridian_flip_requested = true;
        let mut fresh = super::super::Trigger::new(
            "meridian_flip",
            "Meridian Flip",
            crate::TriggerType::MeridianFlip {
                config: crate::MeridianFlipConfig::default(),
            },
            crate::RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default()),
        );
        assert!(
            !fresh.check(&east).await,
            "a request never flips a target east of the meridian"
        );
    }

    #[test]
    fn a_target_change_or_a_completed_flip_drops_the_request() {
        let mut state = past_meridian_state();
        state.meridian_flip_requested = true;
        state.mark_flip_performed();
        assert!(!state.meridian_flip_requested);

        state.meridian_flip_requested = true;
        state.set_meridian_target("M33".to_string());
        assert!(!state.meridian_flip_requested);
    }
}
