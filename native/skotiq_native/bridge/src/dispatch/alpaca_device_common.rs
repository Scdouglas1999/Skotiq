//! [`DeviceCommonMetadata`] trait implementations for the 10 typed Alpaca
//! wrappers in [`skotiq_alpaca`].
//!
//! The trait and the shared [`fetch_api_version`] helper live in
//! [`crate::dispatch::device_common_metadata`]; this module only contains
//! the per-wrapper delegations.
//!
//! Each impl is a verbatim delegation to the wrapper's existing inherent
//! methods (which all share these exact signatures — Alpaca wrappers were
//! audited and confirmed homogeneous). The methods are NOT renamed on the
//! wrappers — the trait piggy-backs on the existing surface.
//!
//! [`fetch_api_version`]: crate::dispatch::device_common_metadata::fetch_api_version

use crate::dispatch::device_common_metadata::DeviceCommonMetadata;

impl DeviceCommonMetadata for skotiq_alpaca::AlpacaCamera {
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

impl DeviceCommonMetadata for skotiq_alpaca::AlpacaTelescope {
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

impl DeviceCommonMetadata for skotiq_alpaca::AlpacaFocuser {
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

impl DeviceCommonMetadata for skotiq_alpaca::AlpacaFilterWheel {
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

impl DeviceCommonMetadata for skotiq_alpaca::AlpacaRotator {
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

impl DeviceCommonMetadata for skotiq_alpaca::AlpacaDome {
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

impl DeviceCommonMetadata for skotiq_alpaca::AlpacaSafetyMonitor {
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

impl DeviceCommonMetadata for skotiq_alpaca::AlpacaSwitch {
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

impl DeviceCommonMetadata for skotiq_alpaca::AlpacaCoverCalibrator {
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

impl DeviceCommonMetadata for skotiq_alpaca::AlpacaObservingConditions {
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
