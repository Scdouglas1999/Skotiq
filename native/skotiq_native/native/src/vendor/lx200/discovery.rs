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
    crate::vendor::run_serial_scan("LX200", scan_serial_ports).await
}

pub(crate) fn scan_serial_ports() -> Result<Vec<Lx200MountInfo>, NativeError> {
    let mut mounts = Vec::new();

    let ports = serialport::available_ports()
        .map_err(|e| NativeError::SdkError(format!("Failed to enumerate ports: {}", e)))?;

    tracing::info!(
        "LX200 discovery: found {} serial ports to scan",
        ports.len()
    );

    for port_info in ports {
        let port_name = port_info.port_name.clone();

        // Log port info for debugging
        let port_type = match &port_info.port_type {
            serialport::SerialPortType::UsbPort(usb) => {
                format!(
                    "USB (VID:{:04X} PID:{:04X} {})",
                    usb.vid,
                    usb.pid,
                    usb.product.as_deref().unwrap_or("unknown")
                )
            }
            serialport::SerialPortType::PciPort => "PCI".to_string(),
            serialport::SerialPortType::BluetoothPort => "Bluetooth".to_string(),
            serialport::SerialPortType::Unknown => "Unknown".to_string(),
        };
        tracing::debug!("Checking port {} ({})", port_name, port_type);

        // Try multiple baud rates - modern mounts like Pegasus NYX use 115200
        let mut found_mount = false;
        for &baud_rate in DISCOVERY_BAUD_RATES {
            if found_mount {
                break;
            }

            tracing::debug!("Trying {} at {} baud", port_name, baud_rate);

            let result = serialport::new(&port_name, baud_rate)
                .timeout(Duration::from_millis(500))
                .open();

            match result {
                Err(e) => {
                    // Common on Windows: port is busy/locked by another app (e.g., ASCOM driver)
                    let msg = e.to_string();
                    let is_access_denied = msg.contains("Access is denied")
                        || msg.contains("access is denied")
                        || msg.contains("Permission denied")
                        || msg.contains("permission denied");

                    if is_access_denied {
                        tracing::debug!(
                            "Port {} is locked by another application (possibly ASCOM driver) - skipping LX200 scan",
                            port_name
                        );
                    } else {
                        tracing::debug!(
                            "Could not open port {} at {} baud for LX200 detection: {}",
                            port_name,
                            baud_rate,
                            msg
                        );
                    }
                    // If we can't open at any baud rate, skip to next port
                    break;
                }
                Ok(mut port) => {
                    // First, try OnStep status command to detect OnStep-based mounts (Pegasus NYX, etc.)
                    // OnStep responds to :GU# with a status string like "nNpPHT..." or similar flags
                    let is_onstep = if port
                        .write_all(commands::ONSTEP_GET_STATUS.as_bytes())
                        .is_ok()
                    {
                        let _ = port.flush();
                        let mut buf = [0u8; 32];
                        std::thread::sleep(Duration::from_millis(200));

                        if let Ok(n) = port.read(&mut buf) {
                            let response = String::from_utf8_lossy(&buf[..n]);
                            let trimmed = response.trim();
                            tracing::debug!(
                                "OnStep detection response from {} at {} baud: {:?}",
                                port_name,
                                baud_rate,
                                trimmed
                            );
                            // OnStep status ends with # and has some content
                            // Be more permissive - just check it ends with # and has reasonable length
                            trimmed.ends_with('#') && trimmed.len() >= 2 && trimmed.len() <= 30
                        } else {
                            false
                        }
                    } else {
                        false
                    };

                    if is_onstep {
                        // Get product name for display
                        let name = if port
                            .write_all(commands::GET_PRODUCT_NAME.as_bytes())
                            .is_ok()
                        {
                            let _ = port.flush();
                            let mut buf = [0u8; 64];
                            std::thread::sleep(Duration::from_millis(200));

                            if let Ok(n) = port.read(&mut buf) {
                                let response = String::from_utf8_lossy(&buf[..n]);
                                response.trim_end_matches('#').to_string()
                            } else {
                                "OnStep Mount".to_string()
                            }
                        } else {
                            "OnStep Mount".to_string()
                        };

                        // Check if it's a Pegasus NYX specifically
                        let display_name = if name.to_lowercase().contains("pegasus")
                            || name.to_lowercase().contains("nyx")
                        {
                            format!("Pegasus {} ({})", name, port_name)
                        } else if name.to_lowercase().contains("onstep") {
                            format!("{} ({})", name, port_name)
                        } else {
                            format!("OnStep: {} ({})", name, port_name)
                        };
                        let firmware_number =
                            optional_discovery_response(&mut *port, commands::GET_FIRMWARE_NUMBER);
                        let firmware_date =
                            optional_discovery_response(&mut *port, commands::GET_FIRMWARE_DATE);
                        let firmware_time =
                            optional_discovery_response(&mut *port, commands::GET_FIRMWARE_TIME);
                        let firmware_version = format_firmware_version(
                            firmware_number.as_deref(),
                            firmware_date.as_deref(),
                            firmware_time.as_deref(),
                        );

                        mounts.push(Lx200MountInfo {
                            port: port_name.clone(),
                            name: display_name.clone(),
                            mount_type: Lx200MountType::OnStep,
                            firmware_version,
                            baud_rate,
                        });
                        tracing::info!(
                            "Found OnStep mount on {} at {} baud: {}",
                            port_name,
                            baud_rate,
                            display_name
                        );
                        found_mount = true;
                        continue;
                    }

                    // Try standard LX200 detection
                    if port
                        .write_all(commands::GET_PRODUCT_NAME.as_bytes())
                        .is_ok()
                    {
                        let _ = port.flush();

                        let mut buf = [0u8; 64];
                        std::thread::sleep(Duration::from_millis(200));

                        if let Ok(n) = port.read(&mut buf) {
                            let response = String::from_utf8_lossy(&buf[..n]);
                            let name = response.trim_end_matches('#').to_string();

                            let mount_type = if name.to_lowercase().contains("meade")
                                || name.to_lowercase().contains("lx")
                            {
                                Some(Lx200MountType::Meade)
                            } else if name.to_lowercase().contains("gemini")
                                || name.to_lowercase().contains("losmandy")
                            {
                                Some(Lx200MountType::Losmandy)
                            } else if name.to_lowercase().contains("10micron") {
                                Some(Lx200MountType::TenMicron)
                            } else if !name.is_empty()
                                && name != "\0"
                                && name.chars().any(|c| c.is_alphanumeric())
                            {
                                Some(Lx200MountType::Generic)
                            } else {
                                None
                            };

                            if let Some(mount_type) = mount_type {
                                let display_name = format!("{} ({})", name, port_name);
                                let firmware_number = optional_discovery_response(
                                    &mut *port,
                                    commands::GET_FIRMWARE_NUMBER,
                                );
                                let firmware_date = optional_discovery_response(
                                    &mut *port,
                                    commands::GET_FIRMWARE_DATE,
                                );
                                let firmware_time = optional_discovery_response(
                                    &mut *port,
                                    commands::GET_FIRMWARE_TIME,
                                );
                                let firmware_version = format_firmware_version(
                                    firmware_number.as_deref(),
                                    firmware_date.as_deref(),
                                    firmware_time.as_deref(),
                                );
                                mounts.push(Lx200MountInfo {
                                    port: port_name.clone(),
                                    name: display_name.clone(),
                                    mount_type,
                                    firmware_version,
                                    baud_rate,
                                });
                                tracing::info!(
                                    "Found LX200 mount on {} at {} baud: {}",
                                    port_name,
                                    baud_rate,
                                    display_name
                                );
                                found_mount = true;
                                continue;
                            }
                        }
                    }

                    // Fallback: try GET_RA for basic LX200 detection
                    if port.write_all(commands::GET_RA.as_bytes()).is_ok() {
                        let _ = port.flush();

                        let mut buf = [0u8; 32];
                        std::thread::sleep(Duration::from_millis(200));

                        if let Ok(n) = port.read(&mut buf) {
                            let response = String::from_utf8_lossy(&buf[..n]);
                            if response.contains(':') && response.ends_with('#') {
                                let display_name = format!("LX200 Compatible ({})", port_name);
                                mounts.push(Lx200MountInfo {
                                    port: port_name.clone(),
                                    name: display_name.clone(),
                                    mount_type: Lx200MountType::Generic,
                                    firmware_version: None,
                                    baud_rate,
                                });
                                tracing::info!(
                                    "Found generic LX200 mount on {} at {} baud",
                                    port_name,
                                    baud_rate
                                );
                                found_mount = true;
                            }
                        }
                    }

                    // Explicit drop + sleep for Windows to fully release the COM port handle
                    drop(port);
                    std::thread::sleep(Duration::from_millis(50));
                } // end Ok(mut port) =>
            } // end match
        } // end for baud_rate
    } // end for port_info

    tracing::debug!("LX200 discovery complete: found {} mounts", mounts.len());
    Ok(mounts)
}

pub fn is_available() -> bool {
    true
}
