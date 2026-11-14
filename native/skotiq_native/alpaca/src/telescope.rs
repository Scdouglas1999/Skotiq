//! Alpaca Telescope (Mount) API implementation

use crate::AlpacaError;
use skotiq_device::ascom::{AlignmentMode, AxisRate, DriveRate, PierSide, TelescopeAxis};

/// Capability endpoints are optional in practice even when a server exposes
/// the rest of the Telescope API. Treat an explicit not-implemented response
/// (ASCOM `NotImplemented` by number, or a server that has no such endpoint
/// and says so) as `false`, while preserving transport and malformed-response
/// failures.
fn capability_or_unsupported(result: Result<bool, AlpacaError>) -> Result<bool, AlpacaError> {
    match result {
        Ok(value) => Ok(value),
        Err(AlpacaError::DeviceError { code, ref message })
            if matches!(
                skotiq_device::ascom::classify_error_number(code, message),
                Some(skotiq_device::DriverError::NotSupported)
            ) =>
        {
            Ok(false)
        }
        Err(AlpacaError::HttpError { ref message, .. })
            if message.to_ascii_lowercase().contains("not implemented") =>
        {
            Ok(false)
        }
        Err(error) => Err(error),
    }
}

/// Telescope status aggregate for parallel status query
#[derive(Debug, Clone)]
pub struct TelescopeStatus {
    pub connected: bool,
    pub right_ascension: f64,
    pub declination: f64,
    pub altitude: f64,
    pub azimuth: f64,
    pub slewing: bool,
    pub tracking: bool,
    pub tracking_rate: DriveRate,
    pub at_home: bool,
    pub at_park: bool,
    pub side_of_pier: PierSide,
    pub sidereal_time: f64,
}

/// Telescope capabilities for determining what features are available
#[derive(Debug, Clone)]
pub struct TelescopeCapabilities {
    pub can_find_home: bool,
    pub can_park: bool,
    pub can_unpark: bool,
    pub can_set_park: bool,
    pub can_slew: bool,
    pub can_slew_async: bool,
    pub can_slew_alt_az: bool,
    pub can_slew_alt_az_async: bool,
    pub can_sync: bool,
    pub can_sync_alt_az: bool,
    pub can_set_tracking: bool,
    pub can_pulse_guide: bool,
    pub can_set_guide_rates: bool,
}

#[derive(Debug, Clone)]
pub struct TelescopeSiteInfo {
    pub site_latitude: f64,
    pub site_longitude: f64,
    pub site_elevation: f64,
}

#[derive(Debug, Clone)]
pub struct TelescopeOpticsInfo {
    pub aperture_area: Option<f64>,
    pub aperture_diameter: Option<f64>,
    pub focal_length: Option<f64>,
    pub alignment_mode: AlignmentMode,
}

/// Comprehensive telescope status aggregate for parallel status query
/// Includes position, state, target coordinates, and guide rates in a single query
#[derive(Debug, Clone)]
pub struct TelescopeFullStatus {
    pub connected: bool,
    pub right_ascension: f64,
    pub declination: f64,
    pub altitude: f64,
    pub azimuth: f64,
    pub slewing: bool,
    pub tracking: bool,
    pub tracking_rate: DriveRate,
    // (mounts where `CanPulseGuide == false` return error 0x400 / NotImplemented).
    // not pulse-guiding" from "device cannot report pulse-guiding state",
    // matching the ASCOM Windows mount.rs convention. The previous
    // `.unwrap_or(false)` silently coerced both error and parse failures to
    // "not guiding", which the audit flagged as a house-rules violation.
    pub is_pulse_guiding: Option<bool>,
    pub at_home: bool,
    pub at_park: bool,
    pub side_of_pier: PierSide,
    pub sidereal_time: f64,
    // Target coordinates (may not be set)
    pub target_right_ascension: Option<f64>,
    pub target_declination: Option<f64>,
    // Guide rates (may not be supported)
    pub guide_rate_right_ascension: Option<f64>,
    pub guide_rate_declination: Option<f64>,
}

alpaca_device!(AlpacaTelescope, Telescope);

impl AlpacaTelescope {
    skotiq_device::ascom_telescope_members!(alpaca_member);

    /// Permitted `MoveAxis` rates for the given axis (`axisrates`).
    pub async fn axis_rates(&self, axis: TelescopeAxis) -> Result<Vec<AxisRate>, AlpacaError> {
        self.axis_rates_for_axis(axis.as_i32()).await
    }

    /// Get comprehensive telescope status in a single parallel query
    pub async fn get_status(&self) -> Result<TelescopeStatus, AlpacaError> {
        let (
            connected,
            right_ascension,
            declination,
            altitude,
            azimuth,
            slewing,
            tracking,
            tracking_rate,
            at_home,
            at_park,
            side_of_pier,
            sidereal_time,
        ) = tokio::join!(
            self.is_connected(),
            self.right_ascension(),
            self.declination(),
            self.altitude(),
            self.azimuth(),
            self.slewing(),
            self.tracking(),
            self.tracking_rate(),
            self.at_home(),
            self.at_park(),
            self.side_of_pier(),
            self.sidereal_time(),
        );

        Ok(TelescopeStatus {
            connected: connected?,
            right_ascension: right_ascension?,
            declination: declination?,
            altitude: altitude?,
            azimuth: azimuth?,
            slewing: slewing?,
            tracking: tracking?,
            tracking_rate: tracking_rate?,
            at_home: at_home?,
            at_park: at_park?,
            side_of_pier: side_of_pier?,
            sidereal_time: sidereal_time?,
        })
    }

    /// Get telescope capabilities in a single parallel query
    pub async fn get_capabilities(&self) -> Result<TelescopeCapabilities, AlpacaError> {
        let (
            can_find_home,
            can_park,
            can_unpark,
            can_set_park,
            can_slew,
            can_slew_async,
            can_slew_alt_az,
            can_slew_alt_az_async,
            can_sync,
            can_sync_alt_az,
            can_set_tracking,
            can_pulse_guide,
            can_set_guide_rates,
        ) = tokio::join!(
            self.can_find_home(),
            self.can_park(),
            self.can_unpark(),
            self.can_set_park(),
            self.can_slew(),
            self.can_slew_async(),
            self.can_slew_alt_az(),
            self.can_slew_alt_az_async(),
            self.can_sync(),
            self.can_sync_alt_az(),
            self.can_set_tracking(),
            self.can_pulse_guide(),
            self.can_set_guide_rates(),
        );

        Ok(TelescopeCapabilities {
            can_find_home: capability_or_unsupported(can_find_home)?,
            can_park: capability_or_unsupported(can_park)?,
            can_unpark: capability_or_unsupported(can_unpark)?,
            can_set_park: capability_or_unsupported(can_set_park)?,
            can_slew: capability_or_unsupported(can_slew)?,
            can_slew_async: capability_or_unsupported(can_slew_async)?,
            can_slew_alt_az: capability_or_unsupported(can_slew_alt_az)?,
            can_slew_alt_az_async: capability_or_unsupported(can_slew_alt_az_async)?,
            can_sync: capability_or_unsupported(can_sync)?,
            can_sync_alt_az: capability_or_unsupported(can_sync_alt_az)?,
            can_set_tracking: capability_or_unsupported(can_set_tracking)?,
            can_pulse_guide: capability_or_unsupported(can_pulse_guide)?,
            can_set_guide_rates: capability_or_unsupported(can_set_guide_rates)?,
        })
    }

    /// Get site information in a single parallel query
    pub async fn get_site_info(&self) -> Result<TelescopeSiteInfo, AlpacaError> {
        let (site_latitude, site_longitude, site_elevation) = tokio::join!(
            self.site_latitude(),
            self.site_longitude(),
            self.site_elevation(),
        );

        Ok(TelescopeSiteInfo {
            site_latitude: site_latitude?,
            site_longitude: site_longitude?,
            site_elevation: site_elevation?,
        })
    }

    /// Get optics information in a single parallel query
    pub async fn get_optics_info(&self) -> Result<TelescopeOpticsInfo, AlpacaError> {
        let (aperture_area, aperture_diameter, focal_length, alignment_mode) = tokio::join!(
            self.aperture_area(),
            self.aperture_diameter(),
            self.focal_length(),
            self.alignment_mode(),
        );

        Ok(TelescopeOpticsInfo {
            aperture_area: aperture_area.ok(),
            aperture_diameter: aperture_diameter.ok(),
            focal_length: focal_length.ok(),
            alignment_mode: AlignmentMode::from(alignment_mode?),
        })
    }

    /// Get comprehensive telescope status in a single parallel query
    /// This includes position, state, target coordinates, and guide rates
    /// Use this for efficient status polling instead of making multiple individual calls
    pub async fn get_full_status(&self) -> Result<TelescopeFullStatus, AlpacaError> {
        let (
            connected,
            right_ascension,
            declination,
            altitude,
            azimuth,
            slewing,
            tracking,
            tracking_rate,
            is_pulse_guiding,
            at_home,
            at_park,
            side_of_pier,
            sidereal_time,
            target_right_ascension,
            target_declination,
            guide_rate_right_ascension,
            guide_rate_declination,
        ) = tokio::join!(
            self.is_connected(),
            self.right_ascension(),
            self.declination(),
            self.altitude(),
            self.azimuth(),
            self.slewing(),
            self.tracking(),
            self.tracking_rate(),
            self.is_pulse_guiding(),
            self.at_home(),
            self.at_park(),
            self.side_of_pier(),
            self.sidereal_time(),
            self.target_right_ascension(),
            self.target_declination(),
            self.guide_rate_right_ascension(),
            self.guide_rate_declination(),
        );

        Ok(TelescopeFullStatus {
            // Connection state - critical
            connected: connected?,
            // Current position - critical
            right_ascension: right_ascension?,
            declination: declination?,
            altitude: altitude?,
            azimuth: azimuth?,
            // Motion state - critical
            slewing: slewing?,
            tracking: tracking?,
            tracking_rate: tracking_rate?,
            // Why: surface unsupported/parse failures as `None`
            // rather than silently reporting "not pulse-guiding".
            is_pulse_guiding: is_pulse_guiding.ok(),
            // Position state - critical
            at_home: at_home?,
            at_park: at_park?,
            side_of_pier: side_of_pier?,
            // Time - critical
            sidereal_time: sidereal_time?,
            // Target coordinates - may not be set if no target
            target_right_ascension: target_right_ascension.ok(),
            target_declination: target_declination.ok(),
            // Guide rates - may not be supported by all mounts
            guide_rate_right_ascension: guide_rate_right_ascension.ok(),
            guide_rate_declination: guide_rate_declination.ok(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[test]
    fn unsupported_capability_is_false_without_masking_other_errors() {
        let not_implemented = AlpacaError::HttpError {
            status: 400,
            message: "Method not implemented: canfindhome".to_string(),
            retry_after: None,
        };
        assert_eq!(
            not_implemented.to_string(),
            "HTTP error 400: Method not implemented: canfindhome"
        );
        assert!(matches!(
            capability_or_unsupported(Err(not_implemented)),
            Ok(false)
        ));
        let refused = AlpacaError::connection_refused("http://127.0.0.1:1", "connection refused");
        assert!(capability_or_unsupported(Err(refused)).is_err());
        // The ASCOM number decides, whatever words the driver chose.
        let by_number = AlpacaError::DeviceError {
            code: 0x400,
            message: "Property CanSetPark is not available in this driver".to_string(),
        };
        assert!(matches!(
            capability_or_unsupported(Err(by_number)),
            Ok(false)
        ));
        let not_connected = AlpacaError::DeviceError {
            code: 0x407,
            message: "not implemented while disconnected".to_string(),
        };
        assert!(capability_or_unsupported(Err(not_connected)).is_err());
    }

    async fn serve_alpaca_response(
        body: &'static str,
    ) -> (String, tokio::task::JoinHandle<String>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind fake Alpaca telescope server");
        let port = listener.local_addr().expect("read listener address").port();
        let base_url = format!("http://127.0.0.1:{port}");

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept client");
            let mut buf = vec![0_u8; 4096];
            let n = socket.read(&mut buf).await.expect("read request");
            let request = String::from_utf8_lossy(&buf[..n]).to_string();
            let request_line = request.lines().next().unwrap_or_default().to_string();
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            socket
                .write_all(response.as_bytes())
                .await
                .expect("write response");
            request_line
        });

        (base_url, server)
    }

    #[tokio::test]
    async fn tracking_rates_reads_alpaca_endpoint() {
        let body = "{\"Value\":[0,1,2],\"ClientTransactionID\":0,\"ServerTransactionID\":1,\"ErrorNumber\":0,\"ErrorMessage\":\"\"}";
        let (base_url, server) = serve_alpaca_response(body).await;
        let telescope = AlpacaTelescope::from_server(&base_url, 0);

        let rates = telescope
            .tracking_rates()
            .await
            .expect("read tracking rates");

        assert_eq!(
            rates,
            vec![DriveRate::Sidereal, DriveRate::Lunar, DriveRate::Solar]
        );
        let request_line = server.await.expect("fake server should finish");
        assert!(
            request_line.starts_with("GET /api/v1/telescope/0/trackingrates?"),
            "unexpected trackingrates request: {}",
            request_line
        );
    }

    #[tokio::test]
    async fn axis_rates_sends_axis_query_parameter() {
        let body = "{\"Value\":[{\"Minimum\":0.1,\"Maximum\":2.5}],\"ClientTransactionID\":0,\"ServerTransactionID\":1,\"ErrorNumber\":0,\"ErrorMessage\":\"\"}";
        let (base_url, server) = serve_alpaca_response(body).await;
        let telescope = AlpacaTelescope::from_server(&base_url, 0);

        let rates = telescope
            .axis_rates(TelescopeAxis::Secondary)
            .await
            .expect("read axis rates");

        assert_eq!(
            rates,
            vec![AxisRate {
                minimum: 0.1,
                maximum: 2.5
            }]
        );
        let request_line = server.await.expect("fake server should finish");
        assert!(
            request_line.starts_with("GET /api/v1/telescope/0/axisrates?"),
            "unexpected axisrates request: {}",
            request_line
        );
        assert!(
            request_line.contains("Axis=1"),
            "axisrates request must include requested axis: {}",
            request_line
        );
    }
}
