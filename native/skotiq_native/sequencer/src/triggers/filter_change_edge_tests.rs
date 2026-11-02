use super::*;
use crate::{RecoveryAction, TriggerType};

/// A single filter change must fire the FilterChange trigger exactly once,
/// not once per ~1Hz evaluation tick for the rest of the run.
#[tokio::test]
async fn filter_change_trigger_fires_once_per_change() {
    let mut manager = TriggerManager::new();
    manager.add_trigger(Trigger::new(
        "filter_change",
        "Filter Change",
        TriggerType::FilterChange,
        RecoveryAction::Continue,
    ));

    manager.state().write().await.set_filter("Ha".to_string());

    let first: Vec<_> = manager.check_all().await;
    assert!(
        first.iter().any(|f| f.trigger_id() == "filter_change"),
        "the change itself must fire the trigger"
    );

    for tick in 0..5 {
        let later: Vec<_> = manager.check_all().await;
        assert!(
            !later.iter().any(|f| f.trigger_id() == "filter_change"),
            "tick {tick} re-fired FilterChange with no new filter change"
        );
    }

    manager.state().write().await.set_filter("OIII".to_string());
    let second: Vec<_> = manager.check_all().await;
    assert!(
        second.iter().any(|f| f.trigger_id() == "filter_change"),
        "a genuinely new filter change must fire again"
    );
}

/// After a filter change the HFR baseline is that filter's focused HFR from
/// its last autofocus, not the first frame through it: with the focuser moved
/// out of focus, adopting that frame made 4.43 px the reference and no HFR
/// trigger could ever see the blur (qa-night N18).
#[test]
fn a_filter_change_restores_the_filters_focused_hfr() {
    let mut state = TriggerState::new();
    state.set_filter("L".to_string());
    state.update_hfr(1.96);
    state.reset_baseline_hfr(); // autofocus succeeded on L
    state.set_filter("R".to_string());
    state.update_hfr(2.10);
    state.reset_baseline_hfr(); // autofocus succeeded on R

    // The focuser is knocked out of focus; the next L frame is blurred.
    state.set_filter("L".to_string());
    assert_eq!(state.baseline_hfr, Some(1.96));
    state.update_hfr(4.43);
    assert_eq!(
        state.baseline_hfr,
        Some(1.96),
        "the blurred frame must not become the baseline"
    );

    // A filter never focused keeps the old behavior: its first frame.
    state.set_filter("Ha".to_string());
    assert_eq!(state.baseline_hfr, None);
    state.update_hfr(2.6);
    assert_eq!(state.baseline_hfr, Some(2.6));

    // A new run starts with nothing remembered.
    state.reset_for_new_run();
    state.set_filter("L".to_string());
    assert_eq!(state.baseline_hfr, None);
}
