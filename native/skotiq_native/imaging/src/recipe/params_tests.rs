//! Parameter-reading taxonomy.

use serde_json::json;

use super::*;
use crate::recipe::model::{DarkroomOp, OpContext, OpImage, OpStage};

struct Probe;

impl DarkroomOp for Probe {
    fn id(&self) -> &'static str {
        "probe"
    }

    fn version(&self) -> u32 {
        3
    }

    fn validate_params(&self, _params: &Value) -> Result<(), OpError> {
        Ok(())
    }

    fn apply(
        &self,
        image: &OpImage,
        _params: &Value,
        _ctx: &OpContext,
    ) -> Result<OpImage, OpError> {
        Ok(image.clone())
    }

    fn stage(&self) -> OpStage {
        OpStage::Linear
    }
}

fn params(value: Value) -> Value {
    value
}

#[test]
fn a_non_object_payload_is_rejected() {
    let value = params(json!(42));
    assert_eq!(
        Params::new(&Probe, &value).err(),
        Some(OpError::ParamsNotObject {
            op_id: "probe",
            op_version: 3,
            found: "a number",
        })
    );
}

#[test]
fn a_null_payload_is_rejected() {
    let value = params(json!(null));
    assert!(matches!(
        Params::new(&Probe, &value),
        Err(OpError::ParamsNotObject { .. })
    ));
}

#[test]
fn an_unknown_key_is_rejected() {
    let value = params(json!({"radius": 3, "typo": 1}));
    let p = Params::new(&Probe, &value).expect("payload is an object");
    assert_eq!(
        p.allow(&["radius"]).err(),
        Some(OpError::UnknownParam {
            op_id: "probe",
            op_version: 3,
            key: "typo".to_string(),
        })
    );
}

#[test]
fn an_absent_key_falls_back_to_its_default() {
    let value = params(json!({}));
    let p = Params::new(&Probe, &value).expect("payload is an object");
    assert_eq!(p.f64_or("gamma", 0.0..=1.0, 0.25), Ok(0.25));
    assert_eq!(p.u32_or("degree", 1..=4, 2), Ok(2));
    assert_eq!(p.bool_or("linked", true), Ok(true));
    assert_eq!(p.enum_or("mode", &["rbf", "poly"], "poly"), Ok("poly"));
    assert_eq!(
        p.f64_array_or("white", 3, 0.0..=4.0, &[1.0, 1.0, 1.0]),
        Ok(vec![1.0, 1.0, 1.0])
    );
    assert!(!p.has("gamma"));
}

#[test]
fn a_required_key_that_is_absent_is_reported_as_missing() {
    let value = params(json!({}));
    let p = Params::new(&Probe, &value).expect("payload is an object");
    assert_eq!(
        p.f64_required("gamma", 0.0..=1.0).err(),
        Some(OpError::MissingParam {
            op_id: "probe",
            op_version: 3,
            key: "gamma".to_string(),
        })
    );
    assert!(matches!(
        p.u32_required("degree", 1..=4),
        Err(OpError::MissingParam { .. })
    ));
}

#[test]
fn a_wrong_type_is_reported_with_both_types() {
    let value = params(json!({"gamma": "half"}));
    let p = Params::new(&Probe, &value).expect("payload is an object");
    assert_eq!(
        p.f64_or("gamma", 0.0..=1.0, 0.5).err(),
        Some(OpError::ParamType {
            op_id: "probe",
            op_version: 3,
            key: "gamma".to_string(),
            expected: "a number",
            found: "a string",
        })
    );
}

#[test]
fn an_out_of_range_value_is_rejected() {
    let value = params(json!({"gamma": 4.0}));
    let p = Params::new(&Probe, &value).expect("payload is an object");
    assert!(matches!(
        p.f64_or("gamma", 0.0..=1.0, 0.5),
        Err(OpError::ParamRange { .. })
    ));
}

#[test]
fn a_negative_integer_is_rejected_as_the_wrong_type() {
    let value = params(json!({"degree": -1}));
    let p = Params::new(&Probe, &value).expect("payload is an object");
    assert!(matches!(
        p.u32_or("degree", 0..=4, 1),
        Err(OpError::ParamType { .. })
    ));
}

#[test]
fn an_integer_past_the_range_is_rejected() {
    let value = params(json!({"degree": 9}));
    let p = Params::new(&Probe, &value).expect("payload is an object");
    assert!(matches!(
        p.u32_or("degree", 0..=4, 1),
        Err(OpError::ParamRange { .. })
    ));
}

#[test]
fn an_unlisted_enum_value_is_rejected() {
    let value = params(json!({"mode": "wavelet"}));
    let p = Params::new(&Probe, &value).expect("payload is an object");
    assert!(matches!(
        p.enum_or("mode", &["rbf", "poly"], "poly"),
        Err(OpError::ParamRange { .. })
    ));
}

#[test]
fn an_enum_value_returns_the_registered_spelling() {
    let value = params(json!({"mode": "rbf"}));
    let p = Params::new(&Probe, &value).expect("payload is an object");
    assert_eq!(p.enum_or("mode", &["rbf", "poly"], "poly"), Ok("rbf"));
}

#[test]
fn an_array_of_the_wrong_length_is_rejected() {
    let value = params(json!({"white": [1.0, 1.0]}));
    let p = Params::new(&Probe, &value).expect("payload is an object");
    assert!(matches!(
        p.f64_array_or("white", 3, 0.0..=4.0, &[1.0, 1.0, 1.0]),
        Err(OpError::ParamRange { .. })
    ));
}

#[test]
fn an_array_element_out_of_range_is_rejected() {
    let value = params(json!({"white": [1.0, 9.0, 1.0]}));
    let p = Params::new(&Probe, &value).expect("payload is an object");
    assert!(matches!(
        p.f64_array_or("white", 3, 0.0..=4.0, &[1.0, 1.0, 1.0]),
        Err(OpError::ParamRange { .. })
    ));
}

#[test]
fn an_array_is_read_in_order() {
    let value = params(json!({"white": [1.0, 2.0, 3.0]}));
    let p = Params::new(&Probe, &value).expect("payload is an object");
    assert_eq!(
        p.f64_array_or("white", 3, 0.0..=4.0, &[1.0, 1.0, 1.0]),
        Ok(vec![1.0, 2.0, 3.0])
    );
}

#[test]
fn a_boolean_of_the_wrong_type_is_rejected() {
    let value = params(json!({"linked": 1}));
    let p = Params::new(&Probe, &value).expect("payload is an object");
    assert!(matches!(
        p.bool_or("linked", false),
        Err(OpError::ParamType { .. })
    ));
}
