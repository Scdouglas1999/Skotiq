//! How a requested exposure is made with a body's shutter speeds: one of its
//! timed speeds, or bulb held open for the request. Pure functions over the
//! choice strings libgphoto2 lists, so they are tested against real bodies'
//! lists.

use skotiq_device::DriverError;

/// The shutter widgets libgphoto2 names, in the order the INDI driver prefers
/// them (gphoto_driver.cpp:1837-1839): Nikon's `shutterspeed2` lists "1/250"
/// where its `shutterspeed` lists "0.0040s".
pub(crate) const SHUTTER_WIDGETS: [&str; 3] = ["shutterspeed2", "shutterspeed", "eos-shutterspeed"];

/// One timed speed the body offers.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct ShutterSpeed {
    pub(crate) choice: String,
    pub(crate) seconds: f64,
}

/// The shutter speeds of one widget as the body lists them now.
#[derive(Debug, Clone, PartialEq, Default)]
pub(crate) struct ShutterSpeeds {
    pub(crate) widget: String,
    /// Timed speeds, shortest first.
    pub(crate) timed: Vec<ShutterSpeed>,
    /// The choice that selects bulb, when the body lists one in its current mode.
    pub(crate) bulb_choice: Option<String>,
}

impl ShutterSpeeds {
    /// `canon_eos`: the choices are a Canon EOS body's, whose wording has
    /// labels of its own (see `canon_eos_seconds`).
    pub(crate) fn from_choices(widget: &str, choices: &[String], canon_eos: bool) -> Self {
        let seconds_of = |choice: &str| {
            canon_eos
                .then(|| canon_eos_seconds(choice))
                .flatten()
                .or_else(|| shutter_seconds(choice))
        };
        let mut timed: Vec<ShutterSpeed> = choices
            .iter()
            .filter_map(|choice| {
                seconds_of(choice).map(|seconds| ShutterSpeed {
                    choice: choice.clone(),
                    seconds,
                })
            })
            .collect();
        timed.sort_by(|a, b| a.seconds.total_cmp(&b.seconds));
        timed.dedup_by(|a, b| a.seconds == b.seconds);
        Self {
            widget: widget.to_string(),
            timed,
            bulb_choice: choices.iter().find(|c| is_bulb_choice(c)).cloned(),
        }
    }

    pub(crate) fn longest(&self) -> Option<f64> {
        self.timed.last().map(|s| s.seconds)
    }

    pub(crate) fn shortest(&self) -> Option<f64> {
        self.timed.first().map(|s| s.seconds)
    }

    fn nearest(&self, seconds: f64) -> Option<&ShutterSpeed> {
        self.timed.iter().min_by(|a, b| {
            let da = (a.seconds / seconds).ln().abs();
            let db = (b.seconds / seconds).ln().abs();
            da.total_cmp(&db)
        })
    }
}

fn is_bulb_choice(choice: &str) -> bool {
    let c = choice.trim().to_ascii_lowercase();
    c.starts_with("bulb") || c == "65535/65535"
}

/// The duration a shutter choice names, or `None` for bulb, time, flash sync
/// ("x 200") and anything else that is no fixed duration.
///
/// The forms libgphoto2 2.5 writes: "1/250" (Canon, Sony, Nikon
/// `shutterspeed2`), "30" and "0.3" (Canon), "0.0040s" and "30.0000s" (Nikon
/// `shutterspeed`), "1/250s", "1 1/3" and "1/3.2", `30"` (seconds mark), and
/// minutes with an "m" suffix ("2m", "1.5m") on Fujifilm bodies
/// (gphoto_driver.cpp:493-497). A minutes-or-seconds "'" is not read: a
/// choice the driver cannot be sure of is left out rather than guessed.
pub(crate) fn shutter_seconds(choice: &str) -> Option<f64> {
    let text = choice.trim().to_ascii_lowercase();
    if text.is_empty() || is_bulb_choice(&text) {
        return None;
    }
    let (number, scale) = if let Some(n) = text.strip_suffix('m') {
        (n.trim(), 60.0)
    } else if let Some(n) = text.strip_suffix('"').or_else(|| text.strip_suffix('s')) {
        (n.trim(), 1.0)
    } else {
        (text.as_str(), 1.0)
    };
    let value = match number.split_once(' ') {
        Some((whole, fraction)) => whole.trim().parse::<f64>().ok()? + fraction_value(fraction)?,
        None if number.contains('/') => fraction_value(number)?,
        None => number.parse::<f64>().ok()?,
    };
    let seconds = value * scale;
    (seconds.is_finite() && seconds > 0.0).then_some(seconds)
}

/// The three Canon EOS labels whose ".3" is no decimal. libgphoto2 names the
/// shutter codes one step apart "20.3" and "20", "10" and "10.3", "6.3" and
/// "6" to tell the half-stop code from the third-stop one
/// (camlibs/ptp2/config.c `canon_shutterspeed`); the body shows, exposes and
/// records 20, 10 and 6 s for either.
fn canon_eos_seconds(choice: &str) -> Option<f64> {
    match choice.trim() {
        "20.3" => Some(20.0),
        "10.3" => Some(10.0),
        "6.3" => Some(6.0),
        _ => None,
    }
}

fn fraction_value(text: &str) -> Option<f64> {
    let (num, den) = text.trim().split_once('/')?;
    let num: f64 = num.trim().parse().ok()?;
    let den: f64 = den.trim().parse().ok()?;
    (den > 0.0).then(|| num / den)
}

/// How an exposure is made.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum ExposurePlan {
    /// One of the body's timed speeds; the frame lasts `speed.seconds`.
    Timed(ShutterSpeed),
    /// The shutter held open for the request and closed by Skotiq.
    Bulb,
}

/// A timed speed this close to the request is the request.
const SAME_DURATION: f64 = 0.01;

/// The longest timed speed used when the body can also do bulb. A timed
/// capture holds the camera (and libgphoto2) until it ends and cannot be
/// aborted, so longer frames are bulb, as NINA makes them (EDCamera.cs:689,
/// bulb above 30 s) and INDI makes every frame of a second or more by
/// default (gphoto_driver.cpp:1165, force bulb on). Fujifilm bodies list
/// timed speeds up to "60m".
const LONGEST_TIMED_WITH_BULB_SECONDS: f64 = 30.0;

/// Bulb is timed by the host, which cannot hold a sub-second release
/// reliably: the release can reach the camera before it starts exposing
/// (gphoto_driver.cpp:1160-1162).
const SHORTEST_BULB_SECONDS: f64 = 1.0;

/// The way to make an exposure of `seconds`: a timed speed of the same
/// duration (up to 30 s on a body that can also do bulb), else bulb for
/// exactly the request when the body can do it,
/// else the nearest timed speed (the frame then records that speed).
pub(crate) fn plan_exposure(
    model: &str,
    speeds: &ShutterSpeeds,
    can_bulb: bool,
    seconds: f64,
) -> Result<ExposurePlan, DriverError> {
    if !seconds.is_finite() || seconds <= 0.0 {
        return Err(DriverError::InvalidParameter(format!(
            "an exposure lasts longer than 0 s; {seconds} s was requested"
        )));
    }
    let bulb_instead =
        can_bulb && seconds > LONGEST_TIMED_WITH_BULB_SECONDS * (1.0 + SAME_DURATION);
    if let Some(same) = speeds
        .timed
        .iter()
        .find(|s| ((s.seconds - seconds) / seconds).abs() <= SAME_DURATION)
        .filter(|_| !bulb_instead)
    {
        return Ok(ExposurePlan::Timed(same.clone()));
    }
    if can_bulb && (seconds >= SHORTEST_BULB_SECONDS || speeds.timed.is_empty()) {
        return Ok(ExposurePlan::Bulb);
    }
    let Some(nearest) = speeds.nearest(seconds) else {
        return Err(DriverError::SdkError(format!(
            "gPhoto2: {model} lists no shutter speeds and offers no bulb control over USB, so \
             Skotiq cannot set an exposure time. Set the camera's mode dial to M."
        )));
    };
    if let Some(longest) = speeds
        .longest()
        .filter(|l| seconds > l * (1.0 + SAME_DURATION))
    {
        if !can_bulb {
            return Err(DriverError::InvalidParameter(format!(
                "{model} offers no bulb control over USB; its longest shutter speed is {longest} s \
                 and {seconds} s was requested"
            )));
        }
    }
    Ok(ExposurePlan::Timed(nearest.clone()))
}

/// The exposures the body can make: from its shortest timed speed to its
/// longest, or to an hour with bulb (the INDI driver's limit,
/// gphoto_driver.cpp:1784).
pub(crate) fn exposure_range(speeds: &ShutterSpeeds, can_bulb: bool) -> Option<(f64, f64)> {
    const LONGEST_BULB_SECONDS: f64 = 3600.0;
    let shortest = speeds
        .shortest()
        .or(can_bulb.then_some(SHORTEST_BULB_SECONDS))?;
    let longest = if can_bulb {
        speeds
            .longest()
            .map_or(LONGEST_BULB_SECONDS, |l| l.max(LONGEST_BULB_SECONDS))
    } else {
        speeds.longest()?
    };
    Some((shortest, longest))
}

/// What the frame records as its exposure time: for a timed speed, the
/// camera's own record in the raw file when it has one (it also tells a body
/// whose mode dial overrode the speed), else the speed; for bulb, the time
/// the shutter was held open.
pub(crate) fn recorded_exposure(made: &MadeExposure, raw_exposure: Option<f64>) -> f64 {
    match made {
        MadeExposure::Timed(seconds) => raw_exposure
            .filter(|s| s.is_finite() && *s > 0.0)
            .unwrap_or(*seconds),
        MadeExposure::Bulb(open) => *open,
    }
}

/// The exposure the camera was asked to make, as far as the host knows it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum MadeExposure {
    /// A timed speed of this many seconds.
    Timed(f64),
    /// Bulb, held open this many seconds.
    Bulb(f64),
}
