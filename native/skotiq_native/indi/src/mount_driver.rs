//! An INDI telescope as a mount driver.
//!
//! `IndiMount` is a name on its server's shared connection, so a value made
//! for one call is the same mount as any other.

use crate::protocol::names::*;
use crate::{IndiClient, IndiError, IndiMount, IndiPermission};
use async_trait::async_trait;
use skotiq_device::{
    DeviceDriver, DriverError, GuideDirection, MountDescription, MountDriver, MountReadings,
    PierSide, TrackingRate, Vendor,
};

impl std::fmt::Debug for IndiMount {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("IndiMount").field(&self.device_name()).finish()
    }
}

/// The failed half (or halves) of a two-direction axis stop.
///
/// An INDI axis stop is two switch writes (east and west, north and south).
/// Both are sent whatever the first answers, and a failure of either fails
/// the stop: a direction whose `TELESCOPE_MOTION_*` switch stayed On is a
/// mount that is still moving.
fn stop_failure_detail<E: std::fmt::Display>(
    first: (&str, Result<(), E>),
    second: (&str, Result<(), E>),
) -> String {
    let (first_label, first_result) = first;
    let (second_label, second_result) = second;
    let mut parts = Vec::new();
    if let Err(e) = first_result {
        parts.push(format!("{first_label}={e}"));
    }
    if let Err(e) = second_result {
        parts.push(format!("{second_label}={e}"));
    }
    format!("stop failed for {}", parts.join("; "))
}

fn stopped(
    first: (&str, Result<(), IndiError>),
    second: (&str, Result<(), IndiError>),
) -> Result<(), DriverError> {
    match (&first.1, &second.1) {
        (Ok(()), Ok(())) => Ok(()),
        _ => Err(DriverError::Backend(
            stop_failure_detail(first, second).into(),
        )),
    }
}

/// A failed operation in the driver's own words. Whoever shows it reads its
/// kind from the INDI error inside.
fn own(error: IndiError) -> DriverError {
    DriverError::Backend(Box::new(error))
}

/// The pier side an element of `TELESCOPE_PIER_SIDE` names.
fn pier_side(element: &str) -> PierSide {
    let upper = element.to_ascii_uppercase();
    if upper.contains("EAST") || upper.ends_with("_E") {
        PierSide::East
    } else if upper.contains("WEST") || upper.ends_with("_W") {
        PierSide::West
    } else {
        PierSide::Unknown
    }
}

/// What `TELESCOPE_TRACK_MODE` offers: the rates it can be set to, each with
/// the element that selects it, and the rate that is On.
#[derive(Debug, Default)]
struct TrackModes {
    settable: Vec<(TrackingRate, String)>,
    on: Option<TrackingRate>,
}

/// The rate an element of `TELESCOPE_TRACK_MODE` names: `TRACK_SIDEREAL`,
/// `TRACK_SOLAR`, `TRACK_LUNAR`, `TRACK_CUSTOM`, and the `TRACK_KING` some
/// drivers add.
fn named_rate(element: &str) -> Option<TrackingRate> {
    let upper = element.to_ascii_uppercase();
    [
        ("SIDEREAL", TrackingRate::Sidereal),
        ("LUNAR", TrackingRate::Lunar),
        ("SOLAR", TrackingRate::Solar),
        ("KING", TrackingRate::King),
        ("CUSTOM", TrackingRate::Custom),
    ]
    .into_iter()
    .find_map(|(word, rate)| upper.contains(word).then_some(rate))
}

/// A driver without the switch tracks at the one rate it does not name. The
/// custom mode is not offered: its rate is `TELESCOPE_TRACK_RATE`'s numbers,
/// which nothing here sets.
async fn track_modes(client: &IndiClient, device_name: &str) -> TrackModes {
    let Some(prop) = client.get_property(device_name, TELESCOPE_TRACK_MODE).await else {
        return TrackModes::default();
    };
    let writable = prop.perm != IndiPermission::ReadOnly;
    let mut modes = TrackModes::default();
    for element in prop.elements {
        let Some(rate) = named_rate(&element) else {
            continue;
        };
        // An element the server has not sent yet is not the one that is On.
        if client
            .get_switch(device_name, TELESCOPE_TRACK_MODE, &element)
            .await
            .unwrap_or(false)
        {
            modes.on = Some(rate);
        }
        if writable && rate != TrackingRate::Custom {
            modes.settable.push((rate, element));
        }
    }
    modes
}

/// `current` widened by `next` with `pick` (`f64::min` or `f64::max`).
fn widest(current: Option<f64>, next: Option<f64>, pick: fn(f64, f64) -> f64) -> Option<f64> {
    match (current, next) {
        (Some(current), Some(next)) => Some(pick(current, next)),
        (current, next) => current.or(next),
    }
}

impl IndiMount {
    async fn has_switch(&self, property: &str, element: &str) -> bool {
        self.client()
            .read()
            .await
            .get_switch(self.device_name(), property, element)
            .await
            .is_some()
    }

    async fn has_park(&self) -> bool {
        self.has_switch(TELESCOPE_PARK, PARK).await || self.has_switch(TELESCOPE_PARK, UNPARK).await
    }

    async fn has_guide_pulses(&self) -> bool {
        let client = self.client().read().await;
        client
            .get_number(self.device_name(), TELESCOPE_TIMED_GUIDE_NS, TIMED_GUIDE_N)
            .await
            .is_some()
            || client
                .get_number(self.device_name(), TELESCOPE_TIMED_GUIDE_WE, TIMED_GUIDE_E)
                .await
                .is_some()
    }
}

#[async_trait]
impl DeviceDriver for IndiMount {
    fn id(&self) -> &str {
        self.device_name()
    }

    fn name(&self) -> &str {
        self.device_name()
    }

    fn vendor(&self) -> Vendor {
        Vendor::Indi
    }

    /// A value of this type is a device that was connected;
    /// [`MountDriver::heartbeat`] asks the server whether it still is.
    fn is_connected(&self) -> bool {
        true
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        IndiMount::connect(self).await.map_err(own)
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        IndiMount::disconnect(self).await.map_err(own)
    }
}

#[async_trait]
impl MountDriver for IndiMount {
    async fn heartbeat(&self) -> Result<bool, DriverError> {
        self.check().await.map_err(own)
    }

    async fn slew_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError> {
        IndiMount::slew_to_coordinates(self, ra_hours, dec_degrees).await.map_err(own)
    }

    async fn slew_to_alt_az(
        &mut self,
        altitude_deg: f64,
        azimuth_deg: f64,
    ) -> Result<(), DriverError> {
        IndiMount::slew_to_alt_az(self, altitude_deg, azimuth_deg).await.map_err(own)
    }

    async fn get_coordinates(&self) -> Result<(f64, f64), DriverError> {
        IndiMount::get_coordinates(self).await.map_err(own)
    }

    async fn sync_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError> {
        IndiMount::sync_to_coordinates(self, ra_hours, dec_degrees).await.map_err(own)
    }

    async fn park(&mut self) -> Result<(), DriverError> {
        IndiMount::park(self).await.map_err(own)
    }

    async fn unpark(&mut self) -> Result<(), DriverError> {
        IndiMount::unpark(self).await.map_err(own)
    }

    async fn is_slewing(&self) -> Result<bool, DriverError> {
        self.try_is_slewing().await.map_err(own)
    }

    async fn is_parked(&self) -> Result<bool, DriverError> {
        self.try_is_parked().await.map_err(own)
    }

    async fn can_park(&self) -> Result<bool, DriverError> {
        Ok(self.has_park().await)
    }

    async fn pulse_guide(
        &mut self,
        direction: GuideDirection,
        duration_ms: u32,
    ) -> Result<(), DriverError> {
        IndiMount::pulse_guide(self, direction, duration_ms).await.map_err(own)
    }

    async fn abort_slew(&mut self) -> Result<(), DriverError> {
        IndiMount::abort_slew(self).await.map_err(own)
    }

    /// INDI moves an axis by direction, at the driver's slew rate: a
    /// positive `rate` is east or north, a negative one west or south, and
    /// 0 stops both directions of the axis.
    async fn move_axis(&mut self, axis: i32, rate: f64) -> Result<(), DriverError> {
        if axis == 0 {
            if rate > 0.0 {
                self.move_east(true).await.map_err(own)
            } else if rate < 0.0 {
                self.move_west(true).await.map_err(own)
            } else {
                let east = self.move_east(false).await;
                let west = self.move_west(false).await;
                stopped(("east", east), ("west", west))
            }
        } else if rate > 0.0 {
            self.move_north(true).await.map_err(own)
        } else if rate < 0.0 {
            self.move_south(true).await.map_err(own)
        } else {
            let north = self.move_north(false).await;
            let south = self.move_south(false).await;
            stopped(("north", north), ("south", south))
        }
    }

    async fn set_tracking(&mut self, enabled: bool) -> Result<(), DriverError> {
        IndiMount::set_tracking(self, enabled).await.map_err(own)
    }

    async fn get_tracking(&self) -> Result<bool, DriverError> {
        self.try_is_tracking().await.map_err(own)
    }

    async fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), DriverError> {
        let modes = track_modes(&*self.client().read().await, self.device_name()).await;
        let element = modes
            .settable
            .into_iter()
            .find_map(|(offered, element)| (offered == rate).then_some(element))
            .ok_or(DriverError::NotSupported)?;
        self.set_track_mode(&element).await.map_err(own)
    }

    async fn get_tracking_rate(&self) -> Result<TrackingRate, DriverError> {
        track_modes(&*self.client().read().await, self.device_name())
            .await
            .on
            .ok_or(DriverError::NotSupported)
    }

    async fn tracking_rates(&self) -> Vec<TrackingRate> {
        track_modes(&*self.client().read().await, self.device_name())
            .await
            .settable
            .into_iter()
            .map(|(rate, _)| rate)
            .collect()
    }

    async fn can_slew(&self) -> bool {
        self.has_switch(ON_COORD_SET, SLEW).await
    }

    async fn can_sync(&self) -> bool {
        self.has_switch(ON_COORD_SET, SYNC).await
    }

    async fn can_pulse_guide(&self) -> bool {
        self.has_guide_pulses().await
    }

    async fn get_side_of_pier(&self) -> Result<PierSide, DriverError> {
        match self.get_pier_side().await {
            Some(element) => Ok(pier_side(&element)),
            None => Err(DriverError::NotSupported),
        }
    }

    async fn get_alt_az(&self) -> Result<(f64, f64), DriverError> {
        self.get_horizontal_coordinates().await.map_err(own)
    }

    /// `TIME_LST` is optional and not read.
    async fn get_sidereal_time(&self) -> Result<f64, DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn status(&self) -> Result<MountReadings, DriverError> {
        let (right_ascension, declination) = IndiMount::get_coordinates(self).await.map_err(own)?;
        let tracking = self.try_is_tracking().await.map_err(own)?;
        let slewing = self.try_is_slewing().await.map_err(own)?;
        let parked = self.try_is_parked().await.map_err(own)?;
        let (altitude, azimuth) = match self.get_horizontal_coordinates().await {
            Ok((altitude, azimuth)) => (Ok(altitude), Ok(azimuth)),
            Err(e) => {
                let words = e.to_string();
                (Err(own(e)), Err(DriverError::Backend(words.into())))
            }
        };
        let side_of_pier = self.get_side_of_pier().await;
        let can_park = self.has_park().await;
        let can_slew = self.can_slew().await;
        let can_sync = self.can_sync().await;
        let can_pulse_guide = self.has_guide_pulses().await;
        let modes = track_modes(&*self.client().read().await, self.device_name()).await;
        Ok(MountReadings {
            right_ascension,
            declination,
            tracking,
            slewing,
            parked: Some(parked),
            // INDI has no standard at-home property.
            at_home: Err(DriverError::NotSupported),
            side_of_pier,
            altitude,
            azimuth,
            sidereal_time: Err(DriverError::NotSupported),
            tracking_rate: modes.on.ok_or(DriverError::NotSupported),
            can_park,
            can_slew,
            can_sync,
            can_pulse_guide,
            can_set_tracking_rate: !modes.settable.is_empty(),
        })
    }

    /// From the properties the driver defines; a pulse length or slew rate
    /// range is the number limits it publishes, the widest over the axes.
    async fn describe(&self) -> MountDescription {
        let device = self.device_name();
        let properties = crate::kind::defined_properties(self.client(), device).await;
        let defines = |name: &str| properties.iter().any(|p| p.name == name);
        let equatorial = properties.iter().any(|p| p.name.starts_with("EQUATORIAL_"));
        let alt_az = defines(HORIZONTAL_COORD);
        let can_park = defines(TELESCOPE_PARK);
        let can_move_ns = defines(TELESCOPE_MOTION_NS);
        let can_move_we = defines(TELESCOPE_MOTION_WE);
        let client = self.client().read().await;
        let mut slew_rate: Option<f64> = None;
        let mut pulse: (Option<f64>, Option<f64>) = (None, None);
        for prop in &properties {
            let is_pulse =
                prop.name == TELESCOPE_TIMED_GUIDE_NS || prop.name == TELESCOPE_TIMED_GUIDE_WE;
            if prop.name != TELESCOPE_SLEW_RATE && !is_pulse {
                continue;
            }
            for element in &prop.elements {
                let Some(limits) = client.get_number_limits(device, &prop.name, element).await
                else {
                    continue;
                };
                if is_pulse {
                    pulse.0 = widest(pulse.0, limits.min, f64::min);
                    pulse.1 = widest(pulse.1, limits.max, f64::max);
                } else {
                    slew_rate = widest(slew_rate, limits.max, f64::max);
                }
            }
        }
        drop(client);
        MountDescription {
            can_slew: equatorial || alt_az,
            can_slew_async: equatorial || alt_az,
            can_sync: defines(ON_COORD_SET),
            can_park,
            can_unpark: can_park,
            // `set_park` drives PARK_CURRENT.
            can_set_park: properties.iter().any(|p| {
                p.name == TELESCOPE_PARK_OPTION && p.elements.iter().any(|e| e == PARK_CURRENT)
            }),
            can_find_home: defines(TELESCOPE_HOME),
            can_pulse_guide: properties
                .iter()
                .any(|p| p.name.starts_with("TELESCOPE_TIMED_GUIDE_")),
            can_set_tracking: defines(TELESCOPE_TRACK_STATE),
            tracking_rates: self.tracking_rates().await,
            can_get_side_of_pier: defines(TELESCOPE_PIER_SIDE),
            is_equatorial: equatorial,
            supports_alt_az: alt_az,
            can_abort_slew: defines(TELESCOPE_ABORT_MOTION),
            can_move_axis: can_move_ns || can_move_we,
            axis_count: u32::from(can_move_ns) + u32::from(can_move_we),
            max_slew_rate: slew_rate,
            min_pulse_guide_ms: pulse.0,
            max_pulse_guide_ms: pulse.1,
        }
    }

    /// `find_home` drives `TELESCOPE_HOME.GO`, so that element is the
    /// capability.
    async fn can_find_home(&self) -> Result<bool, DriverError> {
        Ok(self.has_switch(TELESCOPE_HOME, GO).await)
    }

    async fn find_home(&mut self) -> Result<(), DriverError> {
        IndiMount::find_home(self).await.map_err(own)
    }

    async fn can_set_park(&self) -> Result<bool, DriverError> {
        Ok(IndiMount::can_set_park(self).await)
    }

    async fn set_park(&mut self) -> Result<(), DriverError> {
        self.set_park_to_current().await.map_err(own)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failed_half_of_an_axis_stop_is_named() {
        assert_eq!(
            stop_failure_detail(
                ("east", Err::<(), _>("device disconnected")),
                ("west", Ok::<(), &str>(())),
            ),
            "stop failed for east=device disconnected"
        );
        assert_eq!(
            stop_failure_detail(
                ("north", Ok::<(), &str>(())),
                ("south", Err::<(), _>("timeout")),
            ),
            "stop failed for south=timeout"
        );
        assert_eq!(
            stop_failure_detail(
                ("east", Err::<(), _>("write failed")),
                ("west", Err::<(), _>("broken pipe")),
            ),
            "stop failed for east=write failed; west=broken pipe"
        );
    }

    #[test]
    fn a_pier_side_element_is_read_by_its_name() {
        assert_eq!(pier_side("PIER_EAST"), PierSide::East);
        assert_eq!(pier_side("PIER_W"), PierSide::West);
        assert_eq!(pier_side("SOMETHING"), PierSide::Unknown);
    }
}
