//! The sequencer config an operator-run autofocus is built from.

use super::{sequencer_autofocus_config, AutofocusConfigApi};
use skotiq_sequencer::{AutofocusConfig, AutofocusMethod, Binning};

fn request() -> AutofocusConfigApi {
    AutofocusConfigApi {
        exposure_time: 2.5,
        step_size: 37,
        steps_out: 6,
        method: "Parabolic".to_string(),
        binning: 2,
        gain: Some(120),
        offset: Some(15),
        number_of_attempts: 3,
        exposures_per_point: 4,
        r_squared_threshold: 0.83,
        outer_crop_ratio: 0.9,
        inner_crop_ratio: 0.2,
        use_brightest_n_stars: 25,
        focuser_settle_time_ms: 750,
        backlash_comp_method: "Overshoot".to_string(),
        backlash_in: 120,
        backlash_out: 40,
        measured_backlash_in: Some(88),
    }
}

#[test]
fn every_request_field_reaches_the_sequencer_config() {
    let config = sequencer_autofocus_config(&request()).expect("valid request");
    assert_eq!(
        config,
        AutofocusConfig {
            exposure_duration: 2.5,
            step_size: 37,
            steps_out: 6,
            method: AutofocusMethod::Quadratic,
            binning: Binning::Two,
            gain: Some(120),
            offset: Some(15),
            max_duration_secs: 600.0,
            number_of_attempts: 3,
            exposures_per_point: 4,
            r_squared_threshold: 0.83,
            outer_crop_ratio: 0.9,
            inner_crop_ratio: 0.2,
            use_brightest_n_stars: 25,
            focuser_settle_time_ms: 750,
            backlash_compensation: 120,
            backlash_out_compensation: 40,
            measured_backlash_in: Some(88),
            ..AutofocusConfig::default()
        }
    );
}

#[test]
fn backlash_method_none_sends_no_compensation() {
    let mut request = request();
    request.backlash_comp_method = " None ".to_string();
    let config = sequencer_autofocus_config(&request).expect("valid request");
    assert_eq!(config.backlash_compensation, 0);
    assert_eq!(config.backlash_out_compensation, 0);
    assert_eq!(config.measured_backlash_in, Some(88));
}

#[test]
fn an_unknown_curve_method_is_refused() {
    let mut request = request();
    request.method = "Mystery".to_string();
    assert!(sequencer_autofocus_config(&request).is_err());
    for known in [
        "",
        "VCurve",
        "v-curve",
        "Hyperbolic",
        "parabolic",
        "Quadratic",
    ] {
        request.method = known.to_string();
        assert!(sequencer_autofocus_config(&request).is_ok(), "{known}");
    }
}

#[test]
fn an_out_of_range_request_is_refused() {
    let mut request = request();
    request.steps_out = 0;
    assert!(sequencer_autofocus_config(&request).is_err());
}
