//! Pre-run validation: which devices a sequence tree needs, whether the
//! assigned profile supplies them, whether every instruction is reachable,
//! and whether the capture save path is writable. Moved verbatim out of
//! `executor/mod.rs`.

use super::*;

/// Walk a runtime node tree (pre-order) and return the first Autofocus node's
/// configuration. Used to seed the trigger-driven autofocus config from the
/// sequence's own Autofocus node so HFR / temperature / interval refocus
/// triggers use the operator's real tuning instead of library defaults.
pub(super) fn find_first_autofocus_config(node: &dyn Node) -> Option<crate::AutofocusConfig> {
    if let NodeType::Autofocus(config) = node.node_type() {
        return Some(config.clone());
    }
    node.children()
        .iter()
        .find_map(|child| find_first_autofocus_config(&**child))
}

/// Whether the node tree contains a plate-solve-dependent CenterTarget node.
/// Used to gate the plate-solver/catalog preflight at start() so a sequence
/// that centers on a target fails fast if no solver is installed.
pub(super) fn tree_contains_centering(node: &dyn Node) -> bool {
    if matches!(node.node_type(), NodeType::CenterTarget(_)) {
        return true;
    }
    node.children()
        .iter()
        .any(|child| tree_contains_centering(&**child))
}

/// True when some node in the tree captures frames it must persist through the
/// run's base save path. A `TakeExposure` carrying an absolute `save_to` names
/// its own complete destination, so it does not depend on the base path.
pub(super) fn tree_needs_base_save_path(node: &dyn Node) -> bool {
    let needs_here = match node.node_type() {
        NodeType::TakeExposure(config) => !config
            .save_to
            .as_deref()
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .is_some_and(|t| std::path::Path::new(t).is_absolute()),
        NodeType::SmartExposure(_) => true,
        _ => false,
    };
    needs_here
        || node
            .children()
            .iter()
            .any(|child| tree_needs_base_save_path(&**child))
}

/// A hardware role the loaded sequence declares it needs, in the order the
/// refusal lists them (camera first — it is the one an imaging run cannot do
/// anything at all without).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum RequiredDevice {
    Camera,
    Mount,
    FilterWheel,
    Focuser,
    Rotator,
}

/// Why a role is required: which node asked for it, and (for the camera)
/// whether the asking node captures frames.
///
/// The node name is carried so the refusal can point at the step the operator
/// authored rather than at an abstract capability.
#[derive(Debug, Clone)]
pub(crate) struct DeviceRequirement {
    pub(super) node_name: String,
    pub(super) captures_frames: bool,
}

/// Every hardware role the enabled part of `node`'s subtree needs, keyed by
/// role and remembering the FIRST node in tree order that needs it.
///
/// The mapping is not guesswork — each arm mirrors a `ctx.<role>_id()` call
/// that hard-fails the instruction when the id is absent:
///
/// | node type | accessor that fails | site |
/// |---|---|---|
/// | `TakeExposure` / `SmartExposure` / `FlatWizard` / `SciencePhotometry` | `camera_id()` | `instructions.rs` `execute_exposure_with_renderer` |
/// | `TakeExposure` with a filter | `validate_exposure_filter_request` | `instructions.rs` `execute_exposure_with_renderer` |
/// | `SmartExposure` with any plan | `filterwheel_id()` | `smart_exposure.rs` `run_filter_change` -> `execute_filter_change` |
/// | `CenterTarget` | `mount_id()` then `camera_id()` | `instructions.rs` `execute_center` |
/// | `SlewToTarget` / `Park` / `Unpark` / `MeridianFlip` | `mount_id()` | `execute_slew` / `execute_park` / `execute_unpark` / `execute_meridian_flip_with_autofocus` |
/// | `PolarAlignment` | `mount_id()` then `camera_id()` | `polar_align/mod.rs` |
/// | `Autofocus` | `camera_id()` then `focuser_id()` | `execute_autofocus_once` |
/// | `Autofocus` pinned to a filter | explicit "no filter wheel is connected" failure | `execute_autofocus_admitted_with_pause` |
/// | `TemperatureCompensation` | `focuser_id()` | `temperature_compensation.rs` |
/// | `CoolCamera` / `WarmCamera` | `camera_id()` | `execute_cool_camera` / `execute_warm_camera` |
/// | `ChangeFilter` | `filterwheel_id()` | `execute_filter_change` |
/// | `MoveRotator` | `rotator_id()` | `execute_rotator_move` |
///
/// Two deliberate non-entries: `FlatWizard`'s filter change returns `Ok` when
/// there is no wheel (`flat_wizard/mod.rs` `do_filter_change`), so a flat run
/// is not blocked for a wheel it will not touch; and `Dither` steers the
/// guider, which is not one of the five ids `set_devices` carries.
///
/// Disabled nodes contribute nothing, and neither do their children:
/// `RuntimeNode::execute` returns `Skipped` before it descends, so a disabled
/// subtree never reaches hardware and must never block a start.
pub(super) fn collect_required_devices(
    node: &dyn Node,
    out: &mut std::collections::BTreeMap<RequiredDevice, DeviceRequirement>,
) {
    if !node.is_enabled() {
        return;
    }

    let mut require = |role: RequiredDevice, captures_frames: bool| {
        out.entry(role).or_insert_with(|| DeviceRequirement {
            node_name: node.name().to_string(),
            captures_frames,
        });
    };

    fn names_a_filter(filter: Option<&str>, filter_index: Option<i32>) -> bool {
        filter_index.is_some() || filter.map(str::trim).is_some_and(|name| !name.is_empty())
    }

    match node.node_type() {
        NodeType::TakeExposure(config) => {
            require(RequiredDevice::Camera, true);
            if names_a_filter(config.filter.as_deref(), config.filter_index) {
                require(RequiredDevice::FilterWheel, false);
            }
        }
        NodeType::SmartExposure(config) => {
            require(RequiredDevice::Camera, true);
            // EVERY plan moves the wheel, named or not. SmartExposure fires a
            // ChangeFilter whenever `current_filter != Some(plan.filter_name)`
            // (`smart_exposure.rs`), and `current_filter` starts a run as
            // `None` — so even a plan whose filter name is empty triggers the
            // change, and `execute_filter_change` reads `filterwheel_id()`
            // before it looks at the name at all.
            //
            // Reproduced against the Linux appliance on 2026-08-09 with the
            // sim camera/mount/focuser connected and NO wheel: a one-plan
            // SmartExposure with `filter_name: ""` answered
            // `POST /api/sequencer/start -> 200 {"status":"started"}` and then
            // logged `ERROR Change Filter failed: No filter wheel connected` /
            // `WARN [RECOVERY] Change Filter promoted device disconnect to
            // recovery`, five futile retries, run failed — the exact loop this
            // preflight exists to prevent.
            if !config.plans.is_empty() {
                require(RequiredDevice::FilterWheel, false);
            }
        }
        NodeType::FlatWizard(_) | NodeType::SciencePhotometry(_) => {
            require(RequiredDevice::Camera, true);
        }
        NodeType::CenterTarget(_) | NodeType::PolarAlignment(_) => {
            require(RequiredDevice::Camera, false);
            require(RequiredDevice::Mount, false);
        }
        NodeType::SlewToTarget(_)
        | NodeType::Park
        | NodeType::Unpark
        | NodeType::HomeMount
        | NodeType::MeridianFlip(_) => {
            require(RequiredDevice::Mount, false);
        }
        NodeType::Autofocus(config) => {
            require(RequiredDevice::Camera, false);
            require(RequiredDevice::Focuser, false);
            // An AF node pinned to a filter reads the wheel before it sweeps:
            // `execute_autofocus_admitted_with_pause` fails outright with
            // "Autofocus is configured to use filter \"…\", but no filter wheel
            // is connected". Reproduced on the Linux appliance on 2026-08-09
            // with camera + focuser connected and no wheel: `start` answered
            // 200 and the node then failed with exactly that line.
            //
            // `filter_settings` alone is NOT enough to require a wheel — with
            // no wheel that branch simply leaves the per-filter overrides
            // unapplied and the sweep still runs.
            if config
                .filter
                .as_deref()
                .is_some_and(|name| !name.trim().is_empty())
            {
                require(RequiredDevice::FilterWheel, false);
            }
        }
        NodeType::TemperatureCompensation(_) => {
            require(RequiredDevice::Focuser, false);
        }
        NodeType::CoolCamera(_) | NodeType::WarmCamera(_) => {
            require(RequiredDevice::Camera, false);
        }
        NodeType::ChangeFilter(_) => {
            require(RequiredDevice::FilterWheel, false);
        }
        NodeType::MoveRotator(_) => {
            require(RequiredDevice::Rotator, false);
        }
        _ => {}
    }

    for child in node.children() {
        collect_required_devices(&**child, out);
    }
}

/// Confirm every hardware role the sequence declares is actually assigned to
/// the run.
///
/// The device ids stay `None` until something calls `set_devices()`. When one
/// is missing the instruction that needs it fails with "No <device>
/// connected", the recovery classifier reads that as a device *disconnect*,
/// and the run then burns its whole recovery budget waiting for hardware that
/// was never configured. No amount of waiting can populate an id, so the retry
/// is futile by construction — refuse at Start instead.
///
/// Reproduced against the Linux appliance (release bundle, headless, no
/// devices connected). Each of these answers
/// `POST /api/sequencer/start -> 200 {"status":"started"}` and then dies
/// mid-run at `{"state":"failed","message":"Cancelled: Target"}`, with the
/// real reason visible only in the log:
///
/// ```text
/// ERROR Change Filter failed: No filter wheel connected
/// WARN  [RECOVERY] Change Filter promoted device disconnect to recovery: No filter wheel connected
/// ERROR Slew failed: No mount connected
/// ERROR Park failed: No mount connected
/// ERROR Cool Camera failed: No camera connected
/// ERROR Autofocus failed: No camera connected
/// ERROR Center Target failed: No mount connected
/// ERROR Move Rotator failed: No rotator connected
/// ```
///
/// Gating only `TakeExposure` refuses only `TakeExposure` up front.
pub(super) fn validate_required_devices(
    required: &std::collections::BTreeMap<RequiredDevice, DeviceRequirement>,
    assigned: impl Fn(RequiredDevice) -> Option<String>,
) -> Result<(), String> {
    let mut refusals = Vec::new();

    for (role, requirement) in required {
        if assigned(*role).is_some_and(|id| !id.trim().is_empty()) {
            continue;
        }
        refusals.push(device_refusal(*role, requirement));
    }

    if refusals.is_empty() {
        Ok(())
    } else {
        Err(refusals.join(" "))
    }
}

/// Name the missing thing, then the consequence in the operator's terms —
/// the shape of the save-path and plate-solver refusals this joins.
pub(super) fn device_refusal(role: RequiredDevice, requirement: &DeviceRequirement) -> String {
    let step = &requirement.node_name;
    match role {
        // The capture wording is kept verbatim: it is the refusal the live rig
        // produced on 2026-08-09 and the one the headless API's 400 envelope is
        // documented against.
        RequiredDevice::Camera if requirement.captures_frames => {
            "This sequence captures frames but no camera is assigned to the run. Connect a \
             camera and assign it before starting — every exposure would otherwise fail and \
             the run would sit in recovery waiting for a camera it was never given."
                .to_string()
        }
        RequiredDevice::Camera => format!(
            "This sequence runs \"{step}\", which needs a camera, but no camera is assigned to \
             the run. Connect a camera and assign it before starting — that step would \
             otherwise fail and the run would sit in recovery waiting for a camera it was \
             never given."
        ),
        RequiredDevice::Mount => format!(
            "This sequence moves the mount for \"{step}\" but no mount is assigned to the run. \
             Assign one to the active equipment profile before starting — every slew, park and \
             flip would otherwise fail and the run would sit in recovery waiting for a mount it \
             was never given."
        ),
        RequiredDevice::FilterWheel => format!(
            "This sequence changes filters for \"{step}\" but no filter wheel is assigned to the \
             run. Assign one to the active equipment profile before starting — every exposure \
             that requests a filter would otherwise fail and the run would sit in recovery \
             waiting for a wheel it was never given."
        ),
        RequiredDevice::Focuser => format!(
            "This sequence focuses for \"{step}\" but no focuser is assigned to the run. Assign \
             one to the active equipment profile before starting — that step would otherwise \
             fail and the run would sit in recovery waiting for a focuser it was never given."
        ),
        RequiredDevice::Rotator => format!(
            "This sequence rotates the camera for \"{step}\" but no rotator is assigned to the \
             run. Assign one to the active equipment profile before starting — that step would \
             otherwise fail and the run would sit in recovery waiting for a rotator it was \
             never given."
        ),
    }
}

/// Collect every instruction in the tree that the executor can never reach,
/// as `"<name>"` labels in tree order.
///
/// A node parented under a LEAF instruction is stored and drawn but never
/// executed: the leaf's instruction returns a status and the tree walk stops
/// there. Run 70 of the 6.0.0 sweep was exactly this — `Target → Unpark →
/// SlewToTarget → TakeExposure` nested one inside the next, so the executor
/// ran `Unpark`, returned Success, and reported the run `completed` with 0
/// frames and an empty `errorMessages` while the header still advertised
/// "3 frames".
pub(super) fn unreachable_instructions(node: &dyn Node, out: &mut Vec<String>) {
    let reachable_children = node.node_type().accepts_children();
    for child in node.children() {
        if reachable_children {
            unreachable_instructions(&**child, out);
        } else {
            collect_subtree_names(&**child, out);
        }
    }
}

pub(super) fn collect_subtree_names(node: &dyn Node, out: &mut Vec<String>) {
    out.push(node.name().to_string());
    for child in node.children() {
        collect_subtree_names(&**child, out);
    }
}

/// Operator-facing sentence naming the instructions a run could not reach.
pub(super) fn unreachable_instructions_message(names: &[String]) -> String {
    let count = names.len();
    let (plural, verb, pronoun, sit) = if count == 1 {
        ("", "is", "it", "it sits")
    } else {
        ("s", "are", "them", "they sit")
    };
    format!(
        "{count} instruction{plural} in this sequence {verb} attached to an instruction that \
         cannot hold children, so the executor never reaches {pronoun}: {}. Move {pronoun} so \
         {sit} beside that instruction rather than inside it.",
        names.join(", ")
    )
}

/// Confirm the run can actually keep the frames it is about to capture,
/// before the mount moves. A missing or unwritable save path discovered one
/// frame at a time reaches only the log: the burst "succeeds", the run reports
/// 100%, and nothing reaches disk.
pub(super) fn validate_capture_save_path(
    save_path: Option<&std::path::Path>,
) -> Result<(), String> {
    let Some(path) = save_path.filter(|p| !p.as_os_str().is_empty()) else {
        return Err(
            "This sequence captures frames but no image save path is configured. Set the \
             sequencer save path before starting — every frame would otherwise be captured \
             and discarded."
                .to_string(),
        );
    };

    if let Err(e) = std::fs::create_dir_all(path) {
        return Err(format!(
            "The image save path `{}` cannot be created: {e}. Choose a save path this machine \
             can write to before starting.",
            path.display()
        ));
    }

    let probe = path.join(format!(".skotiq-write-probe-{}", uuid::Uuid::new_v4()));
    if let Err(e) = std::fs::write(&probe, b"") {
        return Err(format!(
            "The image save path `{}` is not writable: {e}. Choose a save path this machine \
             can write to before starting.",
            path.display()
        ));
    }
    let _ = std::fs::remove_file(&probe);
    Ok(())
}
