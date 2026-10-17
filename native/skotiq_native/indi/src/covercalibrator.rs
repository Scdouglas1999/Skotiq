//! INDI Cover Calibrator wrapper
//!
//! Provides high-level flat panel / dust cover control via INDI protocol.
//! Supports various INDI flat panel implementations including:
//! - Dust cap control (CAP_PARK, DUST_CAP, DUSTCAP_CONTROL)
//! - Flat light control (FLAT_LIGHT_CONTROL)
//! - Flat cover state readback (FLAT_COVER_STATE)
//! - Brightness control (FLAT_LIGHT_INTENSITY, LIGHTBOX_BRIGHTNESS)
//!
//! # `unwrap_or(false)` policy
//!
//! `IndiClient::get_switch` returns `Result<Option<bool>, IndiError>`; an
//! `Err`/`None` means the INDI background reader has not yet streamed the
//! property/element pair, the driver does not implement that alternative
//! (e.g. `DUSTCAP_CONTROL` on a panel that only supports `CAP_PARK`), or the
//! pair has not been defined by the device. The probe loop tries every known
//! INDI cover/calibrator vocabulary in turn and falls back to
//! `IndiCoverState::Unknown` / `IndiCalibratorState::Unknown` when nothing
//! resolves — `unwrap_or(false)` here is the semantically-correct
//! "skip-this-alternative" signal, matching the precedent in
//! `bridge/src/dispatch/indi.rs:148`.

use crate::client::IndiClient;
use crate::error::IndiResult;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Cover state for INDI cover calibrators
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndiCoverState {
    /// Device does not have a cover
    NotPresent,
    /// Cover is closed/parked
    Closed,
    /// Cover is moving
    Moving,
    /// Cover is open/unparked
    Open,
    /// Cover state is unknown
    Unknown,
    /// Error condition
    Error,
}

impl IndiCoverState {
    /// Convert to ASCOM-compatible integer value
    pub fn to_i32(&self) -> i32 {
        match self {
            IndiCoverState::NotPresent => 0,
            IndiCoverState::Closed => 1,
            IndiCoverState::Moving => 2,
            IndiCoverState::Open => 3,
            IndiCoverState::Unknown => 4,
            IndiCoverState::Error => 5,
        }
    }
}

/// Calibrator state for INDI cover calibrators
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndiCalibratorState {
    /// Device does not have a calibrator/light
    NotPresent,
    /// Calibrator is off
    Off,
    /// Calibrator is stabilizing
    NotReady,
    /// Calibrator is on and ready
    Ready,
    /// Calibrator state is unknown
    Unknown,
    /// Error condition
    Error,
}

impl IndiCalibratorState {
    /// Convert to ASCOM-compatible integer value
    pub fn to_i32(&self) -> i32 {
        match self {
            IndiCalibratorState::NotPresent => 0,
            IndiCalibratorState::Off => 1,
            IndiCalibratorState::NotReady => 2,
            IndiCalibratorState::Ready => 3,
            IndiCalibratorState::Unknown => 4,
            IndiCalibratorState::Error => 5,
        }
    }
}

/// INDI Cover Calibrator device wrapper
pub struct IndiCoverCalibrator {
    client: Arc<RwLock<IndiClient>>,
    device_name: String,
}

impl IndiCoverCalibrator {
    /// Create a new INDI cover calibrator wrapper
    pub fn new(client: Arc<RwLock<IndiClient>>, device_name: &str) -> Self {
        Self {
            client,
            device_name: device_name.to_string(),
        }
    }

    /// Get the device name
    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    // Connection

    /// Connect to the cover calibrator
    pub async fn connect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.connect_device(&self.device_name).await
    }

    /// Disconnect from the cover calibrator
    pub async fn disconnect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.disconnect_device(&self.device_name).await
    }

    /// Check if connected
    pub async fn is_connected(&self) -> bool {
        let client = self.client.read().await;
        client.is_device_connected(&self.device_name).await
    }

    // Cover control (Dust Cap)

    /// Open the cover (unpark dust cap)
    pub async fn open_cover(&self) -> Result<(), String> {
        let mut client = self.client.write().await;

        // Try CAP_PARK first (common INDI standard)
        if set_switch_when_defined(&mut client, &self.device_name, "CAP_PARK", "UNPARK").await? {
            return Ok(());
        }

        // Try DUST_CAP variants used by some flat panels
        for element in ["CAP_UNPARK", "UNPARK", "OPEN", "DUST_CAP_OPEN"] {
            if set_switch_when_defined(&mut client, &self.device_name, "DUST_CAP", element).await? {
                return Ok(());
            }
        }

        // Try DUSTCAP_CONTROL alternative
        if set_switch_when_defined(&mut client, &self.device_name, "DUSTCAP_CONTROL", "OPEN")
            .await?
        {
            return Ok(());
        }

        // Try LIGHTBOX_CONTROL alternative (Pegasus FlatMaster and similar
        // integrated lightbox-with-shutter devices expose a single switch
        // vector with OPEN / CLOSE elements).
        if set_switch_when_defined(&mut client, &self.device_name, "LIGHTBOX_CONTROL", "OPEN")
            .await?
        {
            return Ok(());
        }

        Err("No compatible cover control property found".to_string())
    }

    /// Close the cover (park dust cap)
    pub async fn close_cover(&self) -> Result<(), String> {
        let mut client = self.client.write().await;

        // Try CAP_PARK first (common INDI standard)
        if set_switch_when_defined(&mut client, &self.device_name, "CAP_PARK", "PARK").await? {
            return Ok(());
        }

        // Try DUST_CAP variants used by some flat panels
        for element in ["CAP_PARK", "PARK", "CLOSE", "CLOSED", "DUST_CAP_CLOSE"] {
            if set_switch_when_defined(&mut client, &self.device_name, "DUST_CAP", element).await? {
                return Ok(());
            }
        }

        // Try DUSTCAP_CONTROL alternative
        if set_switch_when_defined(&mut client, &self.device_name, "DUSTCAP_CONTROL", "CLOSE")
            .await?
        {
            return Ok(());
        }

        // Try LIGHTBOX_CONTROL alternative — see open_cover() for the
        // Pegasus FlatMaster rationale.
        if set_switch_when_defined(&mut client, &self.device_name, "LIGHTBOX_CONTROL", "CLOSE")
            .await?
        {
            return Ok(());
        }

        Err("No compatible cover control property found".to_string())
    }

    /// Halt cover movement (abort)
    pub async fn halt_cover(&self) -> Result<(), String> {
        let mut client = self.client.write().await;

        // Try standard abort property
        if set_switch_when_defined(&mut client, &self.device_name, "CAP_ABORT", "ABORT").await? {
            return Ok(());
        }

        // Some devices use generic abort
        if set_switch_when_defined(&mut client, &self.device_name, "ABORT", "ABORT").await? {
            return Ok(());
        }

        if set_switch_when_defined(&mut client, &self.device_name, "DUST_CAP", "ABORT").await? {
            return Ok(());
        }

        Err("No compatible cover abort property found".to_string())
    }

    /// Get cover state
    pub async fn get_cover_state(&self) -> IndiCoverState {
        let client = self.client.read().await;

        // Check CAP_PARK property
        let is_parked = client
            .get_switch(&self.device_name, "CAP_PARK", "PARK")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → try next vocabulary.
            .unwrap_or(false);
        let is_unparked = client
            .get_switch(&self.device_name, "CAP_PARK", "UNPARK")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → try next vocabulary.
            .unwrap_or(false);

        // Check if property is busy (moving)
        if client.is_property_busy(&self.device_name, "CAP_PARK").await {
            return IndiCoverState::Moving;
        }

        if is_parked && !is_unparked {
            return IndiCoverState::Closed;
        }
        if is_unparked && !is_parked {
            return IndiCoverState::Open;
        }

        // Try DUST_CAP alternative
        for property in ["DUST_CAP", "DUSTCAP_CONTROL"] {
            if client.is_property_busy(&self.device_name, property).await {
                return IndiCoverState::Moving;
            }

            if switch_any_on(
                &client,
                &self.device_name,
                property,
                &["CAP_PARK", "PARK", "CLOSE", "CLOSED", "DUST_CAP_CLOSED"],
            )
            .await
            .unwrap_or(false)
            {
                return IndiCoverState::Closed;
            }
            if switch_any_on(
                &client,
                &self.device_name,
                property,
                &["CAP_UNPARK", "UNPARK", "OPEN", "DUST_CAP_OPEN"],
            )
            .await
            .unwrap_or(false)
            {
                return IndiCoverState::Open;
            }
        }

        if client
            .is_property_busy(&self.device_name, "FLAT_COVER_STATE")
            .await
        {
            return IndiCoverState::Moving;
        }
        if switch_any_on(
            &client,
            &self.device_name,
            "FLAT_COVER_STATE",
            &["FLAT_COVER_CLOSED", "COVER_CLOSED", "CLOSED", "PARKED"],
        )
        .await
        .unwrap_or(false)
        {
            return IndiCoverState::Closed;
        }
        if switch_any_on(
            &client,
            &self.device_name,
            "FLAT_COVER_STATE",
            &["FLAT_COVER_OPEN", "COVER_OPEN", "OPEN", "UNPARKED"],
        )
        .await
        .unwrap_or(false)
        {
            return IndiCoverState::Open;
        }
        if switch_any_on(
            &client,
            &self.device_name,
            "FLAT_COVER_STATE",
            &["FLAT_COVER_MOVING", "COVER_MOVING", "MOVING"],
        )
        .await
        .unwrap_or(false)
        {
            return IndiCoverState::Moving;
        }
        if switch_any_on(
            &client,
            &self.device_name,
            "FLAT_COVER_STATE",
            &["FLAT_COVER_ERROR", "COVER_ERROR", "ERROR"],
        )
        .await
        .unwrap_or(false)
        {
            return IndiCoverState::Error;
        }

        // Try DUSTCAP_CONTROL alternative
        let is_closed = client
            .get_switch(&self.device_name, "DUSTCAP_CONTROL", "CLOSE")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → try next vocabulary.
            .unwrap_or(false);
        let is_open = client
            .get_switch(&self.device_name, "DUSTCAP_CONTROL", "OPEN")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → try next vocabulary.
            .unwrap_or(false);

        if client
            .is_property_busy(&self.device_name, "DUSTCAP_CONTROL")
            .await
        {
            return IndiCoverState::Moving;
        }

        if is_closed && !is_open {
            return IndiCoverState::Closed;
        }
        if is_open && !is_closed {
            return IndiCoverState::Open;
        }

        // Try LIGHTBOX_CONTROL alternative (Pegasus FlatMaster and similar
        // integrated lightbox-with-shutter devices). Single switch vector
        // with OPEN / CLOSE elements.
        let lb_closed = client
            .get_switch(&self.device_name, "LIGHTBOX_CONTROL", "CLOSE")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → try next vocabulary.
            .unwrap_or(false);
        let lb_open = client
            .get_switch(&self.device_name, "LIGHTBOX_CONTROL", "OPEN")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → try next vocabulary.
            .unwrap_or(false);

        if client
            .is_property_busy(&self.device_name, "LIGHTBOX_CONTROL")
            .await
        {
            return IndiCoverState::Moving;
        }

        if lb_closed && !lb_open {
            return IndiCoverState::Closed;
        }
        if lb_open && !lb_closed {
            return IndiCoverState::Open;
        }

        // Check if cover properties exist at all
        let properties = client.get_properties(&self.device_name).await;
        let has_cover = properties.iter().any(|p| {
            p.name == "CAP_PARK"
                || p.name == "DUST_CAP"
                || p.name == "DUSTCAP_CONTROL"
                || p.name == "FLAT_COVER_STATE"
                || p.name == "LIGHTBOX_CONTROL"
        });

        if has_cover {
            IndiCoverState::Unknown
        } else {
            IndiCoverState::NotPresent
        }
    }

    // Calibrator control (Flat Light)

    /// Turn on the calibrator light at specified brightness
    pub async fn calibrator_on(&self, brightness: i32) -> Result<(), String> {
        let mut client = self.client.write().await;

        // Set brightness first if supported
        if brightness > 0 {
            // Try FLAT_LIGHT_INTENSITY
            let _ = set_number_when_defined(
                &mut client,
                &self.device_name,
                "FLAT_LIGHT_INTENSITY",
                "FLAT_LIGHT_INTENSITY_VALUE",
                // Why: i32 brightness -> f64 (INDI wire); lossless.
                f64::from(brightness),
            )
            .await?;

            // Try LIGHTBOX_BRIGHTNESS alternative
            let _ = set_number_when_defined(
                &mut client,
                &self.device_name,
                "LIGHTBOX_BRIGHTNESS",
                "BRIGHTNESS",
                // Why: i32 brightness -> f64 (INDI wire); lossless.
                f64::from(brightness),
            )
            .await?;
        }

        // Turn on the light
        // Try FLAT_LIGHT_CONTROL first
        if set_switch_when_defined(
            &mut client,
            &self.device_name,
            "FLAT_LIGHT_CONTROL",
            "FLAT_LIGHT_ON",
        )
        .await?
        {
            return Ok(());
        }

        // Try LIGHTBOX_BRIGHTNESS (setting to non-zero turns it on)
        if set_number_when_defined(
            &mut client,
            &self.device_name,
            "LIGHTBOX_BRIGHTNESS",
            "BRIGHTNESS",
            // Why: i32 brightness clamped to >= 1, -> f64 (INDI wire); lossless.
            f64::from(brightness.max(1)),
        )
        .await?
        {
            return Ok(());
        }

        Err("No compatible calibrator control property found".to_string())
    }

    /// Turn off the calibrator light
    pub async fn calibrator_off(&self) -> Result<(), String> {
        let mut client = self.client.write().await;

        // Try FLAT_LIGHT_CONTROL first
        if set_switch_when_defined(
            &mut client,
            &self.device_name,
            "FLAT_LIGHT_CONTROL",
            "FLAT_LIGHT_OFF",
        )
        .await?
        {
            return Ok(());
        }

        // Try setting brightness to 0
        if set_number_when_defined(
            &mut client,
            &self.device_name,
            "FLAT_LIGHT_INTENSITY",
            "FLAT_LIGHT_INTENSITY_VALUE",
            0.0,
        )
        .await?
        {
            return Ok(());
        }

        // Try LIGHTBOX_BRIGHTNESS alternative
        if set_number_when_defined(
            &mut client,
            &self.device_name,
            "LIGHTBOX_BRIGHTNESS",
            "BRIGHTNESS",
            0.0,
        )
        .await?
        {
            return Ok(());
        }

        Err("No compatible calibrator control property found".to_string())
    }

    /// Get calibrator state
    pub async fn get_calibrator_state(&self) -> IndiCalibratorState {
        let client = self.client.read().await;

        // Check FLAT_LIGHT_CONTROL property
        let is_on = client
            .get_switch(&self.device_name, "FLAT_LIGHT_CONTROL", "FLAT_LIGHT_ON")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → try next vocabulary.
            .unwrap_or(false);
        let is_off = client
            .get_switch(&self.device_name, "FLAT_LIGHT_CONTROL", "FLAT_LIGHT_OFF")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → try next vocabulary.
            .unwrap_or(false);

        // Check if property is busy (stabilizing)
        if client
            .is_property_busy(&self.device_name, "FLAT_LIGHT_CONTROL")
            .await
        {
            return IndiCalibratorState::NotReady;
        }

        if is_on && !is_off {
            return IndiCalibratorState::Ready;
        }
        if is_off && !is_on {
            return IndiCalibratorState::Off;
        }

        // Check brightness-based control
        if let Some(brightness) = client
            .get_number(
                &self.device_name,
                "FLAT_LIGHT_INTENSITY",
                "FLAT_LIGHT_INTENSITY_VALUE",
            )
            .await
        {
            if brightness > 0.0 {
                return IndiCalibratorState::Ready;
            } else {
                return IndiCalibratorState::Off;
            }
        }

        // Check LIGHTBOX_BRIGHTNESS alternative
        if let Some(brightness) = client
            .get_number(&self.device_name, "LIGHTBOX_BRIGHTNESS", "BRIGHTNESS")
            .await
        {
            if brightness > 0.0 {
                return IndiCalibratorState::Ready;
            } else {
                return IndiCalibratorState::Off;
            }
        }

        // Check if calibrator properties exist at all
        let properties = client.get_properties(&self.device_name).await;
        let has_calibrator = properties.iter().any(|p| {
            p.name == "FLAT_LIGHT_CONTROL"
                || p.name == "FLAT_LIGHT_INTENSITY"
                || p.name == "LIGHTBOX_BRIGHTNESS"
        });

        if has_calibrator {
            IndiCalibratorState::Unknown
        } else {
            IndiCalibratorState::NotPresent
        }
    }

    // Brightness control

    /// Get current brightness (0-max)
    pub async fn get_brightness(&self) -> Result<i32, String> {
        let client = self.client.read().await;

        // Try FLAT_LIGHT_INTENSITY
        if let Some(brightness) = client
            .get_number(
                &self.device_name,
                "FLAT_LIGHT_INTENSITY",
                "FLAT_LIGHT_INTENSITY_VALUE",
            )
            .await
        {
            // Why: INDI wire f64 -> i32 brightness. Real brightness values are
            // 0..255 typical; f64 -> i32 saturates per Rust 1.45 spec.
            return Ok(brightness as i32);
        }

        // Try LIGHTBOX_BRIGHTNESS alternative
        if let Some(brightness) = client
            .get_number(&self.device_name, "LIGHTBOX_BRIGHTNESS", "BRIGHTNESS")
            .await
        {
            // Why: INDI wire f64 -> i32 brightness. Real brightness values are
            // 0..255 typical; f64 -> i32 saturates per Rust 1.45 spec.
            return Ok(brightness as i32);
        }

        Err("Brightness property not available".to_string())
    }

    /// Set brightness (0-max)
    pub async fn set_brightness(&self, brightness: i32) -> Result<(), String> {
        let mut client = self.client.write().await;

        // Try FLAT_LIGHT_INTENSITY
        if set_number_when_defined(
            &mut client,
            &self.device_name,
            "FLAT_LIGHT_INTENSITY",
            "FLAT_LIGHT_INTENSITY_VALUE",
            // Why: i32 brightness -> f64 (INDI wire); lossless.
            f64::from(brightness),
        )
        .await?
        {
            return Ok(());
        }

        // Try LIGHTBOX_BRIGHTNESS alternative
        if set_number_when_defined(
            &mut client,
            &self.device_name,
            "LIGHTBOX_BRIGHTNESS",
            "BRIGHTNESS",
            // Why: i32 brightness -> f64 (INDI wire); lossless.
            f64::from(brightness),
        )
        .await?
        {
            return Ok(());
        }

        Err("Brightness property not available".to_string())
    }

    /// Get maximum brightness
    pub async fn get_max_brightness(&self) -> Result<i32, String> {
        let client = self.client.read().await;

        if let Some(limits) = client
            .get_number_limits(
                &self.device_name,
                "FLAT_LIGHT_INTENSITY",
                "FLAT_LIGHT_INTENSITY_VALUE",
            )
            .await
        {
            if let Some(max) = limits.max {
                // Why: INDI wire f64 -> i32 max brightness; f64 -> i32 saturates per Rust 1.45.
                return Ok(max.round() as i32);
            }
        }

        if let Some(limits) = client
            .get_number_limits(&self.device_name, "LIGHTBOX_BRIGHTNESS", "BRIGHTNESS")
            .await
        {
            if let Some(max) = limits.max {
                // Why: INDI wire f64 -> i32 max brightness; f64 -> i32 saturates per Rust 1.45.
                return Ok(max.round() as i32);
            }
        }

        Err("Brightness property limits not available".to_string())
    }
}

async fn switch_any_on(
    client: &IndiClient,
    device_name: &str,
    property: &str,
    elements: &[&str],
) -> Option<bool> {
    let mut saw_element = false;
    for element in elements {
        if let Some(is_on) = client.get_switch(device_name, property, element).await {
            saw_element = true;
            if is_on {
                return Some(true);
            }
        }
    }
    saw_element.then_some(false)
}

async fn set_switch_when_defined(
    client: &mut IndiClient,
    device_name: &str,
    property: &str,
    element: &str,
) -> Result<bool, String> {
    if !client.has_property(device_name, property).await {
        return Ok(false);
    }
    client
        .set_switch(device_name, property, element, true)
        .await
        .map(|_| true)
        .map_err(|e| e.to_string())
}

async fn set_number_when_defined(
    client: &mut IndiClient,
    device_name: &str,
    property: &str,
    element: &str,
    value: f64,
) -> Result<bool, String> {
    if !client.has_property(device_name, property).await {
        return Ok(false);
    }
    client
        .set_number(device_name, property, element, value)
        .await
        .map(|_| true)
        .map_err(|e| e.to_string())
}
