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
        first.iter().any(|(id, _)| id == "filter_change"),
        "the change itself must fire the trigger"
    );

    for tick in 0..5 {
        let later: Vec<_> = manager.check_all().await;
        assert!(
            !later.iter().any(|(id, _)| id == "filter_change"),
            "tick {tick} re-fired FilterChange with no new filter change"
        );
    }

    manager.state().write().await.set_filter("OIII".to_string());
    let second: Vec<_> = manager.check_all().await;
    assert!(
        second.iter().any(|(id, _)| id == "filter_change"),
        "a genuinely new filter change must fire again"
    );
}
