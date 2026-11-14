//! Keeping on-sky captures off the filter wheel's dark slot.
//!
//! The end-of-night calibration takes its darks through a wheel slot that
//! blocks light, and a run that is stopped or fails can leave the wheel there.
//! A step that captures the sky without a filter of its own (Center, the
//! recenter paths that reuse it, autofocus) would then shoot through that
//! slot: on 2026-11-03 every centering solve failed through "DARK" and the
//! run went on uncentered. Before such a capture the wheel is moved to a
//! light filter.

use super::*;
use crate::node::runtime::Node;

/// A light filter a target's exposures use, in the order they use it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlannedLightFilter {
    pub name: Option<String>,
    /// Zero-based wheel position, when the plan gives one.
    pub index: Option<i32>,
}

/// Whether a wheel slot of this name blocks light: `Dark`, `Darks`, `Blank`,
/// `Opaque`, `Closed`, `Shutter`, `Cap` or `Blocked`, in any case.
///
/// The same names the app's end-of-night calibration picks its dark slot by
/// (`findDarkSlot` in `eon_plan.dart`); keep the two lists equal.
pub fn is_dark_slot_name(name: &str) -> bool {
    matches!(
        name.trim().to_ascii_lowercase().as_str(),
        "dark" | "darks" | "blank" | "opaque" | "closed" | "shutter" | "cap" | "blocked"
    )
}

/// The light filters the light exposures under `node` use, first use first:
/// light TakeExposure nodes, SmartExposure plans and filter changes. Disabled
/// nodes and dark-slot names are left out.
pub(crate) fn planned_light_filters(node: &dyn Node) -> Vec<PlannedLightFilter> {
    let mut out = Vec::new();
    collect_planned_light_filters(node, &mut out);
    out
}

fn collect_planned_light_filters(node: &dyn Node, out: &mut Vec<PlannedLightFilter>) {
    if !node.is_enabled() {
        return;
    }
    let mut push = |name: Option<&str>, index: Option<i32>| {
        let name = name.map(str::trim).filter(|n| !n.is_empty());
        if name.is_none() && index.is_none() {
            return;
        }
        if name.is_some_and(is_dark_slot_name) {
            return;
        }
        let planned = PlannedLightFilter {
            name: name.map(str::to_string),
            index,
        };
        if !out.contains(&planned) {
            out.push(planned);
        }
    };
    match node.node_type() {
        NodeType::TakeExposure(cfg) if cfg.frame_type.is_science() => {
            push(cfg.filter.as_deref(), cfg.filter_index);
        }
        NodeType::SmartExposure(cfg) => {
            for plan in &cfg.plans {
                push(Some(plan.filter_name.as_str()), plan.filter_index);
            }
        }
        NodeType::ChangeFilter(cfg) => push(Some(cfg.filter_name.as_str()), cfg.filter_index),
        _ => {}
    }
    for child in node.children() {
        collect_planned_light_filters(child.as_ref(), out);
    }
}

/// The slot to capture through instead of a dark slot: the first planned
/// light filter the wheel has, else the wheel's first slot that is not dark.
pub fn choose_light_slot(
    names: &[String],
    planned: &[PlannedLightFilter],
) -> Option<(i32, String)> {
    let usable = |index: usize| {
        names
            .get(index)
            .filter(|name| !name.trim().is_empty() && !is_dark_slot_name(name))
            .map(|name| (index as i32, name.clone()))
    };
    for filter in planned {
        let by_index = filter
            .index
            .and_then(|i| usize::try_from(i).ok())
            .and_then(usable);
        let by_name = || {
            let wanted = filter.name.as_deref()?.trim();
            names
                .iter()
                .position(|name| name.trim().eq_ignore_ascii_case(wanted))
                .and_then(usable)
        };
        if let Some(slot) = by_index.or_else(by_name) {
            return Some(slot);
        }
    }
    (0..names.len()).find_map(usable)
}

/// Move the wheel to `slot` for a capture and apply that filter's focus
/// offset. A focus-offset failure is logged, not fatal: the capture is for a
/// solve or a focus run, not for science.
async fn move_for_capture(
    ctx: &InstructionContext,
    fw_id: &str,
    slot: &(i32, String),
) -> Result<(), DeviceFailure> {
    move_filter_wheel(
        ctx,
        fw_id,
        WheelTarget::Position(slot.0),
        Some(Duration::from_secs(DEFAULT_FILTER_WHEEL_TIMEOUT_SECS)),
    )
    .await?;
    if let Err(error) = apply_filter_focus_offset(&slot.1, ctx, None).await {
        tracing::warn!(
            "Focus offset for filter \"{}\" was not applied: {}",
            slot.1,
            error
        );
    }
    Ok(())
}

/// Before `step` captures the sky through whatever filter is loaded: when that
/// is the dark slot, move to the target's first light filter (else the first
/// slot that is not dark) and say so. Returns what was done, or `None` when
/// nothing needed to move. With no wheel, or a wheel that cannot be read,
/// nothing moves; the capture goes ahead as it always did.
pub(crate) async fn leave_dark_slot_for_capture(
    ctx: &InstructionContext,
    step: &str,
) -> Result<Option<String>, InstructionResult> {
    let Some(fw_id) = ctx
        .run
        .rig
        .filterwheel_id
        .as_deref()
        .filter(|id| !id.is_empty())
    else {
        return Ok(None);
    };
    let position = match ctx.run.device_ops.filterwheel_get_position(fw_id).await {
        Ok(position) if position >= 0 => position,
        Ok(_) => return Ok(None),
        Err(error) => {
            tracing::warn!("{step}: could not read the filter wheel position: {error}");
            return Ok(None);
        }
    };
    let names = match ctx.run.device_ops.filterwheel_get_names(fw_id).await {
        Ok(names) => names,
        Err(error) => {
            tracing::warn!("{step}: could not read the filter names: {error}");
            return Ok(None);
        }
    };
    let Some(current) = names.get(position as usize) else {
        return Ok(None);
    };
    if !is_dark_slot_name(current) {
        return Ok(None);
    }
    let Some(slot) = choose_light_slot(&names, &ctx.target_light_filters) else {
        return Err(InstructionResult::failure(format!(
            "{step} cannot capture: the filter wheel is on the dark slot \"{current}\" and has no \
             other slot to use"
        )));
    };
    if let Err(error) = move_for_capture(ctx, fw_id, &slot).await {
        return Err(ctx.check_cancelled().unwrap_or_else(|| {
            InstructionResult::failure(format!(
                "{step} cannot capture: the filter wheel is on the dark slot \"{current}\" and \
                 moving it to \"{}\" failed: {error}",
                slot.1
            ))
            .caused_by(&error.error)
        }));
    }
    let message = format!(
        "{step}: the filter wheel was on the dark slot \"{current}\" (position {}); moved it to \
         \"{}\" (position {}) to capture through",
        position + 1,
        slot.1,
        slot.0 + 1
    );
    tracing::warn!("{message}");
    Ok(Some(message))
}

/// Move the wheel to the filter a step names for its own captures, matched by
/// name in any case. A name the wheel does not have is logged and ignored, so
/// the dark-slot check still runs.
pub(crate) async fn select_step_filter(
    ctx: &InstructionContext,
    step: &str,
    filter: Option<&str>,
) -> Result<Option<String>, InstructionResult> {
    let Some(wanted) = filter.map(str::trim).filter(|name| !name.is_empty()) else {
        return leave_dark_slot_for_capture(ctx, step).await;
    };
    let Some(fw_id) = ctx
        .run
        .rig
        .filterwheel_id
        .as_deref()
        .filter(|id| !id.is_empty())
    else {
        tracing::warn!("{step} names filter \"{wanted}\", but no filter wheel is connected");
        return Ok(None);
    };
    let names = match ctx.run.device_ops.filterwheel_get_names(fw_id).await {
        Ok(names) => names,
        Err(error) => {
            tracing::warn!("{step}: could not read the filter names: {error}");
            return leave_dark_slot_for_capture(ctx, step).await;
        }
    };
    let Some(index) = names
        .iter()
        .position(|name| name.trim().eq_ignore_ascii_case(wanted))
    else {
        tracing::warn!("{step} names filter \"{wanted}\", which the filter wheel does not have");
        return leave_dark_slot_for_capture(ctx, step).await;
    };
    if ctx
        .run
        .device_ops
        .filterwheel_get_position(fw_id)
        .await
        .ok()
        == Some(index as i32)
    {
        return Ok(None);
    }
    let slot = (index as i32, names[index].clone());
    if let Err(error) = move_for_capture(ctx, fw_id, &slot).await {
        return Err(ctx.check_cancelled().unwrap_or_else(|| {
            InstructionResult::failure(format!(
                "{step} could not move to filter \"{}\": {error}",
                slot.1
            ))
            .caused_by(&error.error)
        }));
    }
    let message = format!("{step}: moved the filter wheel to \"{}\"", slot.1);
    tracing::info!("{message}");
    Ok(Some(message))
}
