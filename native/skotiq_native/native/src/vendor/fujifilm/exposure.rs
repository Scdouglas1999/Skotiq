//! How a requested exposure and ISO become the settings a Fujifilm body is
//! given, and how a frame waiting in its buffer is recognized. Pure rules, so
//! they are tested on every platform; the SDK calls that use them are in
//! `camera_ops.rs` (Windows only).

use std::time::Duration;

/// `XSDK_SHUTTER_BULB` (XAPI.h).
pub(crate) const BULB_CODE: i32 = -1;

/// The timed shutter codes XAPI.h defines (`XSDK_SHUTTER_*`). A code is the
/// exposure in microseconds: the header names 64000000 "60" and 60000000
/// "60S", 32000000 "30" and 40000000 "40S", so the plain names are rounded
/// labels of binary-stepped times and only the code says how long the shutter
/// is open. The T-mode codes (64000030 + 30 per step) are the exception: they
/// name whole minutes. The 1/8192-style codes at 1000000000 + n are flicker
/// settings, not exposure times, and are not listed.
const TIMED_CODES: &[i32] = &[
    5, 6, 7, 9, 12, 15, 19, 24, 30, 38, 43, 48, 61, 76, 86, 96, 122, 153, 172, 193, 244, 307, 345,
    387, 488, 615, 690, 775, 976, 1230, 1381, 1550, 1953, 2460, 2762, 3100, 3906, 4921, 5524, 6200,
    7812, 9843, 11048, 12401, 15625, 19686, 22097, 24803, 31250, 39372, 44194, 49606, 62500, 78745,
    88388, 99212, 125000, 157490, 176776, 198425, 250000, 314980, 353553, 396850, 500000, 629960,
    707106, 793700, 1000000, 1259921, 1414213, 1587401, 2000000, 2519842, 2828427, 3174802,
    4000000, 5039684, 5656854, 6349604, 8000000, 10079368, 11313708, 12699208, 16000000, 20158736,
    22627416, 25398416, 32000000, 35000000, 40000000, 40317473, 45000000, 50000000, 50796833,
    55000000, 60000000, 64000000, 80634947, 101593667, 128000000, 161269894, 203187334, 256000000,
    322539788, 406374669, 512000000, 645079577, 812749338, 1024000000, 1290159155, 1625498677,
    2048000000,
];

/// T-mode codes and the minutes each one names (XAPI.h `XSDK_SHUTTER_2M` ..
/// `XSDK_SHUTTER_60M`).
const T_MODE_CODES: &[(i32, u32)] = &[
    (64000030, 2),
    (64000060, 4),
    (64000090, 8),
    (64000120, 15),
    (64000150, 30),
    (64000180, 60),
];

/// How close a timed code must be to the request to be used instead of bulb.
const TIMED_MATCH_TOLERANCE: f64 = 0.01;

/// Below this a request without a matching timed code takes the nearest timed
/// code: the bulb sequence (half press, a 500 ms pause, full press, release on
/// the next status poll) cannot time a sub-second exposure.
const SHORTEST_BULB_SECONDS: f64 = 1.0;

/// Every supported body's bulb mode ends at 60 minutes (Fujifilm specifications).
pub(crate) const LONGEST_BULB_SECONDS: f64 = 3600.0;

/// The exposure time a shutter code sets, or `None` for a code that is not an
/// exposure time this driver knows.
pub(crate) fn code_seconds(code: i32) -> Option<f64> {
    if let Some(&(_, minutes)) = T_MODE_CODES.iter().find(|(c, _)| *c == code) {
        return Some(f64::from(minutes) * 60.0);
    }
    TIMED_CODES
        .contains(&code)
        .then_some(f64::from(code) / 1_000_000.0)
}

/// How the shutter is driven for one exposure, and how long it is open.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Shutter {
    /// The camera times the exposure itself.
    Timed { code: i32, seconds: f64 },
    /// The driver holds the shutter open for `seconds`.
    Bulb { seconds: f64 },
}

/// The timed codes a body reported (`XSDK_CapShutterSpeed`) that this driver
/// can name a duration for, shortest first.
#[derive(Debug, Clone, Default)]
pub(crate) struct ShutterSpeeds {
    timed: Vec<(i32, f64)>,
}

impl ShutterSpeeds {
    /// From the codes the body reported. The body's bulb flag is not consulted:
    /// it reads "not capable" on bodies that then complete bulb exposures (82 of
    /// 82 probes in the owner's NINA plugin, which also lists the bulb code
    /// while denying bulb), and every supported body has a bulb mode.
    pub(crate) fn from_reported(codes: &[i32]) -> Self {
        let mut timed: Vec<(i32, f64)> = codes
            .iter()
            .filter_map(|&code| code_seconds(code).map(|seconds| (code, seconds)))
            .collect();
        timed.sort_by(|a, b| a.1.total_cmp(&b.1));
        timed.dedup_by_key(|(code, _)| *code);
        Self { timed }
    }

    /// The shutter setting for a requested exposure.
    ///
    /// A timed code within 1% of the request is used as is. Otherwise a request
    /// of a second or more is a bulb exposure of exactly that length, so a
    /// sub-exposure is never shortened or lengthened to the nearest step; a
    /// shorter request takes the nearest timed code, and the frame records that
    /// code's time.
    pub(crate) fn choose(&self, seconds: f64) -> Result<Shutter, String> {
        if seconds.is_nan() || seconds <= 0.0 {
            return Err(format!("An exposure of {seconds} s is not possible."));
        }
        if seconds > LONGEST_BULB_SECONDS {
            return Err(format!(
                "A {seconds:.0} s exposure is longer than the camera's 60 minute bulb limit."
            ));
        }
        let nearest = self.timed.iter().copied().min_by(|a, b| {
            (a.1 - seconds)
                .abs()
                .total_cmp(&(b.1 - seconds).abs())
                .then(a.1.total_cmp(&b.1))
        });
        match nearest {
            Some((code, timed)) if (timed - seconds).abs() <= seconds * TIMED_MATCH_TOLERANCE => {
                Ok(Shutter::Timed {
                    code,
                    seconds: timed,
                })
            }
            _ if seconds >= SHORTEST_BULB_SECONDS => Ok(Shutter::Bulb { seconds }),
            Some((code, timed)) => Ok(Shutter::Timed {
                code,
                seconds: timed,
            }),
            None => Err(format!(
                "The camera reported no shutter speeds, so a {seconds} s exposure cannot be set. \
                 Set the shutter speed dial to T and the exposure mode to M, then reconnect."
            )),
        }
    }
}

/// The fixed ISO values among those a body reported (`XSDK_CapSensitivity`),
/// lowest first. The SDK lists the Auto ISO modes in the same array as
/// negative numbers (`XSDK_SENSITIVITY_AUTO1600 = -1600`); selecting one would
/// hand exposure control back to the camera, so they are dropped.
pub(crate) fn fixed_sensitivities(reported: &[i32]) -> Vec<i32> {
    let mut values: Vec<i32> = reported.iter().copied().filter(|&v| v > 0).collect();
    values.sort_unstable();
    values.dedup();
    values
}

/// The supported ISO nearest to `requested` (ties go to the lower ISO), or
/// `requested` itself when the body reported none. A gain control offers any
/// whole number between the lowest and highest ISO; the body accepts only its
/// fixed steps.
pub(crate) fn nearest_sensitivity(supported: &[i32], requested: i32) -> i32 {
    supported
        .iter()
        .copied()
        .min_by_key(|&v| ((i64::from(v) - i64::from(requested)).abs(), v))
        .unwrap_or(requested)
}

/// What sits at the top of the camera's image buffer, from
/// `XSDK_ImageInformation::lFormat`. Only the low byte is the format; bits
/// 0x0F00 carry the body's rotation, so a RAW shot with the camera turned 90°
/// arrives as 0x0601.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BufferedImage {
    Raw,
    LiveView,
    /// A JPEG or HEIF companion of a RAW+JPEG shot, or a thumbnail.
    Other,
}

impl BufferedImage {
    pub(crate) fn from_format(format: i32) -> Self {
        match format & 0xFF {
            1 => Self::Raw,
            4 => Self::LiveView,
            _ => Self::Other,
        }
    }
}

/// How long to wait for a frame to appear in the buffer once the shutter has
/// closed. With long exposure noise reduction on, the body takes a dark of the
/// same length before the frame is ready.
pub(crate) fn frame_wait(exposure_seconds: f64, long_exposure_nr: bool) -> Duration {
    let base = Duration::from_secs(15);
    if long_exposure_nr {
        base + Duration::from_secs_f64(exposure_seconds.max(0.0))
    } else {
        base
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What a body in manual mode reports: whole and third stops to 30 s, the
    /// 5 s steps to 60 s, the T-mode minutes and the bulb code (the GFX100S II
    /// list in the owner's NINA plugin release notes, 3.1.0.0).
    fn body() -> ShutterSpeeds {
        ShutterSpeeds::from_reported(&[
            -1, 976, 3906, 15625, 125000, 250000, 500000, 1000000, 2000000, 4000000, 5039684,
            8000000, 10079368, 16000000, 20158736, 25398416, 32000000, 35000000, 40000000,
            45000000, 50000000, 55000000, 60000000, 64000000, 64000030, 64000060, 64000180,
        ])
    }

    #[test]
    fn a_ten_second_exposure_uses_the_ten_second_code_not_eight() {
        assert_eq!(
            body().choose(10.0),
            Ok(Shutter::Timed {
                code: 10079368,
                seconds: 10.079368
            })
        );
    }

    #[test]
    fn a_request_between_timed_codes_is_a_bulb_exposure_of_exactly_that_length() {
        for seconds in [7.0, 30.0, 47.0, 90.0, 180.0, 300.0, 600.0] {
            assert_eq!(
                body().choose(seconds),
                Ok(Shutter::Bulb { seconds }),
                "{seconds} s"
            );
        }
    }

    #[test]
    fn exact_second_and_t_mode_codes_are_timed() {
        assert_eq!(
            body().choose(60.0),
            Ok(Shutter::Timed {
                code: 60000000,
                seconds: 60.0
            })
        );
        assert_eq!(
            body().choose(45.0),
            Ok(Shutter::Timed {
                code: 45000000,
                seconds: 45.0
            })
        );
        assert_eq!(
            body().choose(120.0),
            Ok(Shutter::Timed {
                code: 64000030,
                seconds: 120.0
            })
        );
        assert_eq!(
            body().choose(3600.0),
            Ok(Shutter::Timed {
                code: 64000180,
                seconds: 3600.0
            })
        );
    }

    #[test]
    fn a_short_request_takes_the_nearest_timed_code_and_records_its_time() {
        assert_eq!(
            body().choose(0.3),
            Ok(Shutter::Timed {
                code: 250000,
                seconds: 0.25
            })
        );
        assert_eq!(
            body().choose(0.001),
            Ok(Shutter::Timed {
                code: 976,
                seconds: 0.000976
            })
        );
    }

    #[test]
    fn requests_the_camera_cannot_make_are_refused() {
        assert!(body().choose(0.0).is_err());
        assert!(body().choose(-1.0).is_err());
        assert!(body().choose(3601.0).is_err());
        assert!(ShutterSpeeds::from_reported(&[]).choose(0.5).is_err());
    }

    #[test]
    fn a_body_without_timed_codes_still_exposes_by_bulb() {
        assert_eq!(
            ShutterSpeeds::from_reported(&[-1]).choose(30.0),
            Ok(Shutter::Bulb { seconds: 30.0 })
        );
    }

    #[test]
    fn unknown_and_flicker_codes_are_ignored() {
        let speeds = ShutterSpeeds::from_reported(&[1000, 1000819200, 2000000]);
        assert_eq!(
            speeds.choose(0.5),
            Ok(Shutter::Timed {
                code: 2000000,
                seconds: 2.0
            })
        );
    }

    #[test]
    fn every_listed_code_has_a_positive_duration() {
        for &code in TIMED_CODES {
            assert!(code_seconds(code).is_some_and(|s| s > 0.0), "{code}");
        }
        assert_eq!(code_seconds(64000150), Some(1800.0));
        assert_eq!(code_seconds(BULB_CODE), None);
    }

    #[test]
    fn auto_iso_modes_are_not_offered_as_iso_values() {
        assert_eq!(
            fixed_sensitivities(&[-1600, 800, 160, -6400, 12800, 800, 0, -1]),
            vec![160, 800, 12800]
        );
    }

    #[test]
    fn a_gain_between_iso_steps_selects_the_nearest_iso() {
        let isos = [160, 200, 250, 320, 400, 500, 640, 800, 1600, 3200];
        assert_eq!(nearest_sensitivity(&isos, 850), 800);
        assert_eq!(nearest_sensitivity(&isos, 1200), 800);
        assert_eq!(nearest_sensitivity(&isos, 1201), 1600);
        assert_eq!(nearest_sensitivity(&isos, 100), 160);
        assert_eq!(nearest_sensitivity(&isos, 6400), 3200);
        assert_eq!(nearest_sensitivity(&[], 850), 850);
    }

    #[test]
    fn a_raw_frame_from_a_rotated_body_is_still_raw() {
        for format in [0x0001, 0x0601, 0x0301, 0x0801] {
            assert_eq!(BufferedImage::from_format(format), BufferedImage::Raw);
        }
        assert_eq!(BufferedImage::from_format(0x0604), BufferedImage::LiveView);
        for format in [0x0007, 0x0607, 0x0012, 0x0812, 0x0005] {
            assert_eq!(BufferedImage::from_format(format), BufferedImage::Other);
        }
    }

    #[test]
    fn long_exposure_noise_reduction_extends_the_frame_wait_by_the_exposure() {
        assert_eq!(frame_wait(300.0, false), Duration::from_secs(15));
        assert_eq!(frame_wait(300.0, true), Duration::from_secs(315));
    }
}
