//! The line a running step shows is the line its instruction wrote.

use super::*;
use crate::node::progress::ProgressDetail;
use std::sync::Mutex as StdMutex;

/// Run one node the way `RuntimeNode` does and return the lines it showed.
async fn step_lines(
    node_type: NodeType,
    ec: &mut crate::node::context::ExecutionContext,
) -> (NodeStatus, Vec<String>, Vec<ProgressDetail>) {
    let updates: Arc<StdMutex<Vec<crate::node::progress::ProgressUpdate>>> =
        Arc::new(StdMutex::new(Vec::new()));
    let sink = updates.clone();
    ec.progress_callback = Some(Arc::new(move |u| sink.lock().unwrap().push(u)));
    let status = crate::node::registry::instruction_for(&node_type)
        .expect("an instruction node")
        .execute("step", &node_type, ec)
        .await;
    let details: Vec<ProgressDetail> = updates
        .lock()
        .unwrap()
        .iter()
        .filter_map(|u| u.detail.clone())
        .collect();
    let lines = details.iter().map(ProgressDetail::detail_text).collect();
    (status, lines, details)
}

#[tokio::test]
async fn start_guiding_shows_each_phase_it_goes_through() {
    let mut ec = crate::node::context::ExecutionContext::new_for_test("step".to_string());
    ec.run.device_ops = Arc::new(ScriptedDomeRotatorOps::new());
    let config = StartGuidingConfig {
        settle_time: 0.0,
        settle_timeout: 10.0,
        ..StartGuidingConfig::default()
    };

    let (status, lines, _) = step_lines(NodeType::StartGuiding(config), &mut ec).await;

    assert_eq!(status, NodeStatus::Success);
    assert!(
        lines.iter().any(|l| l == "Connecting to guider"),
        "the guider connection phase is shown: {lines:?}"
    );
    assert_eq!(lines.last().map(String::as_str), Some("Guiding active"));
}

#[tokio::test]
async fn wait_for_time_names_the_time_it_waits_for() {
    let mut ec = crate::node::context::ExecutionContext::new_for_test("step".to_string());
    let until = chrono::Utc::now().timestamp() + 1;
    let config = crate::WaitTimeConfig {
        wait_until: Some(until),
        wait_for_twilight: None,
    };

    let (status, lines, _) = step_lines(NodeType::WaitForTime(config), &mut ec).await;

    assert_eq!(status, NodeStatus::Success);
    let clock = chrono::DateTime::from_timestamp(until, 0)
        .unwrap()
        .format("%H:%M:%S");
    assert_eq!(
        lines.first().map(String::as_str),
        Some(format!("Waiting until {clock} UTC").as_str()),
        "the first line is the time waited for, not its hour read as seconds"
    );
    assert_eq!(
        lines.last().map(String::as_str),
        Some("Target time reached")
    );
}

#[tokio::test]
async fn change_filter_shows_its_moves_and_then_the_filter_it_is_on() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ec = crate::node::context::ExecutionContext::new_for_test("step".to_string());
    ec.run.device_ops = ops;
    ec.run.rig.filterwheel_id = Some("fw-1".to_string());
    let config = crate::FilterConfig {
        filter_name: "R".to_string(),
        filter_index: Some(1),
        timeout_secs: None,
    };

    let (status, lines, details) = step_lines(NodeType::ChangeFilter(config), &mut ec).await;

    assert_eq!(status, NodeStatus::Success);
    assert_eq!(lines.first().map(String::as_str), Some("Changing to R"));
    assert!(
        lines.iter().any(|l| l == "Moving to position 1"),
        "the move is shown: {lines:?}"
    );
    let filters: Vec<_> = details
        .iter()
        .filter(|d| matches!(d, ProgressDetail::Filter { .. }))
        .collect();
    assert_eq!(filters.len(), 1, "the filter is published once: {lines:?}");
    assert!(
        matches!(details.last(), Some(ProgressDetail::Filter { name, position: Some(1) }) if name == "R"),
        "the step ends on the filter the wheel is on: {lines:?}"
    );
}
