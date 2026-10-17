//! [`DeviceCommonMetadata`] trait implementations for the 7 typed ASCOM
//! wrappers in `crate::ascom_wrapper`.
//!
//! The trait and the shared [`fetch_api_version`] helper live in
//! [`crate::dispatch::device_common_metadata`]; this module only contains
//! the per-wrapper delegations.
//!
//! # All 10 ASCOM wrappers covered
//!
//! All 10 typed ASCOM wrappers (camera, mount, focuser, filter wheel, dome,
//! switch, cover calibrator, rotator, safety monitor, observing conditions)
//! now expose the four ASCOM-Common identification properties and have impl
//! blocks here. Each impl is a verbatim forwarder to the wrapper's inherent
//! method of the same name; see [`fetch_api_version`] for the silent-fallback
//! contract that operates at the dispatch layer above the trait.
//!
//! # Error-type normalization
//!
//! The ASCOM wrappers are heterogeneous in their native error type:
//!
//! * `AscomSwitchWrapper`, `AscomDomeWrapper`, `AscomCoverCalibratorWrapper`
//!   return `Result<_, String>` natively — direct passthrough.
//! * `AscomCameraWrapper`, `AscomMountWrapper`, `AscomFocuserWrapper`,
//!   `AscomFilterWheelWrapper` return `Result<_, NativeError>` (from
//!   `skotiq_native::traits::NativeError`) — the impl converts to
//!   `String` at the trait boundary via `e.to_string()` so the trait
//!   contract stays uniform.
//!
//! This conversion is deliberately done at the impl boundary rather than
//! changing the wrapper signatures, because the wrappers' callers in
//! `device_manager::ops::*` rely on the typed `NativeError` discriminants
//! for retry/recovery decisions. The bridge dispatch layer flattens to
//! `String` anyway, so the conversion is free at this site and contained.
//!
//! [`fetch_api_version`]: crate::dispatch::device_common_metadata::fetch_api_version

use crate::ascom_wrapper::camera::AscomCameraWrapper;
use crate::ascom_wrapper::covercalibrator::AscomCoverCalibratorWrapper;
use crate::ascom_wrapper::dome::AscomDomeWrapper;
use crate::ascom_wrapper::filterwheel::AscomFilterWheelWrapper;
use crate::ascom_wrapper::focuser::AscomFocuserWrapper;
use crate::ascom_wrapper::mount::AscomMountWrapper;
use crate::ascom_wrapper::rotator::AscomRotatorWrapper;
use crate::ascom_wrapper::safetymonitor::AscomSafetyMonitorWrapper;
use crate::ascom_wrapper::switch::AscomSwitchWrapper;
use crate::ascom_wrapper::weather::AscomObservingConditionsWrapper;
use crate::dispatch::device_common_metadata::DeviceCommonMetadata;

// Native-error wrappers (camera, mount, focuser, filter wheel) — convert
// NativeError → String at the trait boundary via Display.

impl DeviceCommonMetadata for AscomCameraWrapper {
    async fn interface_version(&self) -> Result<i32, String> {
        Self::interface_version(self)
            .await
            .map_err(|e| e.to_string())
    }
    async fn driver_version(&self) -> Result<String, String> {
        Self::driver_version(self).await.map_err(|e| e.to_string())
    }
    async fn driver_info(&self) -> Result<String, String> {
        Self::driver_info(self).await.map_err(|e| e.to_string())
    }
    async fn supported_actions(&self) -> Result<Vec<String>, String> {
        Self::supported_actions(self)
            .await
            .map_err(|e| e.to_string())
    }
}

impl DeviceCommonMetadata for AscomMountWrapper {
    async fn interface_version(&self) -> Result<i32, String> {
        Self::interface_version(self)
            .await
            .map_err(|e| e.to_string())
    }
    async fn driver_version(&self) -> Result<String, String> {
        Self::driver_version(self).await.map_err(|e| e.to_string())
    }
    async fn driver_info(&self) -> Result<String, String> {
        Self::driver_info(self).await.map_err(|e| e.to_string())
    }
    async fn supported_actions(&self) -> Result<Vec<String>, String> {
        Self::supported_actions(self)
            .await
            .map_err(|e| e.to_string())
    }
}

impl DeviceCommonMetadata for AscomFocuserWrapper {
    async fn interface_version(&self) -> Result<i32, String> {
        Self::interface_version(self)
            .await
            .map_err(|e| e.to_string())
    }
    async fn driver_version(&self) -> Result<String, String> {
        Self::driver_version(self).await.map_err(|e| e.to_string())
    }
    async fn driver_info(&self) -> Result<String, String> {
        Self::driver_info(self).await.map_err(|e| e.to_string())
    }
    async fn supported_actions(&self) -> Result<Vec<String>, String> {
        Self::supported_actions(self)
            .await
            .map_err(|e| e.to_string())
    }
}

impl DeviceCommonMetadata for AscomFilterWheelWrapper {
    async fn interface_version(&self) -> Result<i32, String> {
        Self::interface_version(self)
            .await
            .map_err(|e| e.to_string())
    }
    async fn driver_version(&self) -> Result<String, String> {
        Self::driver_version(self).await.map_err(|e| e.to_string())
    }
    async fn driver_info(&self) -> Result<String, String> {
        Self::driver_info(self).await.map_err(|e| e.to_string())
    }
    async fn supported_actions(&self) -> Result<Vec<String>, String> {
        Self::supported_actions(self)
            .await
            .map_err(|e| e.to_string())
    }
}

// String-error wrappers (switch, dome, cover calibrator) — direct passthrough.

impl DeviceCommonMetadata for AscomSwitchWrapper {
    async fn interface_version(&self) -> Result<i32, String> {
        Self::interface_version(self).await
    }
    async fn driver_version(&self) -> Result<String, String> {
        Self::driver_version(self).await
    }
    async fn driver_info(&self) -> Result<String, String> {
        Self::driver_info(self).await
    }
    async fn supported_actions(&self) -> Result<Vec<String>, String> {
        Self::supported_actions(self).await
    }
}

impl DeviceCommonMetadata for AscomDomeWrapper {
    async fn interface_version(&self) -> Result<i32, String> {
        Self::interface_version(self).await
    }
    async fn driver_version(&self) -> Result<String, String> {
        Self::driver_version(self).await
    }
    async fn driver_info(&self) -> Result<String, String> {
        Self::driver_info(self).await
    }
    async fn supported_actions(&self) -> Result<Vec<String>, String> {
        Self::supported_actions(self).await
    }
}

impl DeviceCommonMetadata for AscomCoverCalibratorWrapper {
    async fn interface_version(&self) -> Result<i32, String> {
        Self::interface_version(self).await
    }
    async fn driver_version(&self) -> Result<String, String> {
        Self::driver_version(self).await
    }
    async fn driver_info(&self) -> Result<String, String> {
        Self::driver_info(self).await
    }
    async fn supported_actions(&self) -> Result<Vec<String>, String> {
        Self::supported_actions(self).await
    }
}

impl DeviceCommonMetadata for AscomRotatorWrapper {
    async fn interface_version(&self) -> Result<i32, String> {
        Self::interface_version(self).await
    }
    async fn driver_version(&self) -> Result<String, String> {
        Self::driver_version(self).await
    }
    async fn driver_info(&self) -> Result<String, String> {
        Self::driver_info(self).await
    }
    async fn supported_actions(&self) -> Result<Vec<String>, String> {
        Self::supported_actions(self).await
    }
}

impl DeviceCommonMetadata for AscomSafetyMonitorWrapper {
    async fn interface_version(&self) -> Result<i32, String> {
        Self::interface_version(self).await
    }
    async fn driver_version(&self) -> Result<String, String> {
        Self::driver_version(self).await
    }
    async fn driver_info(&self) -> Result<String, String> {
        Self::driver_info(self).await
    }
    async fn supported_actions(&self) -> Result<Vec<String>, String> {
        Self::supported_actions(self).await
    }
}

impl DeviceCommonMetadata for AscomObservingConditionsWrapper {
    async fn interface_version(&self) -> Result<i32, String> {
        Self::interface_version(self).await
    }
    async fn driver_version(&self) -> Result<String, String> {
        Self::driver_version(self).await
    }
    async fn driver_info(&self) -> Result<String, String> {
        Self::driver_info(self).await
    }
    async fn supported_actions(&self) -> Result<Vec<String>, String> {
        Self::supported_actions(self).await
    }
}
