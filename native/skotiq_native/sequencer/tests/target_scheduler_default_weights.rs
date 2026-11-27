//! The TargetScheduler step's weights as the app writes them for a new step
//! are the run's default weights. The Dart node-codec golden test writes
//! `wire_nodes_defaults.json` from the node's defaults; this test reads it.

use serde_json::Value;
use skotiq_sequencer::scheduling::scoring::ScoringWeights;

#[test]
fn a_new_scheduler_step_carries_the_default_weights() {
    let nodes: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../packages/skotiq_core/test/services/node_codec_goldens/goldens/wire_nodes_defaults.json"
    )))
    .expect("the golden is JSON");
    let step = nodes["n-TargetScheduler"]["node_type"].clone();
    let weights: ScoringWeights =
        serde_json::from_value(step).expect("the step carries every weight");
    assert_eq!(weights, ScoringWeights::default());
}
