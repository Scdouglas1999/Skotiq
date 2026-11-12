//! LX200 serial mount discovery.

use super::*;

pub struct Lx200MountInfo {
    pub port: String,
    pub name: String,
    pub mount_type: Lx200MountType,
    pub firmware_version: Option<String>,
    /// Baud rate that was successful during discovery
    pub baud_rate: u32,
}

pub async fn discover_mounts() -> Result<Vec<Lx200MountInfo>, DriverError> {
    serial_link::run_serial_scan("LX200", scan_serial_ports).await
}

pub(crate) fn scan_serial_ports() -> Result<Vec<Lx200MountInfo>, DriverError> {
    serial_link::scan_ports(&SCAN_PLAN, identify_mount)
}

/// The same scan over ports a test supplies.
#[cfg(all(test, target_os = "linux"))]
pub(crate) fn scan_port_list(ports: Vec<serialport::SerialPortInfo>) -> Vec<Lx200MountInfo> {
    serial_link::scan_port_list(&SCAN_PLAN, ports, identify_mount)
}

const ONSTEP_STATUS_PROBE: Probe<'static> = probe(commands::ONSTEP_GET_STATUS, 32);
const PRODUCT_NAME_PROBE: Probe<'static> = probe(commands::GET_PRODUCT_NAME, 64);
const RA_PROBE: Probe<'static> = probe(commands::GET_RA, 32);

/// Three questions, most specific first: the OnStep status (Pegasus NYX and
/// other OnStep mounts), the product name, and last a bare RA read for
/// compatible mounts that answer neither.
fn identify_mount(port: &mut ProbedPort<'_>) -> Option<Lx200MountInfo> {
    // OnStep answers `:GU#` with a short string of status flags ending in `#`.
    let is_onstep = match port.ask(&ONSTEP_STATUS_PROBE) {
        Some(response) => {
            let trimmed = response.trim();
            tracing::debug!(
                "OnStep detection response from {} at {} baud: {:?}",
                port.name,
                port.baud_rate,
                trimmed
            );
            trimmed.ends_with('#') && trimmed.len() >= 2 && trimmed.len() <= 30
        }
        None => false,
    };

    if is_onstep {
        let name = port
            .ask(&PRODUCT_NAME_PROBE)
            .map(|response| reply_text(&response))
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| "OnStep Mount".to_string());

        let display_name =
            if name.to_lowercase().contains("pegasus") || name.to_lowercase().contains("nyx") {
                format!("Pegasus {} ({})", name, port.name)
            } else if name.to_lowercase().contains("onstep") {
                format!("{} ({})", name, port.name)
            } else {
                format!("OnStep: {} ({})", name, port.name)
            };
        let firmware_version = read_firmware_version(port);

        tracing::info!(
            "Found OnStep mount on {} at {} baud: {}",
            port.name,
            port.baud_rate,
            display_name
        );
        return Some(Lx200MountInfo {
            port: port.name.to_string(),
            name: display_name,
            mount_type: Lx200MountType::OnStep,
            firmware_version,
            baud_rate: port.baud_rate,
        });
    }

    if let Some(response) = port.ask(&PRODUCT_NAME_PROBE) {
        let name = reply_text(&response);
        let lower = name.to_lowercase();

        // Meade's own handsets answer `Autostar` (ETX, LX90 and LXD mounts)
        // or an `LX` model name.
        let mount_type = if lower.contains("meade") || lower.contains("lx") || lower.contains("autostar")
        {
            Some(Lx200MountType::Meade)
        } else if lower.contains("gemini") || lower.contains("losmandy") {
            Some(Lx200MountType::Losmandy)
        } else if lower.contains("10micron") {
            Some(Lx200MountType::TenMicron)
        } else if !name.is_empty() && name != "\0" && name.chars().any(|c| c.is_alphanumeric()) {
            Some(Lx200MountType::Generic)
        } else {
            None
        };

        if let Some(mount_type) = mount_type {
            let display_name = format!("{} ({})", name, port.name);
            let firmware_version = read_firmware_version(port);
            tracing::info!(
                "Found LX200 mount on {} at {} baud: {}",
                port.name,
                port.baud_rate,
                display_name
            );
            return Some(Lx200MountInfo {
                port: port.name.to_string(),
                name: display_name,
                mount_type,
                firmware_version,
                baud_rate: port.baud_rate,
            });
        }
    }

    let response = port.ask(&RA_PROBE)?;
    if !(response.contains(':') && response.ends_with('#')) {
        return None;
    }
    tracing::info!(
        "Found generic LX200 mount on {} at {} baud",
        port.name,
        port.baud_rate
    );
    Some(Lx200MountInfo {
        port: port.name.to_string(),
        name: format!("LX200 Compatible ({})", port.name),
        mount_type: Lx200MountType::Generic,
        firmware_version: None,
        baud_rate: port.baud_rate,
    })
}

/// A probe reply without its `#` and the line end some firmware sends after
/// it (the NYX-101 follows every reply with CRLF).
fn reply_text(response: &str) -> String {
    response
        .trim_matches(|c: char| c.is_whitespace() || c == '\0')
        .trim_end_matches('#')
        .trim()
        .to_string()
}

fn read_firmware_version(port: &mut ProbedPort<'_>) -> Option<String> {
    let number = optional_discovery_response(port, commands::GET_FIRMWARE_NUMBER);
    let date = optional_discovery_response(port, commands::GET_FIRMWARE_DATE);
    let time = optional_discovery_response(port, commands::GET_FIRMWARE_TIME);
    format_firmware_version(number.as_deref(), date.as_deref(), time.as_deref())
}
