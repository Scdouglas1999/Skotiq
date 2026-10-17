//! Registry lookup and the version-permanence contract.

use std::sync::Arc;

use super::*;
use crate::recipe::testkit::{test_registry, CurvesLikeOp, ScaleOp};

#[test]
fn the_builtin_list_registers_cleanly_and_carries_the_operations_this_build_ships() {
    let registry = OpRegistry::builtin().expect("the builtin list registers cleanly");
    assert_eq!(registry.len(), builtin_ops().len());
    for (op_id, op_version) in [("background_extract", 1), ("stretch", 1), ("crop", 1)] {
        let op = registry
            .get(op_id, op_version)
            .unwrap_or_else(|| panic!("{op_id}@{op_version} is registered"));
        assert_eq!(op.id(), op_id);
        assert_eq!(op.version(), op_version);
    }
}

#[test]
fn an_empty_registry_finds_nothing() {
    let registry = OpRegistry::new();
    assert!(registry.get("stretch", 1).is_none());
    assert_eq!(registry.latest_version("stretch"), None);
}

#[test]
fn an_operation_is_found_by_id_and_version() {
    let registry = test_registry();
    let op = registry
        .get("test_scale", 1)
        .expect("test_scale@1 is registered");
    assert_eq!(op.id(), "test_scale");
    assert_eq!(op.version(), 1);
    assert!(registry.get("test_scale", 7).is_none());
}

#[test]
fn old_versions_stay_registered_beside_new_ones() {
    let registry = test_registry();
    assert!(registry.get("test_scale", 1).is_some());
    assert!(registry.get("test_scale", 2).is_some());
    assert_eq!(registry.latest_version("test_scale"), Some(2));
}

#[test]
fn a_duplicate_registration_is_rejected_rather_than_overwriting() {
    let mut registry = OpRegistry::new();
    registry
        .register(Arc::new(ScaleOp::new(1)))
        .expect("first registration succeeds");
    assert_eq!(
        registry.register(Arc::new(ScaleOp::new(1))),
        Err(RegistryError::DuplicateRegistration {
            op_id: "test_scale".to_string(),
            op_version: 1,
        })
    );
    assert_eq!(registry.len(), 1);
}

#[test]
fn version_zero_is_rejected() {
    let mut registry = OpRegistry::new();
    assert_eq!(
        registry.register(Arc::new(ScaleOp::new(0))),
        Err(RegistryError::ZeroVersion {
            op_id: "test_scale".to_string()
        })
    );
}

#[test]
fn keys_and_ids_come_back_sorted() {
    let mut registry = OpRegistry::new();
    registry
        .register(Arc::new(CurvesLikeOp))
        .expect("test_curves@1 registers");
    registry
        .register(Arc::new(ScaleOp::new(2)))
        .expect("test_scale@2 registers");
    registry
        .register(Arc::new(ScaleOp::new(1)))
        .expect("test_scale@1 registers");
    assert_eq!(
        registry.keys(),
        vec![
            ("test_curves".to_string(), 1),
            ("test_scale".to_string(), 1),
            ("test_scale".to_string(), 2),
        ]
    );
    assert_eq!(
        registry.ids(),
        vec!["test_curves".to_string(), "test_scale".to_string()]
    );
}

#[test]
fn the_debug_form_lists_what_is_registered() {
    let mut registry = OpRegistry::new();
    registry
        .register(Arc::new(ScaleOp::new(1)))
        .expect("test_scale@1 registers");
    assert!(format!("{registry:?}").contains("test_scale"));
}
