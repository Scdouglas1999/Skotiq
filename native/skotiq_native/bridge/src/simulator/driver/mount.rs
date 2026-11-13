//! The simulated mount. The mount itself is the simulator's one mount state;
//! this handle holds none, so one built for an id that never went through
//! connect answers exactly as the connected one does, and the simulator's own
//! gate says whether the mount is connected.

use crate::device::{MountSite, MountSiteCapabilities, MountStatus, MountTimeInfo, TrackingRate};
use crate::device_capabilities::types::DeviceCapabilities;
use crate::device_manager::rig::mount::Mount;
use crate::device_manager::rig::RigDriver;
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use crate::simulator::mount::get_sim_mount;
use async_trait::async_trait;
use skotiq_device::DriverError;

pub(crate) struct SimMount {
    device_id: String,
}

impl SimMount {
    pub(crate) fn new(device_id: &str) -> Self {
        Self {
            device_id: device_id.to_string(),
        }
    }
}

#[async_trait]
impl RigDriver for SimMount {
    async fn disconnect(&self) -> Result<(), DriverError> {
        get_sim_mount().write().await.status.connected = false;
        tracing::info!("Simulator disconnected: id={} type=Mount", self.device_id);
        Ok(())
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        Ok(get_sim_mount().read().await.status.connected)
    }
}

#[async_trait]
impl Mount for SimMount {
    async fn slew(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError> {
        crate::simulator::gate::require_mount_connected().await?;
        crate::simulator::gate::refuse_while_mount_slewing("slew").await?;
        // Travels to the target over time rather than teleporting, and
        // records the pier side the mount lands on. See
        // `crate::simulator::begin_sim_slew`.
        crate::simulator::mount::begin_sim_slew(ra, dec, chrono::Utc::now()).await;
        // Repointing starts a new target: the previous one's accumulated
        // drift does not carry over, and this is what stops a long
        // session leaving the field pinned at its offset clamp.
        crate::simulator::guiding::reset_sim_guide_offset().await;
        Ok(())
    }

    async fn slew_alt_az(&self, altitude: f64, azimuth: f64) -> Result<(), DeviceOpError> {
        crate::simulator::gate::require_mount_connected().await?;
        crate::simulator::gate::refuse_while_mount_slewing("alt/az slew").await?;
        // Store the equatorial pointing the alt/az slew produced, not the
        // alt/az pair itself: RA/Dec is the simulator's single source of
        // truth and the horizon-frame fields are derived from it on every
        // read (see `gate::read_mount_status`). Writing alt/az here
        // instead left them frozen at the commanded value while the sky
        // moved on underneath.
        let site = crate::state::get_state()
            .get_observer_location()
            .ok()
            .flatten();
        let Some(site) = site else {
            return Err(DeviceOpError::unsupported(
                "Alt/Az slew needs an observer location; set the site first",
            ));
        };
        let now = chrono::Utc::now();
        let (ra, dec) = skotiq_sequencer::meridian::alt_az_to_ra_dec(
            altitude,
            azimuth,
            site.latitude,
            site.longitude,
            now,
        );
        crate::simulator::mount::begin_sim_slew(ra, dec, now).await;
        crate::simulator::guiding::reset_sim_guide_offset().await;
        Ok(())
    }

    async fn abort(&self) -> Result<(), DeviceOpError> {
        crate::simulator::gate::require_mount_connected().await?;
        // Drop the in-flight slew first, or the interpolation would
        // carry the mount on to the target it was just told to stop
        // travelling to.
        crate::simulator::mount::cancel_sim_slew().await;
        crate::simulator::mount::get_sim_mount()
            .write()
            .await
            .status
            .slewing = false;
        Ok(())
    }

    async fn stop(&self) -> Result<(), DeviceOpError> {
        crate::simulator::gate::require_mount_connected().await?;
        crate::simulator::mount::cancel_sim_slew().await;
        let mut m = crate::simulator::mount::get_sim_mount().write().await;
        m.status.slewing = false;
        m.status.tracking = false;
        Ok(())
    }

    async fn move_axis(&self, _axis: i32, rate: f64) -> Result<(), DeviceOpError> {
        // See `mount_unpark`: the shared gate, not an inline
        // `connected` read, is what advances the motion and runs the
        // fault injector.
        crate::simulator::gate::require_mount_connected().await?;
        // NOT refused mid-slew: `rate == 0.0` is how the hand-controller
        // buttons STOP an axis, and a stop must never be rejected.
        // The simulator has no axis-rate state model — just record
        // `slewing` so subsequent `mount_get_status` reflects the move
        // command. A real driver wouldn't no-op silently.
        let m = crate::simulator::mount::get_sim_mount();
        let mut m = m.write().await;
        m.status.slewing = rate != 0.0;
        // Driving an axis moves the mount off its home pose.
        if rate != 0.0 {
            m.status.at_home = Some(false);
        }
        Ok(())
    }

    async fn park(&self) -> Result<(), DeviceOpError> {
        crate::simulator::gate::require_mount_connected().await?;
        crate::simulator::gate::refuse_while_mount_slewing("park").await?;
        // Drop the in-flight slew BEFORE writing the park position: a
        // status read landing in between would otherwise advance the
        // abandoned slew straight back over it.
        crate::simulator::mount::cancel_sim_slew().await;
        let (ra, dec) = crate::simulator::mount::sim_park_position();
        let mut m = crate::simulator::mount::get_sim_mount().write().await;
        m.status.right_ascension = ra;
        m.status.declination = dec;
        m.status.parked = true;
        m.status.tracking = false;
        m.status.slewing = false;
        // ASCOM resets AtHome on any slew, and parking is one: a
        // parked mount reports AtPark, not AtHome, even though the
        // simulator parks on the same pose it homes to.
        m.status.at_home = Some(false);
        drop(m);
        crate::simulator::guiding::reset_sim_guide_offset().await;
        Ok(())
    }

    async fn unpark(&self) -> Result<(), DeviceOpError> {
        // Goes through the shared gate rather than an inline
        // `connected` read: the gate is also what runs the fault
        // injector and advances the in-flight slew, so unpark now sees
        // — and can be made to fail on — the same mount state every
        // other mutating op does.
        crate::simulator::gate::require_mount_connected().await?;
        let m = crate::simulator::mount::get_sim_mount();
        let lst = crate::simulator::mount::sim_local_sidereal_time(chrono::Utc::now());
        let mut m = m.write().await;
        m.status.parked = false;
        crate::simulator::mount::seed_unknown_pier_side(&mut m.status, lst);
        Ok(())
    }

    async fn find_home(&self) -> Result<(), DeviceOpError> {
        crate::simulator::gate::require_mount_connected().await?;
        // A real driver refuses FindHome mid-slew; abort first.
        crate::simulator::gate::refuse_while_mount_slewing("home").await?;
        // Travels to the home pose over time and reports AtHome only
        // once it has arrived and settled; see
        // `crate::simulator::begin_sim_home`.
        crate::simulator::mount::begin_sim_home().await;
        crate::simulator::guiding::reset_sim_guide_offset().await;
        Ok(())
    }

    async fn can_find_home(&self) -> Result<bool, DeviceOpError> {
        crate::simulator::gate::read_mount_status().await?;
        Ok(true)
    }

    async fn set_park(&self) -> Result<(), DeviceOpError> {
        crate::simulator::gate::require_mount_connected().await?;
        crate::simulator::gate::refuse_while_mount_slewing("set park").await?;
        let (ra, dec) = {
            let m = crate::simulator::mount::get_sim_mount().read().await;
            (m.status.right_ascension, m.status.declination)
        };
        crate::simulator::mount::set_sim_park_position(ra, dec);
        Ok(())
    }

    async fn can_set_park(&self) -> Result<bool, DeviceOpError> {
        crate::simulator::gate::read_mount_status().await?;
        Ok(true)
    }

    async fn can_park(&self) -> Result<bool, DeviceOpError> {
        let sim = crate::simulator::gate::read_mount_status().await?;
        Ok(sim.can_park)
    }

    async fn sync(&self, ra: f64, dec: f64) -> Result<(), DeviceOpError> {
        crate::simulator::gate::require_mount_connected().await?;
        crate::simulator::gate::refuse_while_mount_slewing("sync").await?;
        // A sync redefines where the mount believes it is pointing
        // without moving it, so any in-flight slew has to be dropped
        // first — otherwise the interpolation would overwrite the
        // synced coordinates on the next status read.
        crate::simulator::mount::cancel_sim_slew().await;
        crate::simulator::runaway::clear_physical_pointing();
        let m = crate::simulator::mount::get_sim_mount();
        let mut m = m.write().await;
        m.status.right_ascension = ra;
        m.status.declination = dec;
        m.status.slewing = false;
        Ok(())
    }

    async fn coordinates(&self) -> Result<(f64, f64), DeviceOpError> {
        let sim = crate::simulator::gate::read_mount_status().await?;
        Ok((sim.right_ascension, sim.declination))
    }

    async fn status(&self) -> Result<MountStatus, DeviceOpError> {
        crate::simulator::gate::read_mount_status().await
    }

    async fn set_tracking(&self, enabled: bool) -> Result<(), DeviceOpError> {
        // See `mount_unpark`: the shared gate, not an inline
        // `connected` read, is what advances the motion and runs the
        // fault injector.
        crate::simulator::gate::require_mount_connected().await?;
        let lst = crate::simulator::mount::sim_local_sidereal_time(chrono::Utc::now());
        let m = crate::simulator::mount::get_sim_mount();
        let mut m = m.write().await;
        m.status.tracking = enabled;
        if enabled {
            crate::simulator::mount::seed_unknown_pier_side(&mut m.status, lst);
        }
        // Tracking turns the RA axis, which carries the mount off the
        // home pose a FindHome left it in.
        if enabled {
            m.status.at_home = Some(false);
        }
        Ok(())
    }

    async fn pulse_guide(
        &self,
        dir: skotiq_device::GuideDirection,
        duration_ms: u32,
    ) -> Result<(), DeviceOpError> {
        // Move the simulated star field. A guide pulse that gates on
        // connection and returns Ok without recording anything leaves
        // the built-in guider's own pulses never shifting the field it
        // is measuring, so calibration aborts with "Calibration
        // response on east axis was too small (0.000px)" and guiding,
        // dithering and the correction loop cannot be exercised
        // without a mount.
        crate::simulator::gate::require_mount_connected().await?;
        crate::simulator::guiding::advance_sim_guide_pulse(
            match dir {
                skotiq_device::GuideDirection::North => "north",
                skotiq_device::GuideDirection::South => "south",
                skotiq_device::GuideDirection::East => "east",
                skotiq_device::GuideDirection::West => "west",
            },
            duration_ms,
        )
        .await;
        Ok(())
    }

    async fn set_tracking_rate(&self, rate: i32) -> Result<(), DeviceOpError> {
        // See `mount_unpark`: the shared gate, not an inline
        // `connected` read, is what advances the motion and runs the
        // fault injector. It runs before the rate is parsed so a
        // disconnected mount reports being disconnected rather than
        // grading the caller's argument.
        crate::simulator::gate::require_mount_connected().await?;
        // The simulated mount advertises `can_set_tracking_rate: true`
        // and reports a rate, so it has to accept one — falling through
        // to the unsupported arm made its own capability report a lie.
        let rate = match rate {
            0 => TrackingRate::Sidereal,
            1 => TrackingRate::Lunar,
            2 => TrackingRate::Solar,
            3 => TrackingRate::King,
            4 => TrackingRate::Custom,
            _ => {
                return Err(DeviceOpError::invalid_parameter(format!(
                    "Invalid tracking rate: {}",
                    rate
                )))
            }
        };
        let m = crate::simulator::mount::get_sim_mount();
        m.write().await.status.tracking_rate = Some(rate);
        Ok(())
    }

    async fn tracking_rate(&self) -> Result<i32, DeviceOpError> {
        let sim = crate::simulator::gate::read_mount_status().await?;
        // Project the singleton's `tracking_rate` Option onto the
        // i32 wire form. None → 0 (Sidereal) is the project-wide
        // default for "rate not declared".
        Ok(match sim.tracking_rate {
            Some(TrackingRate::Sidereal) => 0,
            Some(TrackingRate::Lunar) => 1,
            Some(TrackingRate::Solar) => 2,
            Some(TrackingRate::King) => 3,
            Some(TrackingRate::Custom) => 4,
            None => 0,
        })
    }

    async fn site(&self) -> Result<MountSite, DeviceOpError> {
        let location = crate::state::get_state()
            .get_observer_location()
            .map_err(|e| DeviceOpError::from(e.to_string()))?;
        match location {
            Some(loc) => Ok(MountSite {
                latitude_deg: loc.latitude,
                longitude_deg: loc.longitude,
                elevation_m: Some(loc.elevation),
            }),
            None => Err(DeviceOpError::unsupported(
                "The simulated mount has no site until the observer location is set",
            )),
        }
    }

    async fn set_site(&self, _site: MountSite) -> Result<(), DeviceOpError> {
        Ok(())
    }

    async fn time(&self) -> Result<MountTimeInfo, DeviceOpError> {
        Ok(MountTimeInfo {
            utc_unix_seconds: chrono::Utc::now().timestamp(),
            utc_offset_hours: 0.0,
        })
    }

    async fn set_time(&self, _time: MountTimeInfo) -> Result<(), DeviceOpError> {
        Ok(())
    }

    async fn site_capabilities(&self) -> Result<MountSiteCapabilities, DeviceOpError> {
        Ok(MountSiteCapabilities {
            can_read_site: true,
            can_write_site: true,
            can_read_time: true,
            can_write_time: true,
        })
    }

    async fn capabilities(&self, device_id: &str) -> Result<DeviceCapabilities, SkotiqError> {
        let parsed = crate::device_id::cache::parse_device_id_cached(device_id)?;
        crate::simulator::capabilities::get_simulator_capabilities(&parsed).await
    }
}
