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

pub async fn discover_mounts() -> Result<Vec<Lx200MountInfo>, NativeError> {
    serial_link::run_serial_scan("LX200", scan_serial_ports).await
}

pub(crate) fn scan_serial_ports() -> Result<Vec<Lx200MountInfo>, NativeError> {
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
        let name = match port.ask(&PRODUCT_NAME_PROBE) {
            Some(response) => response.trim_end_matches('#').to_string(),
            None => "OnStep Mount".to_string(),
        };

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
        let name = response.trim_end_matches('#').to_string();

        let mount_type = if name.to_lowercase().contains("meade")
            || name.to_lowercase().contains("lx")
        {
            Some(Lx200MountType::Meade)
        } else if name.to_lowercase().contains("gemini") || name.to_lowercase().contains("losmandy")
        {
            Some(Lx200MountType::Losmandy)
        } else if name.to_lowercase().contains("10micron") {
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

fn read_firmware_version(port: &mut ProbedPort<'_>) -> Option<String> {
    let number = optional_discovery_response(port, commands::GET_FIRMWARE_NUMBER);
    let date = optional_discovery_response(port, commands::GET_FIRMWARE_DATE);
    let time = optional_discovery_response(port, commands::GET_FIRMWARE_TIME);
    format_firmware_version(number.as_deref(), date.as_deref(), time.as_deref())
}
