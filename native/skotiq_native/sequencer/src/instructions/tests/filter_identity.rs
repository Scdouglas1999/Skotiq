//! `filter_identity` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

/// The wheel is parked on slot 1 ("R" in the double's name table) and the
/// node names no filter. The frame is taken THROUGH R, so R is what the
/// FITS FILTER card, the FILTPOS card and the filename must all say —
/// without a filter identity on the sequence context there is no FILTER card
/// at all and the save-path template renders the synthetic `nofilter`
/// label.
#[tokio::test]
async fn burst_records_the_filter_the_wheel_is_parked_on() {
    let scratch = scratch_dir("wheel-filter");
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ec = expose_node_execution_ctx(ops.clone(), scratch.0.clone()).await;

    let status = run_expose_node(one_dark_no_filter(), &mut ec).await;
    assert_eq!(status, NodeStatus::Success, "burst should complete");

    let saved = ops.saved_frame_contexts();
    assert_eq!(saved.len(), 1, "one frame should have reached the writer");
    assert_eq!(
        saved[0].filter_name.as_deref(),
        Some("R"),
        "the FITS FILTER card must name the filter the wheel is actually on"
    );
    assert_eq!(
        saved[0].filter_index,
        Some(1),
        "FILTPOS must record the slot the frame was taken through"
    );

    let paths = ops.saved_frame_paths();
    assert!(
        paths[0].contains("_R_"),
        "the filename must agree with the header, got {}",
        paths[0]
    );
    assert!(
        !paths[0].contains("nofilter"),
        "a known filter must never render as the synthetic nofilter label, got {}",
        paths[0]
    );
}

/// The burst's resolved filter identity must be PUBLISHED, not just kept in
/// the execution context, because Dart writes `captured_images.filter` and
/// `sequence_runs.stats_json`'s filter bucket from the published value.
///
/// Only a Change Filter node ever emitted `ProgressDetail::Filter`. So a
/// burst that addresses the wheel by SLOT — with a Change Filter to "L"
/// (slot 0) earlier in the sequence — wrote `FILTER = 'R'` into the header
/// and `_R_` into the filename here while Dart still held "L", and the
/// database row for that same frame said "L". One frame, two filters.
#[tokio::test]
async fn burst_publishes_the_filter_identity_it_resolved() {
    use std::sync::Mutex as StdMutex;

    let scratch = scratch_dir("publish-filter");
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ec = expose_node_execution_ctx(ops.clone(), scratch.0.clone()).await;
    // What a preceding Change Filter to "L" leaves behind.
    ec.current_filter = Some("L".to_string());
    ec.current_filter_index = Some(0);

    let updates: Arc<StdMutex<Vec<crate::node::progress::ProgressUpdate>>> =
        Arc::new(StdMutex::new(Vec::new()));
    let sink = updates.clone();
    ec.progress_callback = Some(Arc::new(move |u| sink.lock().unwrap().push(u)));

    // Position-addressed burst: slot 1 is "R" in the wheel's name table.
    let config = ExposureConfig {
        filter: None,
        filter_index: Some(1),
        ..one_dark_no_filter()
    };
    let status = run_expose_node(config, &mut ec).await;
    assert_eq!(status, NodeStatus::Success, "burst should complete");

    let saved = ops.saved_frame_contexts();
    assert_eq!(
        saved[0].filter_name.as_deref(),
        Some("R"),
        "the frame was taken through slot 1, which the wheel names R"
    );

    let published: Vec<(String, Option<i32>)> = updates
        .lock()
        .unwrap()
        .iter()
        .filter_map(|u| match u.detail.as_ref() {
            Some(crate::node::progress::ProgressDetail::Filter { name, position }) => {
                Some((name.clone(), *position))
            }
            _ => None,
        })
        .collect();
    assert_eq!(
        published,
        vec![("R".to_string(), Some(1))],
        "the burst must publish exactly the (name, slot) pair it stamped on \
             the frame, so the database row cannot disagree with the header"
    );
}

/// A node that DOES name its own filter. The wheel is moved there by
/// `execute_exposure`, but `${filter}` in the save-path template reads
/// `current_filter` — never `config.filter` — so the file still landed as
/// `..._nofilter_....fits` while the header said "L".
#[tokio::test]
async fn burst_filename_uses_the_filter_the_node_configured() {
    let scratch = scratch_dir("node-filter");
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ec = expose_node_execution_ctx(ops.clone(), scratch.0.clone()).await;

    let config = ExposureConfig {
        filter: Some("L".to_string()),
        filter_index: Some(0),
        ..one_dark_no_filter()
    };
    let status = run_expose_node(config, &mut ec).await;
    assert_eq!(status, NodeStatus::Success, "burst should complete");

    let paths = ops.saved_frame_paths();
    assert!(
        paths[0].contains("_L_"),
        "the filename must carry the node's own filter, got {}",
        paths[0]
    );
    assert_eq!(
        ec.current_filter.as_deref(),
        Some("L"),
        "the run context must carry the filter forward to later nodes"
    );
}

/// The Flat Wizard's final flat burst: `execute_exposure` called directly,
/// with no node and no save-path renderer, and a config whose `filter` is
/// whatever the wizard was configured with — commonly nothing, because the
/// operator shot flats through the filter already on the wheel. The wheel
/// report is what supplies the identity here: flats with no FILTER card
/// cannot be matched to the lights they were shot for by any calibration
/// tool, which is the whole point of taking them.
#[tokio::test]
async fn flat_wizard_burst_records_the_filter_the_wheel_is_parked_on() {
    let scratch = scratch_dir("direct-wheel-filter");
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let ctx = direct_capture_ctx(ops.clone(), scratch.0.clone()).await;

    let config = ExposureConfig {
        duration_secs: 0.01,
        count: 1,
        frame_type: "Flat".to_string(),
        filter: None,
        filter_index: None,
        ..ExposureConfig::default()
    };
    let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;
    assert_eq!(result.status, NodeStatus::Success, "burst should complete");

    let saved = ops.saved_frame_contexts();
    assert_eq!(saved.len(), 1, "one frame should have reached the writer");
    assert_eq!(
        saved[0].filter_name.as_deref(),
        Some("R"),
        "the FITS FILTER card must name the filter the wheel is actually on"
    );
    assert_eq!(
        saved[0].filter_index,
        Some(1),
        "FILTPOS must record the slot the frame was taken through"
    );

    let paths = ops.saved_frame_paths();
    assert!(
        !paths[0].contains("nofilter"),
        "a known filter must never render as the synthetic nofilter label, got {}",
        paths[0]
    );
    assert!(
        paths[0].contains("_R_"),
        "the filename must agree with the header, got {}",
        paths[0]
    );
}

/// D7/R7: the Flat Wizard's final burst went through `execute_exposure`,
/// whose renderer-less branch is the pre-template
/// `<target>_<filter>_<NNNN>.fits` layout. Flats therefore ignored the
/// user's save-path template, and — because flats are not shot at
/// anything, so the run has no target — every file was filed under the
/// synthetic label `untargeted`, next to lights named after their target.
#[tokio::test]
async fn flat_wizard_flats_are_named_by_the_save_path_renderer() {
    let scratch = scratch_dir("flat-wizard-naming");
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let ctx = direct_capture_ctx(ops.clone(), scratch.0.clone()).await;
    assert!(
        ctx.target_name.is_none(),
        "the case under test is a flat run with no target"
    );

    let config = crate::FlatWizardConfig {
        flat_count: 1,
        filter: None,
        filter_index: None,
        ..crate::FlatWizardConfig::default()
    };
    let result =
        crate::flat_wizard::capture_converged_flats(&config, &ctx, 0.01, |_, _, _| {}).await;
    assert_eq!(
        result.status,
        NodeStatus::Success,
        "the flat burst should complete: {:?}",
        result.message
    );

    let paths = ops.saved_frame_paths();
    assert_eq!(paths.len(), 1, "one flat should have reached the writer");
    let filename = std::path::Path::new(&paths[0])
        .file_name()
        .expect("a saved frame has a filename")
        .to_string_lossy()
        .into_owned();
    assert_eq!(
        filename, "Flat_R_0001.fits",
        "a target-less calibration frame is named for its frame type, the way \
             every other renderer-rendered calibration frame in the session is"
    );
}

/// A direct burst that names its filter but carries no slot, run after
/// something else established a different filter. Name and slot must be
/// resolved together: resolving them independently
/// (`config.filter.or(ctx.current_filter)` beside
/// `config.filter_index.or(ctx.current_filter_index)`) stamps the frame with
/// this burst's NAME and the previous burst's SLOT, and the disagreement is
/// silent because each field is individually plausible.
#[tokio::test]
async fn direct_burst_never_pairs_its_filter_name_with_a_stale_slot() {
    let scratch = scratch_dir("direct-stale-slot");
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ctx = direct_capture_ctx(ops.clone(), scratch.0.clone()).await;
    // What a preceding Change Filter to "L" (slot 0) leaves behind.
    ctx.current_filter = Some("L".to_string());
    ctx.current_filter_index = Some(0);

    let config = ExposureConfig {
        duration_secs: 0.01,
        count: 1,
        frame_type: "Flat".to_string(),
        filter: Some("R".to_string()),
        filter_index: None,
        ..ExposureConfig::default()
    };
    let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;
    assert_eq!(result.status, NodeStatus::Success, "burst should complete");

    let saved = ops.saved_frame_contexts();
    assert_eq!(
        saved[0].filter_name.as_deref(),
        Some("R"),
        "the burst's own filter is what the frame was taken through"
    );
    assert_eq!(
        saved[0].filter_index,
        Some(1),
        "FILTPOS must be R's slot, not the slot the previous filter occupied"
    );
}

/// A burst that addresses the wheel BY NAME never learns the slot it landed
/// on, so it must not inherit the previous burst's slot — that describes one
/// frame with two different filters.
#[tokio::test]
async fn name_addressed_burst_does_not_inherit_the_previous_bursts_slot() {
    let scratch = scratch_dir("stale-filter-slot");
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ec = expose_node_execution_ctx(ops.clone(), scratch.0.clone()).await;

    // Burst 1 addresses slot 1 ("R" in the double's name table).
    let by_index = ExposureConfig {
        filter: None,
        filter_index: Some(1),
        ..one_dark_no_filter()
    };
    assert_eq!(
        run_expose_node(by_index, &mut ec).await,
        NodeStatus::Success,
        "position-addressed burst should complete"
    );

    // Burst 2 addresses "L" by name only, exactly what the Dart serializer
    // emits when the profile has no index for that filter.
    let by_name = ExposureConfig {
        filter: Some("L".to_string()),
        filter_index: None,
        ..one_dark_no_filter()
    };
    assert_eq!(
        run_expose_node(by_name, &mut ec).await,
        NodeStatus::Success,
        "name-addressed burst should complete"
    );

    let saved = ops.saved_frame_contexts();
    assert_eq!(saved.len(), 2, "one frame per burst");
    assert_eq!(saved[1].filter_name.as_deref(), Some("L"));
    assert_eq!(
        saved[1].filter_index,
        Some(0),
        "the slot must be the one L actually occupies, not slot 1 left over \
             from the previous burst"
    );
}

/// The wheel does not answer to the name the burst asked for (profile and
/// device naming drifted — "Ha" vs "H-alpha"). The slot is then genuinely
/// unknown, and unknown must be recorded as unknown: keeping the previous
/// burst's slot would file the frame under a filter it was not taken
/// through.
#[tokio::test]
async fn unmatched_filter_name_clears_the_slot_instead_of_keeping_a_stale_one() {
    let scratch = scratch_dir("unmatched-filter-slot");
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ec = expose_node_execution_ctx(ops.clone(), scratch.0.clone()).await;

    let by_index = ExposureConfig {
        filter: None,
        filter_index: Some(1),
        ..one_dark_no_filter()
    };
    assert_eq!(
        run_expose_node(by_index, &mut ec).await,
        NodeStatus::Success,
        "position-addressed burst should complete"
    );

    let unknown_name = ExposureConfig {
        filter: Some("H-alpha".to_string()),
        filter_index: None,
        ..one_dark_no_filter()
    };
    assert_eq!(
        run_expose_node(unknown_name, &mut ec).await,
        NodeStatus::Success,
        "name-addressed burst should complete"
    );

    let saved = ops.saved_frame_contexts();
    assert_eq!(saved[1].filter_name.as_deref(), Some("H-alpha"));
    assert_eq!(
        saved[1].filter_index, None,
        "an unresolvable slot must be recorded as unknown, not as slot 1 \
             left over from the previous burst"
    );
}

/// A rig with no filter wheel at all (OSC / DSLR) must stay honest: no
/// invented label, no FILTER card.
#[tokio::test]
async fn burst_without_a_wheel_leaves_the_filter_unknown() {
    let scratch = scratch_dir("no-wheel");
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ec = expose_node_execution_ctx(ops.clone(), scratch.0.clone()).await;
    ec.filterwheel_id = None;

    let status = run_expose_node(one_dark_no_filter(), &mut ec).await;
    assert_eq!(status, NodeStatus::Success, "burst should complete");

    let saved = ops.saved_frame_contexts();
    assert_eq!(
        saved[0].filter_name, None,
        "with no wheel there is no filter to record"
    );
}
