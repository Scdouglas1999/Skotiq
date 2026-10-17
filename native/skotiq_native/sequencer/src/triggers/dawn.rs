//! Dawn (morning astronomical twilight) helper used by the DawnApproaching trigger.

/// Unix timestamp of the next dawn (morning astronomical twilight) for a
/// given location.
///
/// The math lives in [`crate::solar`] so this and the `WaitTime` twilight
/// instruction are calibrated against the same Sun.
pub fn calculate_dawn_time(latitude: f64, longitude: f64) -> i64 {
    crate::solar::time_of_sun_altitude(
        latitude,
        longitude,
        -18.0,
        crate::solar::SunCrossing::Rising,
    )
}
