//! The operation catalogue: what every registered operation is called, what it
//! emits, and what each of its parameters accepts.
//!
//! # Why the table lives here and not in Dart
//!
//! The autopilot drafts a recipe and the editor draws parameter controls. Both
//! need each operation's ranges and defaults, and both would otherwise carry a
//! second copy of numbers the Rust operation already owns — a copy that drifts
//! the first time a range moves. This surface publishes them once.
//!
//! # Why the table is data and not derived
//!
//! An operation validates its own payload; it does not describe it. Rather than
//! widen the operation trait, the table below states each parameter and the
//! tests cross-check every row against the operation's own
//! `validate_params`: every declared key is accepted, an undeclared key is
//! rejected, each bound validates and a value past it does not, and every
//! registered operation has a row. A range that moves in an operation without
//! moving here fails those tests rather than misleading the editor.

use serde_json::{json, Map, Value};
use skotiq_imaging::recipe::ops::crop::auto_rect;
use skotiq_imaging::recipe::ops::stretch::auto_params;
use skotiq_imaging::recipe::{
    render, OpContext, OpImage, Recipe, RecipeAuthor, RecipeError, RecipeStep, RenderOptions,
};

use super::state::{registry, render_cache, LoadedMaster};

/// The JSON type of a parameter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ParamKind {
    /// A finite float.
    Number,
    /// A non-negative integer.
    Integer,
    /// One of `allowed`.
    Enumerated,
    /// A fixed-length array of finite floats.
    NumberArray,
    /// A variable-length array of finite floats.
    NumberList,
}

impl ParamKind {
    /// The `camelCase` wire token.
    fn as_wire(&self) -> &'static str {
        match self {
            Self::Number => "number",
            Self::Integer => "integer",
            Self::Enumerated => "enum",
            Self::NumberArray => "numberArray",
            Self::NumberList => "numberList",
        }
    }
}

/// One parameter of one operation version.
pub(crate) struct ParamDoc {
    /// Wire key.
    pub(crate) name: &'static str,
    /// What an operator calls this parameter, with its unit where it has one.
    ///
    /// The wire key is the recipe's own vocabulary — `d`, `b`, `blackPoint` —
    /// and an editor that labels a control with it asks the operator to know
    /// the engine's field names. The registry owns the unit as well as the
    /// range, so it states both here rather than leaving the editor to invent
    /// either. The wire key is still published beside it, so a control can be
    /// matched to the JSON the recipe stores.
    pub(crate) display_name: &'static str,
    pub(crate) kind: ParamKind,
    /// Whether the payload must carry it.
    pub(crate) required: bool,
    /// Lowest accepted value, for a number or each element of an array.
    pub(crate) min: Option<f64>,
    /// Highest accepted value.
    pub(crate) max: Option<f64>,
    /// Exact element count for a `numberArray`.
    pub(crate) length: Option<usize>,
    /// Element-count bounds for a `numberList`.
    pub(crate) length_range: Option<(usize, usize)>,
    /// Accepted tokens for an `enum`.
    pub(crate) allowed: &'static [&'static str],
    /// The value the operation reads when the key is absent, as JSON text.
    /// `None` for a required parameter, and for one whose absence means
    /// something other than a value.
    pub(crate) default_json: Option<&'static str>,
    /// A value inside every constraint, as JSON text. The editor seeds a new
    /// step with it and the tests probe with it.
    pub(crate) example_json: &'static str,
    /// Whether this parameter is validated on its own. `false` means it is
    /// constrained jointly with another parameter — `whitePoint` above
    /// `blackPoint`, `y` matching the length of `x` — so a control that changes
    /// it alone can be rejected for a reason its own range does not show, and
    /// the editor validates the pair together.
    pub(crate) independent: bool,
    /// What the parameter does, in the words the editor shows.
    pub(crate) summary: &'static str,
}

/// One registered operation version.
pub(crate) struct OpDoc {
    pub(crate) id: &'static str,
    pub(crate) version: u32,
    /// `linear` or `stretched`: the domain the operation emits.
    pub(crate) stage: &'static str,
    pub(crate) summary: &'static str,
    pub(crate) params: &'static [ParamDoc],
}

/// Every operation this build registers, in registry order.
pub(crate) const OP_DOCS: &[OpDoc] = &[
    OpDoc {
        id: "background_extract",
        version: 1,
        stage: "linear",
        summary: "Fits a smooth background model from a star-rejected sample lattice and subtracts it, keeping the frame's pedestal.",
        params: &[
            ParamDoc {
                name: "sampleSpacing",
                display_name: "Sample spacing (master pixels)",
                kind: ParamKind::Number,
                required: false,
                min: Some(8.0),
                max: Some(1024.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("64.0"),
                example_json: "64.0",
                independent: true,
                summary: "Spacing in master pixels between background sample boxes.",
            },
            ParamDoc {
                name: "exclusionPercentile",
                display_name: "Darkest-sample fraction kept",
                kind: ParamKind::Number,
                required: false,
                min: Some(0.05),
                max: Some(1.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("0.75"),
                example_json: "0.75",
                independent: true,
                summary: "Fraction of the darkest samples kept, so nebulosity does not become background.",
            },
            ParamDoc {
                name: "modelOrder",
                display_name: "Background polynomial degree",
                kind: ParamKind::Integer,
                required: false,
                min: Some(0.0),
                max: Some(6.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("2"),
                example_json: "2",
                independent: true,
                summary: "Polynomial degree of the background surface.",
            },
        ],
    },
    OpDoc {
        id: "stretch",
        version: 1,
        stage: "stretched",
        summary: "Applies a generalised hyperbolic stretch, leaving the linear stage.",
        params: &[
            ParamDoc {
                name: "blackPoint",
                display_name: "Black point (ADU)",
                kind: ParamKind::Number,
                required: true,
                min: Some(-1e12),
                max: Some(1e12),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: None,
                example_json: "0.0",
                independent: false,
                summary: "ADU mapped to 0. Must sit below whitePoint.",
            },
            ParamDoc {
                name: "whitePoint",
                display_name: "White point (ADU)",
                kind: ParamKind::Number,
                required: true,
                min: Some(-1e12),
                max: Some(1e12),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: None,
                example_json: "1.0",
                independent: false,
                summary: "ADU mapped to 1. Must sit above blackPoint.",
            },
            ParamDoc {
                name: "d",
                display_name: "Stretch intensity",
                kind: ParamKind::Number,
                required: false,
                min: Some(0.0),
                max: Some(100.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("1.0"),
                example_json: "1.0",
                independent: true,
                summary: "Stretch intensity; 0 is the identity ramp.",
            },
            ParamDoc {
                name: "b",
                display_name: "Local intensity",
                kind: ParamKind::Number,
                required: false,
                min: Some(-5.0),
                max: Some(15.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("0.0"),
                example_json: "0.0",
                independent: true,
                summary: "Local intensity: the generalised-hyperbolic family selector.",
            },
            ParamDoc {
                name: "symmetryPoint",
                display_name: "Symmetry point (normalised)",
                kind: ParamKind::Number,
                required: false,
                min: Some(0.0),
                max: Some(1.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("0.0"),
                example_json: "0.0",
                independent: true,
                summary: "Normalised position the curve is symmetric about.",
            },
        ],
    },
    OpDoc {
        id: "crop",
        version: 1,
        stage: "linear",
        summary: "Cuts a rectangle out of the frame and moves the reference pixel with it.",
        params: &[
            ParamDoc {
                name: "x",
                display_name: "Left edge (master pixels)",
                kind: ParamKind::Integer,
                required: false,
                min: Some(0.0),
                max: Some(1_000_000.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("0"),
                example_json: "0",
                independent: true,
                summary: "Left edge in master pixels.",
            },
            ParamDoc {
                name: "y",
                display_name: "Top edge (master pixels)",
                kind: ParamKind::Integer,
                required: false,
                min: Some(0.0),
                max: Some(1_000_000.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("0"),
                example_json: "0",
                independent: true,
                summary: "Top edge in master pixels.",
            },
            ParamDoc {
                name: "width",
                display_name: "Width (master pixels)",
                kind: ParamKind::Integer,
                required: true,
                min: Some(1.0),
                max: Some(1_000_000.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: None,
                example_json: "16",
                independent: true,
                summary: "Rectangle width in master pixels.",
            },
            ParamDoc {
                name: "height",
                display_name: "Height (master pixels)",
                kind: ParamKind::Integer,
                required: true,
                min: Some(1.0),
                max: Some(1_000_000.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: None,
                example_json: "16",
                independent: true,
                summary: "Rectangle height in master pixels.",
            },
        ],
    },
    OpDoc {
        id: "color_calibrate",
        version: 1,
        stage: "linear",
        summary: "Scales the channels of a three-channel master from a Johnson B-V colour-versus-flux regression against the caller's photometry. It is not full spectrophotometric calibration: the shipped photometry is B and V only.",
        params: &[
            ParamDoc {
                name: "channelScale",
                display_name: "Per-channel scales",
                kind: ParamKind::NumberArray,
                required: false,
                min: Some(1e-6),
                max: Some(1e6),
                length: Some(3),
                length_range: None,
                allowed: &[],
                default_json: None,
                example_json: "[1.0, 1.0, 1.0]",
                independent: true,
                summary: "Explicit per-channel scales. Absent solves them from the catalogue instead.",
            },
            ParamDoc {
                name: "whiteRefBv",
                display_name: "Neutral colour (B-V)",
                kind: ParamKind::Number,
                required: false,
                min: Some(-0.5),
                max: Some(2.5),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("0.65"),
                example_json: "0.65",
                independent: true,
                summary: "B-V of the colour the calibration renders neutral.",
            },
            ParamDoc {
                name: "magLimit",
                display_name: "Faintest catalogue magnitude (V)",
                kind: ParamKind::Number,
                required: false,
                min: Some(5.0),
                max: Some(22.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("17.0"),
                example_json: "17.0",
                independent: true,
                summary: "Faintest catalogue V magnitude used.",
            },
            ParamDoc {
                name: "matchRadiusPx",
                display_name: "Match radius (render pixels)",
                kind: ParamKind::Number,
                required: false,
                min: Some(0.5),
                max: Some(32.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("3.0"),
                example_json: "3.0",
                independent: true,
                summary: "How far a detected star may sit from its catalogue position.",
            },
            ParamDoc {
                name: "minStars",
                display_name: "Fewest matched stars",
                kind: ParamKind::Integer,
                required: false,
                min: Some(8.0),
                max: Some(100_000.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("8"),
                example_json: "8",
                independent: true,
                summary: "Fewest matched stars the fit accepts.",
            },
        ],
    },
    OpDoc {
        id: "denoise",
        version: 1,
        stage: "linear",
        summary: "Shrinks starlet-wavelet detail coefficients against each scale's own measured noise, and smooths chroma separately.",
        params: &[
            ParamDoc {
                name: "scaleCount",
                display_name: "Wavelet scales",
                kind: ParamKind::Integer,
                required: false,
                min: Some(1.0),
                max: Some(6.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("4"),
                example_json: "4",
                independent: true,
                summary: "Wavelet scales thresholded, in render-level pixels.",
            },
            ParamDoc {
                name: "thresholdSigma",
                display_name: "Detail threshold (noise sigmas)",
                kind: ParamKind::Number,
                required: false,
                min: Some(0.0),
                max: Some(10.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("3.0"),
                example_json: "3.0",
                independent: true,
                summary: "Detail threshold in per-scale noise sigmas; 0 shrinks nothing.",
            },
            ParamDoc {
                name: "strength",
                display_name: "Strength",
                kind: ParamKind::Number,
                required: false,
                min: Some(0.0),
                max: Some(1.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("1.0"),
                example_json: "1.0",
                independent: true,
                summary: "Weight the whole correction is applied at; 0 is the identity.",
            },
            ParamDoc {
                name: "chromaStrength",
                display_name: "Chroma strength",
                kind: ParamKind::Number,
                required: false,
                min: Some(0.0),
                max: Some(1.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("0.5"),
                example_json: "0.5",
                independent: true,
                summary: "Weight the chroma low-pass is applied at. A mono master has no chroma.",
            },
        ],
    },
    OpDoc {
        id: "star_reduce",
        version: 1,
        stage: "stretched",
        summary: "De-emphasises detected stars morphologically. It removes no star and leaves mask-zero pixels byte-identical.",
        params: &[
            ParamDoc {
                name: "amount",
                display_name: "Amount",
                kind: ParamKind::Number,
                required: false,
                min: Some(0.0),
                max: Some(1.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("0.5"),
                example_json: "0.5",
                independent: true,
                summary: "How far a star core is pulled toward its surroundings; 0 is an exact clone.",
            },
            ParamDoc {
                name: "maskThresholdSigma",
                display_name: "Mask threshold (noise sigmas)",
                kind: ParamKind::Number,
                required: false,
                min: Some(1.0),
                max: Some(20.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("5.0"),
                example_json: "5.0",
                independent: true,
                summary: "Detection threshold above the background, in noise sigmas.",
            },
            ParamDoc {
                name: "maskDilatePx",
                display_name: "Mask dilation (render pixels)",
                kind: ParamKind::Number,
                required: false,
                min: Some(0.0),
                max: Some(32.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("2.0"),
                example_json: "2.0",
                independent: true,
                summary: "Pixels the star mask grows by before it is feathered.",
            },
        ],
    },
    OpDoc {
        id: "saturation",
        version: 1,
        stage: "stretched",
        summary: "Scales each pixel's departure from its own luminance, protecting the brightest tones.",
        params: &[
            ParamDoc {
                name: "amount",
                display_name: "Saturation change",
                kind: ParamKind::Number,
                required: false,
                min: Some(-1.0),
                max: Some(3.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("0.0"),
                example_json: "0.0",
                independent: true,
                summary: "Saturation change; 0 is the identity and -1 is fully desaturated.",
            },
            ParamDoc {
                name: "protection",
                display_name: "Highlight protection",
                kind: ParamKind::Number,
                required: false,
                min: Some(0.0),
                max: Some(1.0),
                length: None,
                length_range: None,
                allowed: &[],
                default_json: Some("0.5"),
                example_json: "0.5",
                independent: true,
                summary: "How strongly highlights are held back from the change.",
            },
        ],
    },
    OpDoc {
        id: "curves",
        version: 1,
        stage: "stretched",
        summary: "Applies a monotone spline through the given control points, on luminance or per channel.",
        params: &[
            ParamDoc {
                name: "mode",
                display_name: "Curve mode",
                kind: ParamKind::Enumerated,
                required: false,
                min: None,
                max: None,
                length: None,
                length_range: None,
                allowed: &["luminance", "perChannel"],
                default_json: Some("\"luminance\""),
                example_json: "\"luminance\"",
                independent: true,
                summary: "Whether the curve moves luminance alone or each channel.",
            },
            ParamDoc {
                name: "x",
                display_name: "Control-point inputs",
                kind: ParamKind::NumberList,
                required: false,
                min: Some(0.0),
                max: Some(1.0),
                length: None,
                length_range: Some((2, 16)),
                allowed: &[],
                default_json: Some("[0.0, 1.0]"),
                example_json: "[0.0, 1.0]",
                independent: false,
                summary: "Control-point inputs, strictly increasing from 0 to 1.",
            },
            ParamDoc {
                name: "y",
                display_name: "Control-point outputs",
                kind: ParamKind::NumberList,
                required: false,
                min: Some(0.0),
                max: Some(1.0),
                length: None,
                length_range: Some((2, 16)),
                allowed: &[],
                default_json: Some("[0.0, 1.0]"),
                example_json: "[0.0, 1.0]",
                independent: false,
                summary: "Control-point outputs, one per entry of x.",
            },
        ],
    },
];

/// Parse one JSON constant from the table.
///
/// A constant that does not parse is a mistake in [`OP_DOCS`] itself, and the
/// catalogue reports it rather than publishing a null the editor would draw a
/// control from.
fn table_json(text: &str, op_id: &str, param: &str, slot: &str) -> Result<Value, String> {
    serde_json::from_str(text)
        .map_err(|e| format!("the {slot} of {op_id}.{param} is not valid JSON: {e}"))
}

/// The parameter object built from every documented default, for a step the
/// caller wants written out in full.
pub(crate) fn default_params(doc: &OpDoc) -> Result<Value, String> {
    let mut map = Map::new();
    for param in doc.params {
        if let Some(text) = param.default_json {
            map.insert(
                param.name.to_string(),
                table_json(text, doc.id, param.name, "default")?,
            );
        }
    }
    Ok(Value::Object(map))
}

/// The parameter object built from every documented example, which satisfies
/// every constraint of every parameter at once.
pub(crate) fn example_params(doc: &OpDoc) -> Result<Value, String> {
    let mut map = Map::new();
    for param in doc.params {
        map.insert(
            param.name.to_string(),
            table_json(param.example_json, doc.id, param.name, "example")?,
        );
    }
    Ok(Value::Object(map))
}

/// The catalogue as wire JSON.
pub(crate) fn ops_json() -> Result<Value, String> {
    let mut ops = Vec::with_capacity(OP_DOCS.len());
    for doc in OP_DOCS {
        let mut params = Vec::with_capacity(doc.params.len());
        for param in doc.params {
            let mut entry = json!({
                "name": param.name,
                "displayName": param.display_name,
                "kind": param.kind.as_wire(),
                "required": param.required,
                "example": table_json(param.example_json, doc.id, param.name, "example")?,
                "independent": param.independent,
                "summary": param.summary,
            });
            if let Some(min) = param.min {
                entry["min"] = json!(min);
            }
            if let Some(max) = param.max {
                entry["max"] = json!(max);
            }
            if let Some(length) = param.length {
                entry["length"] = json!(length);
            }
            if let Some((min_length, max_length)) = param.length_range {
                entry["minLength"] = json!(min_length);
                entry["maxLength"] = json!(max_length);
            }
            if !param.allowed.is_empty() {
                entry["allowed"] = json!(param.allowed);
            }
            if let Some(text) = param.default_json {
                entry["default"] = table_json(text, doc.id, param.name, "default")?;
            }
            params.push(entry);
        }
        ops.push(json!({
            "id": doc.id,
            "version": doc.version,
            "stage": doc.stage,
            "summary": doc.summary,
            "params": params,
            "defaults": default_params(doc)?,
            "example": example_params(doc)?,
        }));
    }
    Ok(Value::Array(ops))
}

/// The documentation for one operation version.
pub(crate) fn doc_for(id: &str, version: u32) -> Option<&'static OpDoc> {
    OP_DOCS
        .iter()
        .find(|doc| doc.id == id && doc.version == version)
}

/// Longest edge the draft's linear prefix is measured at.
///
/// The stretch parameters are value-domain, so measuring them at a coarse level
/// costs a fraction of a full render and reads the same background and the same
/// dynamic range the full render will.
const DRAFT_MEASURE_MAX_DIMENSION: u32 = 1024;

/// A first-draft recipe for `master`, plus the measurements behind it.
///
/// The draft is the autopilot's opening interpretation: trim the registration
/// edge, flatten the background, shrink the noise, calibrate colour when the
/// master has colour to calibrate, and lift the background to a viewable level.
/// Every step that cannot be drafted is left out and the reason is recorded —
/// a draft never carries a step whose parameters were guessed.
pub(crate) fn draft_for_master(
    master: &LoadedMaster,
    recipe_id: &str,
    base_master_ref: &str,
) -> Result<Value, String> {
    let base = master.pyramid.base();
    let mut notes: Vec<Value> = Vec::new();
    let mut steps: Vec<RecipeStep> = Vec::new();

    let crop_rect = auto_rect(base);
    let crop_params = match crop_rect {
        Some(rect) => {
            steps.push(RecipeStep::new("crop", 1).with_params(rect.to_params()));
            Some(rect.to_params())
        }
        None => {
            notes.push(json!({
                "opId": "crop",
                "outcome": "omitted",
                "reason": "no fully covered rectangle survives in this master, so no crop is proposed",
            }));
            None
        }
    };

    for id in ["background_extract", "denoise"] {
        // The stored step carries an empty payload: a documented default lives
        // in the operation for the life of its version, and writing one into the
        // recipe would freeze today's value into a recipe that should follow it.
        steps.push(RecipeStep::new(id, 1));
    }

    if base.channels() == 3 {
        steps.push(RecipeStep::new("color_calibrate", 1));
    } else {
        let channels = base.channels();
        let (count, coverage) = if channels == 1 {
            ("1 channel".to_string(), "the one channel it was given")
        } else {
            (format!("{channels} channels"), "the channels it was given")
        };
        notes.push(json!({
            "opId": "color_calibrate",
            "outcome": "omitted",
            "reason": format!(
                "this master has {count} and the colour fit needs three, so this draft covers {coverage}; to calibrate colour, combine the per-filter masters into a single three-channel master and draft that composite",
            ),
        }));
    }

    let measure_level = master
        .pyramid
        .level_for_max_dimension(DRAFT_MEASURE_MAX_DIMENSION);
    let (measured, mut steps) = measure_linear_prefix(
        master,
        measure_level,
        recipe_id,
        base_master_ref,
        steps,
        &mut notes,
    )?;
    let stretch_params = match auto_params(&measured) {
        Ok(params) => {
            let payload = params.to_params();
            steps.push(RecipeStep::new("stretch", 1).with_params(payload.clone()));
            Some(payload)
        }
        Err(reason) => {
            notes.push(json!({
                "opId": "stretch",
                "outcome": "omitted",
                "reason": reason.to_string(),
            }));
            None
        }
    };

    let mut draft = Recipe::new(
        if recipe_id.is_empty() {
            "draft"
        } else {
            recipe_id
        },
        base_master_ref,
        RecipeAuthor::Autopilot,
    );
    draft.steps = steps;
    let ops = registry()?;
    skotiq_imaging::recipe::validate(&draft, ops).map_err(|e| {
        format!("the drafted recipe does not validate against this build's operations: {e}")
    })?;

    let mut defaults = Map::new();
    for id in ["background_extract", "denoise"] {
        let doc = doc_for(id, 1)
            .ok_or_else(|| format!("the operation catalogue carries no entry for {id}@1"))?;
        defaults.insert(id.to_string(), default_params(doc)?);
    }

    Ok(json!({
        "recipe": serde_json::to_value(&draft)
            .map_err(|e| format!("cannot encode the drafted recipe: {e}"))?,
        "notes": notes,
        "autoParams": {
            "cropRect": crop_params,
            "stretch": stretch_params,
            "stretchMeasuredAtLevel": measure_level,
            "defaults": Value::Object(defaults),
        },
    }))
}

/// Render the draft's linear prefix at `level`, so the stretch is measured
/// against the pixels it will actually see rather than the raw master.
///
/// A step whose own data preconditions this master does not meet — a background
/// lattice too sparse to fit a surface, say — is dropped from the draft and the
/// operation's own reason is recorded. The alternative would be a draft carrying
/// a step that fails the first time the editor renders it. The loop terminates
/// because every pass either returns or removes one step.
fn measure_linear_prefix(
    master: &LoadedMaster,
    level: u32,
    recipe_id: &str,
    base_master_ref: &str,
    mut steps: Vec<RecipeStep>,
    notes: &mut Vec<Value>,
) -> Result<(OpImage, Vec<RecipeStep>), String> {
    let base = master
        .pyramid
        .level(level)
        .ok_or_else(|| format!("pyramid level {level} is out of range while drafting"))?;
    let ops = registry()?;
    let mut ctx = OpContext::new().at_level(level);
    if let Some(wcs) = base.wcs() {
        ctx = ctx.with_wcs(wcs);
    }

    loop {
        if steps.is_empty() {
            return Ok((base.as_ref().clone(), steps));
        }
        let mut prefix = Recipe::new(
            format!("{recipe_id}:draft-measure"),
            base_master_ref,
            RecipeAuthor::Autopilot,
        );
        prefix.steps = steps.clone();
        let outcome = {
            let mut cache = render_cache();
            render(
                &prefix,
                base,
                ops,
                &mut cache,
                &ctx,
                RenderOptions::full()
                    .at_level(level)
                    .over_master(master.identity.as_str()),
            )
        };
        match outcome {
            Ok(output) => return Ok((output.image.as_ref().clone(), steps)),
            Err(RecipeError::Step { index, source }) => {
                if index >= steps.len() {
                    return Err(format!(
                        "the draft's step {index} failed and the draft holds {} step{}: {source}",
                        steps.len(),
                        if steps.len() == 1 { "" } else { "s" }
                    ));
                }
                let removed = steps.remove(index);
                notes.push(json!({
                    "opId": removed.op_id,
                    "outcome": "omitted",
                    "reason": format!("this master's own data does not support it: {source}"),
                }));
            }
            Err(other) => return Err(format!("cannot measure the draft's linear stack: {other}")),
        }
    }
}
