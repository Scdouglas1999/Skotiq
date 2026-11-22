//! A read-only check of what a device reports, on every connect and
//! reconnect (owner, 2026-11-22: "have Skotiq check device state/position
//! on connect and attempt to verify the accuracy of that report, we both
//! know astro devices can sometimes incorrectly report states").
//!
//! Nothing here commands a device: no move, no state change, no busy marker
//! (a check never holds a heartbeat or a command off). A disagreement is
//! one warning per device naming what each source said, in the log and as
//! a notice, and a `PropertyChanged` "unverified" event naming the fields;
//! what Skotiq shows stays what the device reports. Checked:
//!
//! * mount: tracking against RA over two reads ([`verdicts::RA_SAMPLE_GAP`]
//!   apart), parked against tracking, pier side against hour angle,
//!   its clock against this computer's, its site against Skotiq's. No driver
//!   Skotiq talks to reports its park coordinates, so a parked mount is not
//!   checked against them. The simulator does not move its RA when it is not
//!   tracking, so its tracking is not checked;
//! * focuser, filter wheel, rotator: position against the last one Skotiq
//!   recorded ([`positions`]); not a wheel that cannot say its slot yet, nor
//!   a relative focuser. The rotator's last recorded angle includes a
//!   sync to a plate solve, so a recent solve is checked through it;
//! * camera: cooler on, power and temperature against its set-point, unless
//!   this connect just switched the cooler back on (it has not settled yet).

pub(crate) mod positions;
pub(crate) mod verdicts;

use crate::device::{DeviceInfo, DriverType};
use crate::device_manager::ops::backstop::Reading;
use crate::device_manager::ops::state_events::property;
use crate::device_manager::DeviceManager;
use verdicts::TrackingVerdict;

/// One thing a check found: the field and the sentence naming both sources.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Disagreement {
    pub(crate) field: &'static str,
    pub(crate) said: String,
}

impl DeviceManager {
    /// Tell the operator what a check of `info` found, once for the device.
    pub(crate) fn report_unverified(&self, info: &DeviceInfo, found: &[Disagreement]) {
        if found.is_empty() {
            return;
        }
        let said: Vec<&str> = found.iter().map(|d| d.said.as_str()).collect();
        self.publish_notice(
            &format!("{}: report not verified", info.shown_name()),
            format!(
                "Checked at connect: {}. Skotiq shows what the {} reports and changes nothing; \
                 check the {} itself.",
                said.join("; "),
                info.device_type.noun(),
                info.device_type.noun()
            ),
        );
        let fields: Vec<&str> = found.iter().map(|d| d.field).collect();
        self.publish_property_changed(
            info.device_type,
            &info.id,
            property::UNVERIFIED,
            fields.join(","),
        );
    }

    /// The position a focuser, wheel or rotator reported at connect,
    /// checked against the last one Skotiq recorded, and recorded. A wheel
    /// that cannot say its slot (-1: moving, or not homed yet after a
    /// reconnect) and a relative focuser (its position restarts with it)
    /// are not checked.
    pub(crate) async fn check_position_at_connect(&self, info: &DeviceInfo, reading: Reading) {
        let unknown = match reading {
            Reading::Filter(slot) => (slot < 0).then_some("the wheel does not say its slot yet"),
            Reading::Focuser(_) => match self.focuser_is_absolute(&info.id).await {
                Ok(true) => None,
                Ok(false) => Some("a relative focuser's position restarts with it"),
                Err(_) => Some("the focuser does not say whether it is absolute"),
            },
            Reading::Rotator(_) => None,
        };
        if let Some(why) = unknown {
            tracing::debug!("{}: position not checked at connect: {why}", info.id);
            return;
        }
        let identity = self.observed_identities.read().await.get(&info.id).cloned();
        self.positions.bind(
            &info.id,
            positions::key(info.device_type, &info.id, identity.as_ref()),
        );
        if let Some(recorded) = self.positions.last(&info.id) {
            if let Some(said) = verdicts::position(reading, recorded) {
                self.report_unverified(
                    info,
                    &[Disagreement {
                        field: "position",
                        said,
                    }],
                );
            }
        }
        self.positions.record(&info.id, reading);
    }

    /// The cooler a camera reported just after its connect, checked.
    pub(crate) async fn check_cooler_at_connect(&self, info: &DeviceInfo) {
        let status = match self.camera_get_status(&info.id).await {
            Ok(status) => status,
            Err(e) => {
                tracing::debug!("{}: cooler not checked at connect: {e}", info.id);
                return;
            }
        };
        if let Some(said) = verdicts::cooler(&status) {
            self.report_unverified(
                info,
                &[Disagreement {
                    field: "cooler",
                    said,
                }],
            );
        }
    }

    /// Check what a mount reports, on a task of its own: the reads take
    /// [`verdicts::RA_SAMPLE_GAP`] and more, and the connect does not wait.
    pub(crate) fn check_mount_after_connect(&self, info: &DeviceInfo) {
        let Some(manager) = self.me.upgrade() else {
            return;
        };
        let info = info.clone();
        tokio::spawn(async move {
            let found = manager.check_mount(&info).await;
            manager.report_unverified(&info, &found);
        });
    }

    pub(crate) async fn check_mount(&self, info: &DeviceInfo) -> Vec<Disagreement> {
        let id = &info.id;
        let mut found = Vec::new();
        let first = match self.mount_get_status(id).await {
            Ok(status) => status,
            Err(e) => {
                tracing::debug!("{id}: mount not checked at connect: {e}");
                return found;
            }
        };
        let started = tokio::time::Instant::now();

        if info.driver_type == DriverType::Simulator {
            tracing::debug!(
                "{id}: tracking not checked: the simulator does not move its RA when it is not \
                 tracking"
            );
        } else {
            tokio::time::sleep(verdicts::RA_SAMPLE_GAP).await;
            let mut verdict = match self.still_connected_status(id).await {
                Some(second) => verdicts::tracking(&first, &second, started.elapsed(), false),
                None => return found,
            };
            if verdict == TrackingVerdict::LookAgain {
                tokio::time::sleep(verdicts::RA_SECOND_LOOK).await;
                verdict = match self.still_connected_status(id).await {
                    Some(third) => verdicts::tracking(&first, &third, started.elapsed(), true),
                    None => return found,
                };
            }
            match verdict {
                TrackingVerdict::Disagrees(said) => found.push(Disagreement {
                    field: "tracking",
                    said,
                }),
                TrackingVerdict::Skip(why) => tracing::debug!("{id}: tracking not checked: {why}"),
                TrackingVerdict::Agrees | TrackingVerdict::LookAgain => {}
            }
        }
        tracing::debug!(
            "{id}: park position not checked: no driver Skotiq talks to reports its park \
             coordinates"
        );

        let status = match self.still_connected_status(id).await {
            Some(status) => status,
            None => return found,
        };
        if let Some(said) = verdicts::pier_side(&status) {
            found.push(Disagreement {
                field: "pier side",
                said,
            });
        }

        let capabilities = match self.mount_site_capabilities(id).await {
            Ok(capabilities) => Some(capabilities),
            Err(e) => {
                tracing::debug!("{id}: clock and site not checked: {e}");
                None
            }
        };
        if capabilities.as_ref().is_some_and(|c| c.can_read_time) {
            match self.mount_get_time(id).await {
                Ok(time) => {
                    if let Some(said) = verdicts::clock(&time, chrono::Utc::now().timestamp()) {
                        found.push(Disagreement {
                            field: "clock",
                            said,
                        });
                    }
                }
                Err(e) => tracing::debug!("{id}: clock not checked: {e}"),
            }
        }
        let skotiq_site = self.app_state.get_observer_location().ok().flatten();
        if let (true, Some(skotiq_site)) = (
            capabilities.as_ref().is_some_and(|c| c.can_read_site),
            skotiq_site,
        ) {
            match self.mount_get_site(id).await {
                Ok(site) => {
                    if let Some(said) =
                        verdicts::site(&site, skotiq_site.latitude, skotiq_site.longitude)
                    {
                        found.push(Disagreement {
                            field: "site",
                            said,
                        });
                    }
                }
                Err(e) => tracing::debug!("{id}: site not checked: {e}"),
            }
        }
        found
    }

    async fn still_connected_status(&self, device_id: &str) -> Option<crate::device::MountStatus> {
        if !self.is_connected(device_id).await {
            return None;
        }
        self.mount_get_status(device_id).await.ok()
    }
}

#[cfg(test)]
mod tests;
