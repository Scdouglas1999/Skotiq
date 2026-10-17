//! `gating.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

/// The default maximum Sun altitude (degrees above the horizon) at which an
/// on-sky LIGHT capture is permitted. `-12.0` mirrors the Dart scheduler's
/// `SchedulerConfig.maxSunAltitudeDegrees` default (nautical darkness), so the
/// structural native gate is never weaker than the Dart twilight gate it
/// backstops: a `0.0` default would open a twilight gap between -12° and 0°
/// where Dart rejects and the native gate allows, and the Sun in civil
/// twilight is far too bright for science LIGHT frames.
///
/// The Dart side can push a tighter or looser value at session start via
/// [`crate::executor::ExecutorCommand::UpdateMaxSunAltitude`] /
/// `SequenceExecutor::update_max_sun_altitude`; this constant is the floor
/// used when nothing was pushed, or when a non-finite value is seen.
pub const DEFAULT_MAX_SUN_ALTITUDE_DEGREES: f64 = -12.0;

/// W1 native daylight gate — recovery code stamped on a START rejection so the
/// UI / recovery layer can distinguish a daylight block from other slew/expose
/// failures.
pub const DAYLIGHT_GATE_RECOVERY_CODE: &str = "DAYLIGHT_GATE_SUN_UP";

/// Recovery code stamped when a node refuses to point at a target whose sky
/// position was never chosen, so the recovery layer can offer "set the target's
/// coordinates" instead of treating it as a mount fault.
pub const UNSET_TARGET_RECOVERY_CODE: &str = "TARGET_COORDINATES_UNSET";

/// Structural gate on pointing inherited from a `TargetHeader` that still
/// carries the palette placeholder. Returns `Some(reason)` to BLOCK.
///
/// `TargetHeaderConfig` has no nullable coordinate meaning "nothing picked
/// yet", so a target added from the palette starts at exactly RA 0h / Dec +0°.
/// Both values are in range and the pair is a real point in Pisces, so nothing
/// downstream can tell it apart from a deliberate pointing: the mount slews
/// there, and on an unattended remote rig it sits there for the rest of the
/// night.
///
/// Dart's `TargetCoordinatesUnsetRule` blocks this on the GUI start path, but
/// pre-flight validation is not the only way into a run — the headless
/// `POST /api/sequencer/start`, `sequencer_load_json` and every checkpoint
/// resume reach the executor without it, and a checkpoint written before that
/// rule existed resumes straight into the same slew. Gating the two nodes that
/// actually command the mount holds for all of those entry points at once.
///
/// The test is deliberately exact — `0.0` and nothing else — matching the Dart
/// rule so the two surfaces cannot disagree about which sequences are
/// runnable. An operator who genuinely wants that spot claims it with the
/// ten-thousandth-of-a-unit nudge the coordinate editor already exposes;
/// anything fuzzier would refuse legitimate pointings near the vernal equinox.
pub(crate) fn unset_target_pointing_reason(
    target_name: Option<&str>,
    ra_hours: f64,
    dec_degrees: f64,
    what: &str,
) -> Option<String> {
    if ra_hours != 0.0 || dec_degrees != 0.0 {
        return None;
    }
    let label = target_name
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .unwrap_or("this target");
    Some(format!(
        "Refusing {what}: target \"{label}\" is still at the RA 0h / Dec +0° placeholder, so \
         its sky position was never chosen. Set the target's coordinates before running this \
         sequence."
    ))
}

/// Whether a sequencer frame is an on-sky light that requires darkness.
///
/// Calibration frame types are intentionally explicit exemptions: they can be
/// captured during daylight even when they live below a TargetHeader and the
/// mount happens to be unparked.
pub(crate) fn frame_type_requires_darkness(frame_type: &str) -> bool {
    frame_type.eq_ignore_ascii_case("light")
}

/// W1 native daylight gate decision.
///
/// Structural START gate applied by `execute_slew` (when slewing to a
/// sky/science target) and `execute_exposure` (when capturing a LIGHT frame on
/// a science target). It enforces the W1 "no daylight imaging" invariant for
/// EVERY executor-run sequence — including a raw sequence started via
/// `api_sequencer_start` (e.g. a mosaic) — not just the autopilot path that
/// `scheduler_engine.dart` already gates. The same Sun-position math behind
/// `ExecutionContext::is_dark` is reused via
/// `crate::node::context::current_sun_altitude_degrees`.
///
/// Returns `Some(reason)` to BLOCK, `None` to allow. It is fail-closed only for
/// a genuine on-sky LIGHT capture: when the observer location is unknown the
/// gate ABSTAINS (returns `None`) rather than blocking, because without a
/// location the Sun altitude cannot be computed and blocking would break
/// location-less rigs doing legitimate work — the Dart W1 gate remains the
/// belt-and-suspenders for the autopilot path. Flats/darks/bias/park and a
/// parked rig never reach this function (their callers pass nothing that looks
/// like an on-sky LIGHT capture), so daytime calibration / testing is
/// unaffected.
pub(crate) fn daylight_gate_block_reason(
    latitude: Option<f64>,
    longitude: Option<f64>,
    max_sun_altitude_degrees: f64,
    what: &str,
) -> Option<String> {
    // (0, 0) is the shape an unset site arrives in, not a site in the Gulf of
    // Guinea: quoting a Greenwich Sun altitude refused every light frame of an
    // Australian night and blamed the Sun for a missing setting.
    let (latitude, longitude) =
        crate::node::context::normalized_observer_location(latitude, longitude);
    let (lat, lon) = match (latitude, longitude) {
        (Some(lat), Some(lon)) => (lat, lon),
        _ => {
            // No location => cannot compute Sun altitude. Abstain (the Dart W1
            // gate still protects the autopilot path); never fabricate a block
            // that would wedge a location-less rig.
            tracing::warn!(
                "Daylight gate cannot protect {what}: no observing site is set, so the \
                 Sun's altitude is unknown. Set your latitude and longitude in Settings."
            );
            return None;
        }
    };

    let sun_alt = crate::node::context::current_sun_altitude_degrees(lat, lon);
    let max_alt = if max_sun_altitude_degrees.is_finite() {
        max_sun_altitude_degrees
    } else {
        DEFAULT_MAX_SUN_ALTITUDE_DEGREES
    };

    if sun_alt > max_alt {
        Some(format!(
            "Daylight gate: refusing {what} — Sun altitude {sun_alt:.1}° is above the \
             maximum {max_alt:.1}° for on-sky light imaging. Daytime flats/darks/bias and \
             a parked rig are unaffected; this blocks only on-sky science captures."
        ))
    } else {
        None
    }
}

/// W1 native daylight gate — resolve the effective maximum Sun altitude for a
/// running sequence. Reads the executor-seeded value from the shared trigger
/// state (mirrors `RuntimeConfig::max_sun_altitude_degrees`), falling back to
/// [`DEFAULT_MAX_SUN_ALTITUDE_DEGREES`] when no trigger state is wired (one-shot
/// instruction sites / tests) or the value has not been seeded.
pub(crate) async fn resolve_max_sun_altitude(ctx: &InstructionContext) -> f64 {
    if let Some(lock) = &ctx.trigger_state {
        if let Some(v) = lock.read().await.max_sun_altitude_degrees {
            return v;
        }
    }
    DEFAULT_MAX_SUN_ALTITUDE_DEGREES
}

pub(crate) fn validate_exposure_filter_request(
    filter: Option<&str>,
    filter_index: Option<i32>,
    filterwheel_id: Option<&str>,
) -> Result<(), String> {
    let filter = filter.map(str::trim).filter(|name| !name.is_empty());
    if filterwheel_id.is_some() || (filter.is_none() && filter_index.is_none()) {
        return Ok(());
    }

    let requested = match (filter, filter_index) {
        (Some(name), Some(index)) => format!("\"{}\" at position {}", name, index),
        (Some(name), None) => format!("\"{}\"", name),
        (None, Some(index)) => format!("position {}", index),
        (None, None) => unreachable!("no filter request was already handled"),
    };
    Err(format!(
        "Cannot capture with requested filter {} because no filter wheel is connected",
        requested
    ))
}

/// Ask the wheel which filter it is ACTUALLY sitting on.
///
/// The sequence context only ever learns a filter name when something inside
/// the running sequence sets one — a Change Filter node, a Smart Exposure
/// plan, or the burst's own `filter`. A run that simply captures with the
/// wheel left where the operator parked it therefore carried NO filter
/// identity at all: the save-path template rendered the synthetic `nofilter`
/// label and `FrameContext.filter_name` stayed `None`, so the saved FITS had
/// no FILTER card even though the wheel would answer the question at any
/// moment. Every calibration workflow (PixInsight / Siril / APP) keys off
/// FILTER, so those lights could not be matched to flats without hand-editing
/// the headers.
///
/// Returns `None` — never a guessed label — when there is no wheel, when the
/// wheel is still moving (drivers report a negative position while in
/// transit), when the names cannot be read, or when the occupied slot has no
/// configured name. An unknown filter must stay unknown; inventing "L" would
/// mis-label narrowband frames as luminance.
pub(crate) async fn observed_wheel_filter(ctx: &InstructionContext) -> Option<(String, i32)> {
    let fw_id = ctx.filterwheel_id.as_deref()?;
    let position = match ctx.device_ops.filterwheel_get_position(fw_id).await {
        Ok(position) if position >= 0 => position,
        Ok(position) => {
            tracing::debug!(
                "[CAPTURE] filter wheel reports in-transit position {}; frame filter left unknown",
                position
            );
            return None;
        }
        Err(e) => {
            tracing::debug!(
                "[CAPTURE] filterwheel_get_position failed; frame filter left unknown: {}",
                e
            );
            return None;
        }
    };
    let name = wheel_filter_name_at(ctx, position).await?;
    Some((name, position))
}

/// Name of the filter installed in wheel slot `position`, or `None` when the
/// wheel cannot be asked or the slot is unnamed. Companion to
/// [`observed_wheel_filter`] for the case where the slot is already known
/// (a burst that addresses the wheel by index).
pub(crate) async fn wheel_filter_name_at(
    ctx: &InstructionContext,
    position: i32,
) -> Option<String> {
    let fw_id = ctx.filterwheel_id.as_deref()?;
    if position < 0 {
        return None;
    }
    let names = match ctx.device_ops.filterwheel_get_names(fw_id).await {
        Ok(names) => names,
        Err(e) => {
            tracing::debug!(
                "[CAPTURE] filterwheel_get_names failed; frame filter left unknown: {}",
                e
            );
            return None;
        }
    };
    let name = names.get(position as usize)?.trim().to_string();
    if name.is_empty() {
        tracing::debug!(
            "[CAPTURE] filter wheel slot {} has no configured name; frame filter left unknown",
            position
        );
        return None;
    }
    Some(name)
}

/// Wheel slot occupied by the filter called `name`, or `None` when there is no
/// wheel, it cannot be asked, or nothing in it goes by that name.
///
/// Inverse of [`wheel_filter_name_at`]. A burst that addresses the wheel BY
/// NAME never learns the slot it landed on, so without this the frame carried a
/// correct `filter_name` next to whatever `filter_index` an earlier burst had
/// left behind — one frame described by two filters, which is the same
/// disagreement the name resolution was added to end.
pub(crate) async fn wheel_filter_index_of(ctx: &InstructionContext, name: &str) -> Option<i32> {
    let fw_id = ctx.filterwheel_id.as_deref()?;
    let wanted = name.trim();
    if wanted.is_empty() {
        return None;
    }
    let names = match ctx.device_ops.filterwheel_get_names(fw_id).await {
        Ok(names) => names,
        Err(e) => {
            tracing::debug!(
                "[CAPTURE] filterwheel_get_names failed; frame filter position left unknown: {}",
                e
            );
            return None;
        }
    };
    let position = names
        .iter()
        .position(|slot| slot.trim().eq_ignore_ascii_case(wanted))?;
    i32::try_from(position).ok()
}

/// Outcome of [`resolve_burst_filter`].
pub(crate) enum BurstFilter {
    /// This burst addresses the wheel itself, so BOTH fields describe every
    /// frame in it — including when one of them is `None`. Overwriting the pair
    /// as a unit is what stops a slot number left behind by an earlier burst
    /// from being filed next to this burst's filter name.
    Resolved {
        name: Option<String>,
        index: Option<i32>,
    },
    /// Nothing in this burst addresses the wheel. Whatever a preceding Change
    /// Filter / Smart Exposure established still describes these frames.
    Inherit,
}

/// Decide the filter identity that this burst's frames should be recorded
/// under.
///
/// Precedence, strongest evidence first:
///  1. the burst's own `filter` — `execute_exposure` is about to drive the
///     wheel there, so it is what these frames are taken through. Dropping
///     this case is silent: `${filter}` in the save-path template reads
///     `current_filter`, never `config.filter`, so even a node with "Ha"
///     configured writes `..._nofilter_....fits`;
///  2. the burst's `filter_index` resolved against the wheel's name table,
///     for nodes that address the wheel by position only;
///  3. whatever a preceding Change Filter / Smart Exposure already
///     established — already correct, leave it alone;
///  4. the wheel's own report of where it is parked, for the common case of a
///     sequence that never changes filter at all.
///
/// Cases 1 and 2 each know only half of the identity, so the other half is
/// looked up on the wheel: a name-addressed burst asks which slot it landed in,
/// a position-addressed burst asks what lives in that slot. A `None` that
/// survives the lookup is honest ignorance and is recorded as such — see
/// [`observed_wheel_filter`].
///
/// Lives here rather than in the TakeExposure node because the node is not the
/// only capture path: the Flat Wizard and every bridge one-shot call
/// [`execute_exposure`] directly, and they need the same answer.
pub(crate) async fn resolve_burst_filter(
    config: &ExposureConfig,
    ctx: &InstructionContext,
) -> BurstFilter {
    let configured_name = config
        .filter
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_string);

    match (configured_name, config.filter_index) {
        (Some(name), Some(index)) => BurstFilter::Resolved {
            name: Some(name),
            index: Some(index),
        },
        (Some(name), None) => {
            let index = wheel_filter_index_of(ctx, &name).await;
            BurstFilter::Resolved {
                name: Some(name),
                index,
            }
        }
        // Position-addressed burst: the wheel's own name table is the only
        // thing that knows what sits in that slot.
        (None, Some(index)) => BurstFilter::Resolved {
            name: wheel_filter_name_at(ctx, index).await,
            index: Some(index),
        },
        (None, None) => {
            // Already established by a preceding Change Filter / Smart Exposure.
            if ctx.current_filter.is_some() {
                return BurstFilter::Inherit;
            }
            match observed_wheel_filter(ctx).await {
                Some((name, index)) => BurstFilter::Resolved {
                    name: Some(name),
                    index: Some(index),
                },
                None => BurstFilter::Inherit,
            }
        }
    }
}

/// The filter identity to stamp on the frames of this burst, as one
/// (name, slot) pair.
///
/// [`resolve_burst_filter`] flattened against the running context, for the two
/// consumers that record a frame rather than update the context: the
/// renderer-less filename fallback and `build_frame_context_for_save` (FITS
/// FILTER card + the `captured_images` row). Reading `config.filter` and
/// `config.filter_index` independently files a burst that names "Ha" but
/// carries no index under "Ha" next to whatever slot a previous burst left in
/// the context — one frame described by two different filters. Resolving the
/// pair as a unit here makes the filename, the FITS header and the database
/// row agree by construction.
pub(crate) async fn resolve_frame_filter(
    config: &ExposureConfig,
    ctx: &InstructionContext,
) -> (Option<String>, Option<i32>) {
    match resolve_burst_filter(config, ctx).await {
        BurstFilter::Resolved { name, index } => (name, index),
        // A slot number with no name behind it cannot describe a frame: it is
        // an artefact of an earlier burst, not evidence about this one.
        BurstFilter::Inherit if ctx.current_filter.is_some() => {
            (ctx.current_filter.clone(), ctx.current_filter_index)
        }
        BurstFilter::Inherit => (None, None),
    }
}
