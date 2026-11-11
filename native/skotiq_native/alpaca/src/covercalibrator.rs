//! Alpaca Cover Calibrator API implementation

use crate::{AlpacaClient, AlpacaDevice, AlpacaDeviceType, AlpacaError};

/// Cover state enum
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoverStatus {
    NotPresent = 0,
    Closed = 1,
    Moving = 2,
    Open = 3,
    Unknown = 4,
    Error = 5,
}

impl From<i32> for CoverStatus {
    fn from(value: i32) -> Self {
        match value {
            0 => CoverStatus::NotPresent,
            1 => CoverStatus::Closed,
            2 => CoverStatus::Moving,
            3 => CoverStatus::Open,
            4 => CoverStatus::Unknown,
            _ => CoverStatus::Error,
        }
    }
}

impl std::fmt::Display for CoverStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CoverStatus::NotPresent => write!(f, "Not Present"),
            CoverStatus::Closed => write!(f, "Closed"),
            CoverStatus::Moving => write!(f, "Moving"),
            CoverStatus::Open => write!(f, "Open"),
            CoverStatus::Unknown => write!(f, "Unknown"),
            CoverStatus::Error => write!(f, "Error"),
        }
    }
}

/// Calibrator state enum
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CalibratorStatus {
    NotPresent = 0,
    Off = 1,
    NotReady = 2,
    Ready = 3,
    Unknown = 4,
    Error = 5,
}

impl From<i32> for CalibratorStatus {
    fn from(value: i32) -> Self {
        match value {
            0 => CalibratorStatus::NotPresent,
            1 => CalibratorStatus::Off,
            2 => CalibratorStatus::NotReady,
            3 => CalibratorStatus::Ready,
            4 => CalibratorStatus::Unknown,
            _ => CalibratorStatus::Error,
        }
    }
}

impl std::fmt::Display for CalibratorStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CalibratorStatus::NotPresent => write!(f, "Not Present"),
            CalibratorStatus::Off => write!(f, "Off"),
            CalibratorStatus::NotReady => write!(f, "Not Ready"),
            CalibratorStatus::Ready => write!(f, "Ready"),
            CalibratorStatus::Unknown => write!(f, "Unknown"),
            CalibratorStatus::Error => write!(f, "Error"),
        }
    }
}

/// Alpaca Cover Calibrator client
pub struct AlpacaCoverCalibrator {
    client: AlpacaClient,
}

impl AlpacaCoverCalibrator {
    /// Create a new Alpaca cover calibrator client
    pub fn new(device: &AlpacaDevice) -> Self {
        assert_eq!(device.device_type, AlpacaDeviceType::CoverCalibrator);
        Self {
            client: AlpacaClient::new(device),
        }
    }

    /// Create from server details
    pub fn from_server(base_url: &str, device_number: u32) -> Self {
        let device =
            AlpacaDevice::from_server(AlpacaDeviceType::CoverCalibrator, base_url, device_number);
        Self::new(&device)
    }

    /// Get access to the underlying client
    pub fn client(&self) -> &AlpacaClient {
        &self.client
    }

    // Connection methods

    pub async fn connect(&self) -> Result<(), AlpacaError> {
        self.client.connect().await
    }

    pub async fn disconnect(&self) -> Result<(), AlpacaError> {
        self.client.disconnect().await
    }

    pub async fn is_connected(&self) -> Result<bool, AlpacaError> {
        self.client.is_connected().await
    }

    // Cover Calibrator information

    pub async fn name(&self) -> Result<String, AlpacaError> {
        self.client.get_name().await
    }

    pub async fn description(&self) -> Result<String, AlpacaError> {
        self.client.get_description().await
    }

    /// Get the driver version string
    pub async fn driver_version(&self) -> Result<String, AlpacaError> {
        self.client.get_driver_version().await
    }

    /// Get the driver info string
    pub async fn driver_info(&self) -> Result<String, AlpacaError> {
        self.client.get_driver_info().await
    }

    /// Get the interface version number
    pub async fn interface_version(&self) -> Result<i32, AlpacaError> {
        self.client.get_interface_version().await
    }

    /// Get the list of supported custom actions
    pub async fn supported_actions(&self) -> Result<Vec<String>, AlpacaError> {
        self.client.get_supported_actions().await
    }

    // Status

    pub async fn cover_state(&self) -> Result<CoverStatus, AlpacaError> {
        let state: i32 = self.client.get("coverstate").await?;
        Ok(CoverStatus::from(state))
    }

    pub async fn calibrator_state(&self) -> Result<CalibratorStatus, AlpacaError> {
        let state: i32 = self.client.get("calibratorstate").await?;
        Ok(CalibratorStatus::from(state))
    }

    pub async fn brightness(&self) -> Result<i32, AlpacaError> {
        self.client.get("brightness").await
    }

    pub async fn max_brightness(&self) -> Result<i32, AlpacaError> {
        self.client.get("maxbrightness").await
    }

    // Cover control

    /// Open cover with typed error handling and long timeout
    pub async fn open_cover(&self) -> Result<(), AlpacaError> {
        self.client.put_long("opencover", &[]).await
    }

    /// Close cover with typed error handling and long timeout
    pub async fn close_cover(&self) -> Result<(), AlpacaError> {
        self.client.put_long("closecover", &[]).await
    }

    pub async fn halt_cover(&self) -> Result<(), AlpacaError> {
        self.client.put("haltcover", &[]).await
    }

    // Calibrator control

    pub async fn calibrator_on(&self, brightness: i32) -> Result<(), AlpacaError> {
        self.client
            .put("calibratoron", &[("Brightness", &brightness.to_string())])
            .await
    }

    pub async fn calibrator_off(&self) -> Result<(), AlpacaError> {
        self.client.put("calibratoroff", &[]).await
    }

    // Wait methods

    /// Get comprehensive cover calibrator status
    pub async fn get_status(&self) -> Result<CoverCalibratorStatus, AlpacaError> {
        let (cover_state, calibrator_state, brightness) = tokio::join!(
            self.cover_state(),
            self.calibrator_state(),
            self.brightness(),
        );

        Ok(CoverCalibratorStatus {
            cover_state: cover_state?,
            calibrator_state: calibrator_state?,
            brightness: brightness.ok(),
        })
    }
}

/// Cover calibrator status aggregate
#[derive(Debug, Clone)]
pub struct CoverCalibratorStatus {
    pub cover_state: CoverStatus,
    pub calibrator_state: CalibratorStatus,
    pub brightness: Option<i32>,
}
