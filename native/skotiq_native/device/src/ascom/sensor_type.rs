//! ASCOM `SensorType` → Bayer element order.
//!
//! ASCOM ICameraV3 defines `SensorType` as 0 Monochrome, 1 Color, 2 RGGB,
//! 3 CMYG, 4 CMYG2, 5 LRGB. The ordinal names the colour-filter *family*, never
//! the element order: every RGGB-family mosaic reports 2, and which corner of
//! the 2×2 block holds red is carried only by `BayerOffsetX`/`BayerOffsetY`.
//! Type 1 is a direct-colour sensor with no Bayer mask, so its offsets name
//! nothing; types 3..=5 are mosaics with no RGGB-style order to name.
//!
//! Deriving a pattern from the family ordinal alone transposes red and blue on
//! a BGGR or GRBG sensor and writes the wrong `BAYERPAT` into the FITS header,
//! and neither is recoverable from the saved frame. `None` therefore means "the
//! pattern is unknown", which leaves the frame undebayered and the `BAYERPAT`
//! card unwritten rather than debayered wrongly.
//!
//! Both ASCOM transports carry this same enum, so the mapping lives here,
//! compiled and tested on every platform.

use skotiq_cfa::BayerPattern;
use std::collections::HashSet;
use std::sync::{Mutex, OnceLock};

/// The `SensorType` ordinal for an RGGB-family colour-filter array, the one
/// family whose element order [`BayerPattern`] can name.
pub const SENSOR_TYPE_RGGB: i32 = 2;

/// True when `SensorType` names an RGGB-family mosaic, so `BayerOffsetX` and
/// `BayerOffsetY` are worth the two property reads.
///
/// Monochrome (0) and direct-colour (1) sensors carry no Bayer mask, the CMYG
/// (3), CMYG2 (4) and LRGB (5) mosaics have no RGGB-style order, and an
/// unreadable `SensorType` names nothing at all — the offsets are skipped for
/// every one of them.
pub fn has_nameable_bayer_order(sensor_type: i32) -> bool {
    sensor_type == SENSOR_TYPE_RGGB
}

/// True when `SensorType` names one of the colour families (1..=5).
///
/// Colour and Bayer order are independent answers: a direct-colour sensor
/// (type 1) is colour with no Bayer mask, and the CMYG/CMYG2/LRGB mosaics are
/// colour with no RGGB-style order. An ordinal outside the enum names no
/// family, so it reads monochrome — debayering a mono frame is a no-op, while
/// treating a frame as colour on a guess is not.
pub fn is_colour_sensor(sensor_type: i32) -> bool {
    (1..=5).contains(&sensor_type)
}

/// The operator-facing reason a colour frame will NOT be debayered, or `None`
/// when the sensor is monochrome, outside the enum, or carries a nameable order.
///
/// A colour sensor with no RGGB-style order — `SensorType` 1 (direct colour) or
/// the 3..=5 CMYG/CMYG2/LRGB mosaics — is left undebayered and writes no
/// `BAYERPAT` card. That is correct for those families, but once the OSC gate
/// moved from `SensorType == 1` to `== 2` a Bayer one-shot-colour camera whose
/// driver MISREPORTS its `SensorType` as 1 loses its debayering and its
/// `BAYERPAT` card silently. Naming the reason lets that misreport be
/// recognised from the app rather than hunted, and keeps the copy in one place
/// across the Windows COM worker and the Alpaca download path.
pub fn debayer_skip_reason(sensor_type: i32) -> Option<String> {
    if is_colour_sensor(sensor_type) && !has_nameable_bayer_order(sensor_type) {
        Some(format!(
            "colour sensor (SensorType={sensor_type}) with no nameable Bayer order: the \
             frame is left undebayered and carries no BAYERPAT card. If this is a Bayer \
             one-shot-colour camera, its driver is misreporting SensorType — set it to 2 \
             (RGGB) so the BayerOffsetX/Y pair can name the element order."
        ))
    } else {
        None
    }
}

/// The (device, `SensorType`) pairs whose skipped debayer has already been
/// reported this session — see [`warn_debayer_skip_once`].
static REPORTED_DEBAYER_SKIPS: OnceLock<Mutex<HashSet<(String, i32)>>> = OnceLock::new();

/// [`debayer_skip_reason`], but only the FIRST time this (device, `SensorType`)
/// pair asks.
///
/// The download path runs once per exposure, and a CMYG or direct-colour camera
/// is *correctly* left undebayered on every one of them — repeating the reason
/// per frame would bury it in its own noise, and a misreporting driver's
/// reading is the one that has to be readable. The seen-set is passed in so the
/// latch is a value the tests can own; [`warn_debayer_skip_once`] holds the
/// process-wide one.
pub fn take_debayer_skip_reason(
    seen: &mut HashSet<(String, i32)>,
    device_id: &str,
    sensor_type: i32,
) -> Option<String> {
    let reason = debayer_skip_reason(sensor_type)?;
    seen.insert((device_id.to_string(), sensor_type))
        .then_some(reason)
}

/// Log the skipped debayer once per (device, `SensorType`), at WARN.
///
/// Called from the frame-download path, so the operator learns from the app's
/// own log why a colour frame arrived undebayered with no `BAYERPAT` card,
/// instead of finding it in the pixels. A `SensorType` that CHANGES — the
/// driver corrected, or a different camera on the same id — is a new pair and
/// is reported again.
pub fn warn_debayer_skip_once(device_id: &str, sensor_type: i32) {
    let seen = REPORTED_DEBAYER_SKIPS.get_or_init(|| Mutex::new(HashSet::new()));
    // A panic inside an unrelated caller must not silence this warning for the
    // rest of the session; the set's contents are still valid either way.
    let mut guard = match seen.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    if let Some(reason) = take_debayer_skip_reason(&mut guard, device_id, sensor_type) {
        tracing::warn!("Camera {} reports a {}", device_id, reason);
    }
}

/// Derive the Bayer element order from `SensorType` plus the
/// `BayerOffsetX`/`BayerOffsetY` pair.
///
/// The result is `None` whenever the offsets do not pin an order down: the
/// sensor family has none to name, an offset is unreadable (`None`), or the
/// pair falls outside the 2×2 block.
pub fn bayer_pattern_from_sensor(
    sensor_type: i32,
    offset_x: Option<i32>,
    offset_y: Option<i32>,
) -> Option<BayerPattern> {
    if !has_nameable_bayer_order(sensor_type) {
        return None;
    }
    match (offset_x, offset_y) {
        (Some(0), Some(0)) => Some(BayerPattern::Rggb),
        (Some(1), Some(0)) => Some(BayerPattern::Grbg),
        (Some(0), Some(1)) => Some(BayerPattern::Gbrg),
        (Some(1), Some(1)) => Some(BayerPattern::Bggr),
        (x, y) => {
            tracing::warn!(
                "ASCOM camera reports SensorType={} with unusable Bayer offsets \
                 (x: {:?}, y: {:?}); leaving the Bayer pattern unknown rather than \
                 guessing an element order",
                sensor_type,
                x,
                y
            );
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The offset pair, not the `SensorType` ordinal, names the element order:
    /// all four corners are reachable from the one RGGB-family ordinal.
    #[test]
    fn rggb_family_reads_the_order_out_of_the_offsets() {
        assert_eq!(
            bayer_pattern_from_sensor(2, Some(0), Some(0)),
            Some(BayerPattern::Rggb)
        );
        assert_eq!(
            bayer_pattern_from_sensor(2, Some(1), Some(0)),
            Some(BayerPattern::Grbg)
        );
        assert_eq!(
            bayer_pattern_from_sensor(2, Some(0), Some(1)),
            Some(BayerPattern::Gbrg)
        );
        assert_eq!(
            bayer_pattern_from_sensor(2, Some(1), Some(1)),
            Some(BayerPattern::Bggr)
        );
    }

    /// A BGGR sensor is never reported as RGGB: that transposes red and blue in
    /// every debayered frame and stamps the wrong `BAYERPAT`.
    #[test]
    fn rggb_family_does_not_assume_rggb() {
        assert_eq!(
            bayer_pattern_from_sensor(2, Some(1), Some(1)),
            Some(BayerPattern::Bggr),
            "the offset pair, not the SensorType ordinal, names the element order"
        );
    }

    /// SensorType 1 is a direct-colour sensor with no Bayer mask: it is colour,
    /// its offsets are meaningless, and no `BAYERPAT` card is produced.
    #[test]
    fn direct_colour_sensor_is_colour_without_a_pattern() {
        assert!(is_colour_sensor(1));
        assert!(!has_nameable_bayer_order(1));
        assert_eq!(bayer_pattern_from_sensor(1, Some(0), Some(0)), None);
        assert_eq!(bayer_pattern_from_sensor(1, Some(1), Some(1)), None);
        assert_eq!(bayer_pattern_from_sensor(1, None, None), None);
    }

    /// Monochrome is neither colour nor masked.
    #[test]
    fn monochrome_sensor_has_no_pattern() {
        assert!(!is_colour_sensor(0));
        assert!(!has_nameable_bayer_order(0));
        assert_eq!(bayer_pattern_from_sensor(0, Some(0), Some(0)), None);
    }

    /// CMYG (3), CMYG2 (4) and LRGB (5) are colour and do carry offsets, but
    /// they index a mosaic [`BayerPattern`] cannot name, so the pattern stays
    /// unknown.
    #[test]
    fn non_rggb_mosaics_have_no_nameable_order() {
        for sensor_type in [3, 4, 5] {
            assert!(is_colour_sensor(sensor_type));
            assert!(
                !has_nameable_bayer_order(sensor_type),
                "SensorType={sensor_type} has no RGGB-style order to name"
            );
            for (x, y) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                assert_eq!(
                    bayer_pattern_from_sensor(sensor_type, Some(x), Some(y)),
                    None,
                    "SensorType={sensor_type} offsets ({x}, {y}) named an RGGB pattern"
                );
            }
        }
    }

    /// An unreadable offset leaves the pattern unknown instead of defaulting to
    /// the (0, 0) corner.
    #[test]
    fn unreadable_offsets_leave_the_pattern_unknown() {
        assert_eq!(bayer_pattern_from_sensor(2, None, Some(0)), None);
        assert_eq!(bayer_pattern_from_sensor(2, Some(0), None), None);
        assert_eq!(bayer_pattern_from_sensor(2, None, None), None);
    }

    /// An offset pair outside the 2×2 block is unknown, not RGGB.
    #[test]
    fn out_of_range_offsets_leave_the_pattern_unknown() {
        assert_eq!(bayer_pattern_from_sensor(2, Some(2), Some(0)), None);
        assert_eq!(bayer_pattern_from_sensor(2, Some(-1), Some(1)), None);
        assert_eq!(bayer_pattern_from_sensor(2, Some(0), Some(7)), None);
    }

    /// An ordinal outside the enum names no family, so the frame is neither
    /// claimed colour nor debayered.
    #[test]
    fn out_of_enum_sensor_type_is_mono_without_a_pattern() {
        for sensor_type in [-1, 6, 99] {
            assert!(
                !is_colour_sensor(sensor_type),
                "SensorType={sensor_type} is outside the enum and names no family"
            );
            assert!(!has_nameable_bayer_order(sensor_type));
            assert_eq!(
                bayer_pattern_from_sensor(sensor_type, Some(0), Some(0)),
                None
            );
        }
    }

    /// A colour sensor with no nameable order carries a reason the operator can
    /// read — direct colour (1) and the CMYG/CMYG2/LRGB mosaics (3..=5) — and
    /// that reason names the SensorType so a misreport can be recognised.
    #[test]
    fn colour_without_a_nameable_order_carries_a_reason() {
        for sensor_type in [1, 3, 4, 5] {
            let reason = debayer_skip_reason(sensor_type)
                .unwrap_or_else(|| panic!("SensorType={sensor_type} named no reason"));
            assert!(
                reason.contains(&format!("SensorType={sensor_type}")),
                "the reason must name the SensorType it saw: {reason}"
            );
            assert!(
                reason.contains("BAYERPAT"),
                "the reason must state that no BAYERPAT card is written: {reason}"
            );
        }
    }

    /// The download path asks once per exposure. The reason is given the first
    /// time a (device, SensorType) pair asks and withheld afterwards, so a
    /// legitimately undebayerable camera does not repeat it every frame — while
    /// a SECOND camera, and the same camera reporting a DIFFERENT SensorType,
    /// are each new pairs that are reported.
    #[test]
    fn the_reason_is_given_once_per_device_and_sensor_type() {
        let mut seen = HashSet::new();
        assert!(
            take_debayer_skip_reason(&mut seen, "alpaca:cam-1", 1).is_some(),
            "the first frame off this camera must name the reason"
        );
        for frame in 0..10 {
            assert_eq!(
                take_debayer_skip_reason(&mut seen, "alpaca:cam-1", 1),
                None,
                "frame {frame} repeated a reason already given"
            );
        }
        assert!(
            take_debayer_skip_reason(&mut seen, "alpaca:cam-2", 1).is_some(),
            "a different camera is a different reading"
        );
        assert!(
            take_debayer_skip_reason(&mut seen, "alpaca:cam-1", 3).is_some(),
            "the same camera reporting a different SensorType is a new reading"
        );
    }

    /// The latch never invents a reason: a nameable-order or non-colour sensor
    /// stays silent however many times it is asked, and leaves the seen-set
    /// empty so it cannot crowd out a camera that does have something to say.
    #[test]
    fn the_latch_stays_silent_for_a_sensor_with_nothing_to_report() {
        let mut seen = HashSet::new();
        for sensor_type in [0, 2, -1, 99] {
            assert_eq!(
                take_debayer_skip_reason(&mut seen, "alpaca:cam-1", sensor_type),
                None,
                "SensorType={sensor_type} has no skipped debayer to report"
            );
        }
        assert!(
            seen.is_empty(),
            "nothing was reported, so nothing is latched"
        );
    }

    /// An RGGB-family sensor (2) HAS a nameable order, monochrome (0) and
    /// out-of-enum ordinals are not colour: none of them is a skipped-debayer
    /// reason, so none raises the warning.
    #[test]
    fn a_nameable_or_non_colour_sensor_carries_no_reason() {
        assert_eq!(debayer_skip_reason(2), None, "RGGB has a nameable order");
        assert_eq!(debayer_skip_reason(0), None, "monochrome is not colour");
        for sensor_type in [-1, 6, 99] {
            assert_eq!(
                debayer_skip_reason(sensor_type),
                None,
                "SensorType={sensor_type} is outside the enum and names no family"
            );
        }
    }

    /// The FITS spelling round-trips: every pattern the mapping produces has a
    /// `BAYERPAT` name, and that name maps back to the same pattern.
    #[test]
    fn fits_names_round_trip() {
        for (x, y) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            let pattern =
                bayer_pattern_from_sensor(2, Some(x), Some(y)).expect("offsets name a pattern");
            let cfa = skotiq_cfa::ColorFilterArray::from(pattern);
            let name = cfa.letters();
            let back = skotiq_cfa::ColorFilterArray::parse(&name).unwrap_or_else(|| {
                panic!("offsets ({x}, {y}) produced unmappable BAYERPAT {name}")
            });
            assert_eq!(back, cfa);
        }
    }
}
