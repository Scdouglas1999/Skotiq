//! Wire-format, image and context invariants.

use serde_json::json;

use super::*;
use crate::recipe::testkit::{synthetic_star_field, wcs_header};
use crate::{ImageData, PixelType};

fn sample_recipe() -> Recipe {
    let mut recipe = Recipe::new("rec-1", "master-abc", RecipeAuthor::Autopilot);
    recipe.steps = vec![
        RecipeStep::new("background_extract", 1).with_params(json!({"degree": 2})),
        RecipeStep::new("stretch", 1)
            .with_params(json!({"gamma": 0.5}))
            .with_enabled(false),
    ];
    recipe
}

#[test]
fn recipe_round_trips_through_camel_case_json() {
    let recipe = sample_recipe();
    let json = recipe.to_json().expect("recipe encodes");
    assert!(json.contains("\"schemaVersion\":1"), "{json}");
    assert!(json.contains("\"baseMasterRef\":\"master-abc\""), "{json}");
    assert!(json.contains("\"createdBy\":\"autopilot\""), "{json}");
    assert!(json.contains("\"opId\":\"background_extract\""), "{json}");
    assert!(json.contains("\"opVersion\":1"), "{json}");
    assert_eq!(Recipe::from_json(&json).expect("recipe decodes"), recipe);
}

#[test]
fn a_root_recipe_omits_the_parent_key() {
    let json = sample_recipe().to_json().expect("recipe encodes");
    assert!(!json.contains("parent"), "{json}");
}

#[test]
fn a_branch_carries_its_parent_and_divergence_index() {
    let mut recipe = sample_recipe();
    recipe.parent = Some(RecipeParent {
        recipe_id: "rec-0".to_string(),
        divergence_index: 1,
    });
    let json = recipe.to_json().expect("recipe encodes");
    assert!(json.contains("\"recipeId\":\"rec-0\""), "{json}");
    assert!(json.contains("\"divergenceIndex\":1"), "{json}");
    assert_eq!(Recipe::from_json(&json).expect("recipe decodes"), recipe);
}

#[test]
fn a_future_schema_version_is_reported_as_unsupported() {
    let json = r#"{"id":"r","schemaVersion":99,"baseMasterRef":"m","createdBy":"user","steps":[]}"#;
    assert_eq!(
        Recipe::from_json(json),
        Err(RecipeError::UnsupportedSchemaVersion { found: 99 })
    );
}

#[test]
fn a_missing_schema_version_is_a_decode_error() {
    let json = r#"{"id":"r","baseMasterRef":"m","createdBy":"user","steps":[]}"#;
    let Err(RecipeError::Decode(message)) = Recipe::from_json(json) else {
        panic!("an object with no schemaVersion is a decode error");
    };
    assert!(message.contains("missing schemaVersion"), "{message}");
}

#[test]
fn a_payload_that_is_not_an_object_is_refused_for_what_it_is() {
    // Every one of these has no fields at all, so reading `schemaVersion` off
    // it answers `None` — and each used to be reported as a recipe missing
    // that field rather than as the payload the caller actually sent.
    for (json, kind) in [
        ("[]", "an array"),
        ("[1,2,3]", "an array"),
        ("null", "null"),
        ("12345", "a number"),
        ("\"a string\"", "a string"),
        ("true", "a boolean"),
    ] {
        let Err(RecipeError::Decode(message)) = Recipe::from_json(json) else {
            panic!("{json} is not a recipe");
        };
        assert_eq!(
            message,
            format!("a recipe is a JSON object; this payload is {kind}"),
            "payload {json}"
        );
    }
}

#[test]
fn a_schema_version_of_the_wrong_type_is_not_reported_as_absent() {
    let json =
        r#"{"id":"r","schemaVersion":"1","baseMasterRef":"m","createdBy":"user","steps":[]}"#;
    let Err(RecipeError::Decode(message)) = Recipe::from_json(json) else {
        panic!("a string schemaVersion is a decode error");
    };
    assert_eq!(
        message,
        "recipe schemaVersion must be a whole number; this one states \"1\"",
    );
}

#[test]
fn an_unknown_top_level_key_is_rejected() {
    let json = r#"{"id":"r","schemaVersion":1,"baseMasterRef":"m","createdBy":"user","steps":[],"mystery":1}"#;
    assert!(matches!(
        Recipe::from_json(json),
        Err(RecipeError::Decode(_))
    ));
}

#[test]
fn a_step_without_params_decodes_as_an_empty_object() {
    let json = r#"{"id":"r","schemaVersion":1,"baseMasterRef":"m","createdBy":"user","steps":[{"opId":"crop","opVersion":1,"enabled":true}]}"#;
    let recipe = Recipe::from_json(json).expect("recipe decodes");
    assert_eq!(recipe.steps[0].params, json!({}));
}

#[test]
fn a_step_without_enabled_is_a_decode_error() {
    let json = r#"{"id":"r","schemaVersion":1,"baseMasterRef":"m","createdBy":"user","steps":[{"opId":"crop","opVersion":1}]}"#;
    assert!(matches!(
        Recipe::from_json(json),
        Err(RecipeError::Decode(_))
    ));
}

#[test]
fn canonical_json_sorts_object_keys_at_every_depth() {
    let a = json!({"b": 1, "a": {"z": [1, 2], "y": 3}});
    let b = json!({"a": {"y": 3, "z": [1, 2]}, "b": 1});
    assert_eq!(canonical_json(&a), canonical_json(&b));
    assert_eq!(canonical_json(&a), r#"{"a":{"y":3,"z":[1,2]},"b":1}"#);
}

#[test]
fn canonical_json_escapes_control_characters() {
    let value = json!({"k": "line\nbreak\t\"quoted\""});
    assert_eq!(canonical_json(&value), r#"{"k":"line\nbreak\t\"quoted\""}"#);
}

#[test]
fn canonical_json_preserves_array_order() {
    assert_eq!(canonical_json(&json!([3, 1, 2])), "[3,1,2]");
}

#[test]
fn the_canonical_prefix_drops_disabled_steps() {
    let recipe = sample_recipe();
    assert_eq!(recipe.canonical_prefix(1), recipe.canonical_prefix(0));
}

#[test]
fn the_canonical_prefix_grows_with_enabled_steps() {
    let mut recipe = sample_recipe();
    recipe.steps[1].enabled = true;
    assert_ne!(recipe.canonical_prefix(1), recipe.canonical_prefix(0));
}

#[test]
fn the_canonical_prefix_of_an_empty_recipe_is_the_empty_list() {
    let recipe = Recipe::new("r", "m", RecipeAuthor::User);
    assert_eq!(recipe.canonical_prefix(0), "[]");
}

#[test]
fn the_canonical_prefix_ignores_parameter_key_order() {
    let mut left = Recipe::new("r", "m", RecipeAuthor::User);
    left.steps = vec![RecipeStep::new("op", 1).with_params(json!({"a": 1, "b": 2}))];
    let mut right = Recipe::new("r", "m", RecipeAuthor::User);
    right.steps = vec![RecipeStep::new("op", 1).with_params(json!({"b": 2, "a": 1}))];
    assert_eq!(left.canonical_prefix(0), right.canonical_prefix(0));
}

#[test]
fn the_fingerprint_is_stable_and_distinguishes_inputs() {
    assert_eq!(fingerprint_hex(b"skotiq"), fingerprint_hex(b"skotiq"));
    assert_ne!(fingerprint_hex(b"skotiq"), fingerprint_hex(b"nightshadf"));
    assert_eq!(fingerprint_hex(b"").len(), 32);
}

#[test]
fn author_and_stage_wire_tokens_match_the_serialized_form() {
    assert_eq!(RecipeAuthor::Autopilot.as_wire(), "autopilot");
    assert_eq!(RecipeAuthor::User.as_wire(), "user");
    assert_eq!(OpStage::Linear.as_wire(), "linear");
    assert_eq!(OpStage::Stretched.as_wire(), "stretched");
    assert_eq!(
        serde_json::to_string(&OpStage::Stretched).expect("stage encodes"),
        "\"stretched\""
    );
}

#[test]
fn an_f32_image_carries_its_samples_verbatim() {
    let source = ImageData::from_f32(2, 2, 1, &[1.5, -2.25, 3.0, 0.0]);
    let image = OpImage::from_image_data(&source, FitsHeader::new()).expect("image reads");
    assert_eq!(image.data(), &[1.5, -2.25, 3.0, 0.0]);
    assert_eq!(image.to_image_data().pixel_type, PixelType::F32);
}

#[test]
fn a_u16_image_carries_its_adu_values_unscaled() {
    let source = ImageData::from_u16(2, 1, 1, &[0, 65535]);
    let image = OpImage::from_image_data(&source, FitsHeader::new()).expect("image reads");
    assert_eq!(image.data(), &[0.0, 65535.0]);
}

#[test]
fn an_unsupported_pixel_type_is_rejected_rather_than_reinterpreted() {
    let source = ImageData::new(2, 2, 1, PixelType::U32);
    assert_eq!(
        OpImage::from_image_data(&source, FitsHeader::new()).err(),
        Some(OpError::UnsupportedPixelType {
            found: PixelType::U32
        })
    );
}

#[test]
fn an_empty_image_is_rejected() {
    let source = ImageData::new(0, 0, 1, PixelType::F32);
    assert_eq!(
        OpImage::from_image_data(&source, FitsHeader::new()).err(),
        Some(OpError::EmptyImage)
    );
}

#[test]
fn a_buffer_that_does_not_match_the_geometry_is_rejected() {
    assert_eq!(
        OpImage::new(4, 4, 1, vec![0.0; 15], FitsHeader::new()).err(),
        Some(OpError::GeometryMismatch {
            width: 4,
            height: 4,
            channels: 1,
            expected: 16,
            found: 15,
        })
    );
}

#[test]
fn with_data_keeps_the_header_and_geometry() {
    let image = synthetic_star_field(16, 16, 1, 7);
    let next = image
        .with_data(vec![1.0; image.len()])
        .expect("same-geometry buffer is accepted");
    assert_eq!(next.width(), image.width());
    assert_eq!(next.header().get_string("OBJECT"), Some("M31"));
    assert_eq!(
        next.header().get_float("CRVAL1"),
        image.header().get_float("CRVAL1")
    );
}

#[test]
fn with_geometry_updates_the_axis_keywords() {
    let image = synthetic_star_field(16, 16, 1, 7);
    let cropped = image
        .with_geometry(8, 8, 1, vec![0.0; 64])
        .expect("geometry and buffer agree");
    assert_eq!(cropped.header().get_int("NAXIS1"), Some(8));
    assert_eq!(cropped.header().get_int("NAXIS2"), Some(8));
}

#[test]
fn translating_the_reference_pixel_tracks_a_crop_origin() {
    let mut image = synthetic_star_field(16, 16, 1, 7);
    let before = image
        .header()
        .get_float("CRPIX1")
        .expect("header has CRPIX1");
    image.translate_reference_pixel(3.0, 5.0);
    assert_eq!(image.header().get_float("CRPIX1"), Some(before - 3.0));
    assert_eq!(
        image.header().get_float("CRPIX2"),
        Some(8.5 - 5.0),
        "CRPIX2 tracks the vertical crop origin"
    );
}

#[test]
fn a_cd_only_header_reads_back_as_a_wcs_without_sip() {
    let header = wcs_header(100, 100, 1);
    let wcs = wcs_from_header(&header).expect("header carries a complete WCS");
    assert_eq!(wcs.crval1, 10.684_708);
    assert_eq!(wcs.crpix1, 50.5);
    assert_eq!(wcs.a_order, 0);
    assert!(wcs.a_coeffs.is_empty());
}

#[test]
fn sip_terms_are_read_row_major() {
    let mut header = wcs_header(100, 100, 1);
    header.set_int("A_ORDER", 2);
    header.set_float("A_1_1", 1.25e-6);
    header.set_float("A_0_2", -3.5e-7);
    let wcs = wcs_from_header(&header).expect("header carries a complete WCS");
    assert_eq!(wcs.a_order, 2);
    assert_eq!(wcs.a_coeffs.len(), 9);
    assert_eq!(wcs.a_coeffs[4], 1.25e-6);
    assert_eq!(wcs.a_coeffs[2], -3.5e-7);
}

#[test]
fn a_degenerate_cd_matrix_yields_no_wcs() {
    let mut header = wcs_header(100, 100, 1);
    header.set_float("CD1_1", 0.0);
    header.set_float("CD2_2", 0.0);
    assert!(wcs_from_header(&header).is_none());
}

#[test]
fn a_header_without_crval_yields_no_wcs() {
    let header = FitsHeader::new();
    assert!(wcs_from_header(&header).is_none());
}

#[test]
fn the_context_reports_cancellation_once_it_is_requested() {
    let ctx = OpContext::new();
    assert!(!ctx.cancel_requested());
    assert_eq!(ctx.check_cancel(), Ok(()));
    ctx.request_cancel();
    assert!(ctx.cancel_requested());
    assert_eq!(ctx.check_cancel(), Err(OpError::Cancelled));
}

#[test]
fn a_shared_cancel_flag_reaches_a_cloned_context() {
    let ctx = OpContext::new();
    let clone = ctx.clone().at_level(2);
    ctx.request_cancel();
    assert!(clone.cancel_requested());
}

#[test]
fn the_context_scale_halves_per_level() {
    assert_eq!(OpContext::new().scale(), 1.0);
    assert_eq!(OpContext::new().at_level(1).scale(), 0.5);
    assert_eq!(OpContext::new().at_level(3).scale(), 0.125);
}

#[test]
fn the_context_identity_changes_with_level_catalog_and_wcs() {
    let base = OpContext::new();
    let levelled = base.clone().at_level(1);
    assert_ne!(base.identity(), levelled.identity());

    let with_catalog = base
        .clone()
        .with_catalog(crate::recipe::testkit::fixed_catalog());
    assert_ne!(base.identity(), with_catalog.identity());

    let wcs = wcs_from_header(&wcs_header(64, 64, 1)).expect("header carries a WCS");
    let with_wcs = base.clone().with_wcs(wcs.clone());
    assert_ne!(base.identity(), with_wcs.identity());

    let mut moved = wcs;
    moved.crval1 += 0.001;
    assert_ne!(with_wcs.identity(), base.with_wcs(moved).identity());
}

#[test]
fn the_context_identity_follows_what_a_catalog_holds_not_that_it_exists() {
    use std::sync::Arc;

    use crate::recipe::testkit::{fixed_catalog, fixed_stars, FixedCatalog};

    let base = OpContext::new();
    let first = base.clone().with_catalog(fixed_catalog());
    let same_stars = base.clone().with_catalog(Arc::new(FixedCatalog {
        stars: fixed_stars(),
    }));
    assert_eq!(
        first.identity(),
        same_stars.identity(),
        "two handles over the same stars render the same pixels and must share a key"
    );

    let mut revised = fixed_stars();
    revised[0].b_minus_v += 0.01;
    let corrected = base.with_catalog(Arc::new(FixedCatalog { stars: revised }));
    assert_ne!(
        first.identity(),
        corrected.identity(),
        "a colour index the catalog revised reaches the colour fit, so it must reach the key"
    );
}

#[test]
fn the_byte_size_counts_four_bytes_per_sample() {
    let image = synthetic_star_field(8, 8, 3, 1);
    assert_eq!(image.len(), 8 * 8 * 3);
    assert_eq!(image.byte_size(), 8 * 8 * 3 * 4);
    assert_eq!(image.pixel_count(), 64);
}

/// The step numbers an operator READS are the same ones the editor shows.
///
/// The struct fields stay 0-based — code indexes the step list with them — so
/// each sentence is checked against the index it was built from, not against
/// itself. A recipe whose 4th step is unregistered used to be refused with
/// "step 3", beside step cards that call that same step "4 of 4" and an export
/// sheet that writes `step4-stretch` into the exported filename.
#[test]
fn recipe_faults_number_their_steps_the_way_the_editor_does() {
    let unknown = RecipeError::UnknownOp {
        index: 3,
        op_id: "stretch".to_string(),
        op_version: 99,
    };
    assert_eq!(
        unknown.to_string(),
        "step 4: no operation registered as stretch@99"
    );

    let invalid = RecipeError::InvalidParams {
        index: 0,
        op_id: "crop".to_string(),
        op_version: 1,
        source: Box::new(OpError::EmptyImage),
    };
    assert!(
        invalid.to_string().starts_with("step 1 (crop@1) "),
        "{invalid}"
    );

    let order = RecipeError::StageOrder {
        index: 3,
        op_id: "denoise".to_string(),
        op_version: 1,
        blocking_index: 2,
        blocking_op_id: "stretch".to_string(),
    };
    assert_eq!(
        order.to_string(),
        "step 4 (denoise@1) is a linear-stage operation but step 3 (stretch) \
         already left the linear stage"
    );

    let out_of_range = RecipeError::StepIndexOutOfRange {
        index: 4,
        step_count: 4,
    };
    assert_eq!(
        out_of_range.to_string(),
        "step 5 is out of range; the recipe's step count is 4"
    );

    let failed = RecipeError::Step {
        index: 1,
        source: Box::new(OpError::EmptyImage),
    };
    assert!(
        failed.to_string().starts_with("step 2 failed: "),
        "{failed}"
    );

    // The fields themselves did not move: they are what `steps.remove(index)`
    // and the per-step verdict join index with.
    match unknown {
        RecipeError::UnknownOp { index, .. } => assert_eq!(index, 3),
        other => panic!("expected UnknownOp, got {other:?}"),
    }
}
