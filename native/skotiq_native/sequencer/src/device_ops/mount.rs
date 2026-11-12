//! What a run asks of the mount.

use super::{DeviceError, DeviceResult};
use async_trait::async_trait;

#[async_trait]
pub trait MountOps: Send + Sync {
    /// Slew mount to coordinates (RA in hours, Dec in degrees)
    async fn mount_slew_to_coordinates(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<()>;

    /// Abort mount slew
    async fn mount_abort_slew(&self, mount_id: &str) -> DeviceResult<()>;

    /// Get current mount coordinates (returns RA hours, Dec degrees)
    async fn mount_get_coordinates(&self, mount_id: &str) -> DeviceResult<(f64, f64)>;

    /// Express a J2000 target in the SAME frame [`mount_get_coordinates`]
    /// reports for this mount, so a commanded position can be compared against
    /// a read-back one.
    ///
    /// The two are not interchangeable. Catalogue and plate-solve coordinates
    /// are J2000, but real mounts want coordinates of date, so the device layer
    /// precesses everything it SENDS (slew, sync) and deliberately leaves
    /// everything it READS in the mount's own frame — the hour-angle maths
    /// depends on of-date RA. In 2026 those frames are ~22' apart, which is far
    /// outside any sane slew tolerance, so comparing one to the other reports a
    /// perfectly good slew as a miss.
    ///
    /// Identity by default: the test doubles store exactly what they are given.
    /// The real device layer overrides it, and so does the simulator behind
    /// it, which is an of-date mount too (`epoch::SimMountFrame` in the bridge).
    async fn mount_readback_frame(
        &self,
        _mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<(f64, f64)> {
        Ok((ra_hours, dec_degrees))
    }

    /// The inverse of [`Self::mount_readback_frame`]: express a position this
    /// mount READ BACK in J2000, for anything that records or compares it as a
    /// catalogue coordinate — the FITS `RA`/`DEC` cards and the
    /// `captured_images` pointing columns, which stackers, solvers and the
    /// Library all read as J2000.
    ///
    /// Hour-angle and altitude maths want the of-date read-back itself; convert
    /// only what is stored or matched against catalogues. Identity by default.
    async fn mount_readback_to_j2000(
        &self,
        _mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<(f64, f64)> {
        Ok((ra_hours, dec_degrees))
    }

    /// Sync mount to coordinates
    async fn mount_sync(&self, mount_id: &str, ra_hours: f64, dec_degrees: f64)
        -> DeviceResult<()>;

    /// Park the mount
    async fn mount_park(&self, mount_id: &str) -> DeviceResult<()>;

    /// Unpark the mount
    async fn mount_unpark(&self, mount_id: &str) -> DeviceResult<()>;

    /// Send the mount to its mechanical home position.
    ///
    /// Homing is not parking: the mount is left unparked and commandable. The
    /// default fails closed so a backend that never wired homing says so
    /// instead of reporting a move that did not happen.
    async fn mount_find_home(&self, _mount_id: &str) -> DeviceResult<()> {
        Err(DeviceError::unsupported(
            "Homing is not supported by this device backend",
        ))
    }

    /// Whether the mount reports that it is at its home position.
    ///
    /// Fails closed by default for the same reason as [`Self::mount_find_home`].
    async fn mount_is_at_home(&self, _mount_id: &str) -> DeviceResult<bool> {
        Err(DeviceError::unsupported(
            "Homing is not supported by this device backend",
        ))
    }

    async fn mount_is_slewing(&self, mount_id: &str) -> DeviceResult<bool>;

    /// One read of a slewing mount for [`crate::slew_arrival`]: its `Slewing`
    /// flag and its position in the mount's frame, each `None` when its read
    /// failed. The device layer answers both from one status read.
    async fn mount_slew_state(&self, mount_id: &str) -> crate::slew_arrival::SlewSample {
        crate::slew_arrival::SlewSample {
            slewing: self.mount_is_slewing(mount_id).await.ok(),
            position: self.mount_get_coordinates(mount_id).await.ok(),
        }
    }

    async fn mount_is_parked(&self, mount_id: &str) -> DeviceResult<bool>;

    /// Check if mount can perform a meridian flip
    /// Returns true if mount supports flipping, false otherwise
    async fn mount_can_flip(&self, mount_id: &str) -> DeviceResult<bool>;

    /// Get the side of the pier the mount is currently on
    async fn mount_side_of_pier(&self, mount_id: &str) -> DeviceResult<crate::meridian::PierSide>;

    async fn mount_is_tracking(&self, mount_id: &str) -> DeviceResult<bool>;

    async fn mount_set_tracking(&self, mount_id: &str, enabled: bool) -> DeviceResult<()>;

    /// Run a mount axis at `rate_deg_per_sec` (0 stops it). Axis 0 is the
    /// primary (RA) axis; a positive rate moves it north or east. Used to move
    /// a mount off an axis limit it is stuck at.
    async fn mount_move_axis(
        &self,
        mount_id: &str,
        _axis: i32,
        _rate_deg_per_sec: f64,
    ) -> DeviceResult<()> {
        Err(DeviceError::unsupported(format!(
            "Moving an axis directly is not supported for mount {mount_id}"
        )))
    }

    /// Hold the run for a mount fault the run itself ran into (a recenter
    /// after a fault that could not finish). The device layer pauses the
    /// run and tells the operator; the default does nothing.
    async fn request_mount_fault_hold(&self, _mount_id: &str, _message: &str) {}
}
