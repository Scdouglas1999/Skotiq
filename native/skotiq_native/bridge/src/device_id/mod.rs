//! Device ID Parsing and Validation
//!
//! This module provides safe, structured parsing of device IDs across all
//! supported driver types (ASCOM, Alpaca, INDI, Native). Device IDs follow
//! a consistent format:
//!
//! - ASCOM:  `ascom:{prog_id}` (e.g., `ascom:ASCOM.Camera.Simulator`)
//! - Alpaca: `alpaca:{protocol}://{host}:{port}:{device_type}:{device_num}`
//!           (e.g., `alpaca:http://192.168.1.100:11111:camera:0`)
//! - INDI:   `indi:{host}:{port}:{device_name}`
//!           (e.g., `indi:localhost:7624:ZWO CCD`)
//! - Native: `native:{vendor}:{device_id}` for the simple case, with
//!           multi-segment forms documented on `parse_native`.
//!
//! # Example
//!
//! ```rust,ignore
//! use skotiq_bridge::device_id::ParsedDeviceId;
//!
//! let parsed = ParsedDeviceId::parse("alpaca:http://192.168.1.100:11111:camera:0")?;
//! if let ConnectionInfo::Alpaca { host, port, device_type, device_num, .. } = parsed.connection_info {
//!     println!("Alpaca device at {}:{}", host, port);
//! }
//! ```

use crate::device::DriverType;
use crate::error::SkotiqError;
use serde::{Deserialize, Serialize};

pub mod cache;
#[cfg(test)]
// `unwrap_or` policy: the test helpers in this module
// use `unwrap_or_else(|e| panic!(...))` as a richer-message replacement
// for `expect`. These are NOT silent fallbacks — they fail the test loud
// with the vendor name and parse error embedded in the panic message.
mod tests;

/// A fully parsed and validated device ID
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParsedDeviceId {
    /// The raw device ID string
    pub raw_id: String,
    /// The driver type this ID represents
    pub driver_type: DriverType,
    pub connection_info: ConnectionInfo,
}

/// Connection information specific to each driver type
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ConnectionInfo {
    /// ASCOM driver (Windows COM)
    Ascom {
        /// The ASCOM ProgID (e.g., "ASCOM.Camera.Simulator")
        prog_id: String,
    },

    /// ASCOM Alpaca (REST API)
    Alpaca {
        /// Protocol (http or https)
        protocol: String,
        /// Host address (IP or hostname)
        host: String,
        port: u16,
        /// Device type string (camera, telescope, focuser, etc.)
        device_type: String,
        /// Device number on the server
        device_num: u32,
        /// Full base URL for convenience
        base_url: String,
    },

    Indi {
        host: String,
        port: u16,
        device_name: String,
    },

    /// Native SDK (ZWO, QHY, etc.)
    Native {
        /// Vendor name (zwo, qhy, playerone, etc.) lower-cased and
        /// validated against the vendor catalog (`skotiq_native::catalog`).
        vendor: String,
        /// Device identifier (index, serial, port, etc.). For
        /// multi-segment IDs this is the trailing payload AFTER any
        /// `vendor_brand` / `device_subtype` segment is stripped.
        device_id: String,
        /// Parsed device index if `device_id` is purely numeric.
        device_index: Option<i32>,
        /// Touptek brand segment for IDs of the form
        /// `native:touptek:{brand}:{idx}` (e.g. brand = "ogma"). `None`
        /// for any other vendor — including 3-part Touptek IDs, which
        /// `parse_native` rejects rather than silently fall through.
        vendor_brand: Option<String>,
        /// Subtype segment for vendors that use a 4-part form to
        /// distinguish accessory devices from cameras: ZWO `eaf`/`efw`,
        /// QHY `cfw`, FLI `focuser`/`fw`. `None` for the composite
        /// (`zwo_eaf`, `qhy_cfw`, ...) form and for vendors with no
        /// subtype concept.
        device_subtype: Option<String>,
    },

    Simulator {
        device_type: String,
        instance: u32,
    },
}

impl ParsedDeviceId {
    /// Parse a device ID string (`"ascom:ASCOM.Camera.Simulator"`,
    /// `"native:zwo:0"`, `"alpaca:http://host:11111:camera:0"`) into its
    /// components.
    pub fn parse(id: &str) -> Result<Self, SkotiqError> {
        if id.is_empty() {
            return Err(SkotiqError::invalid_device_id(
                id,
                "Device ID cannot be empty",
            ));
        }

        if id.starts_with("ascom:") {
            Self::parse_ascom(id)
        } else if id.starts_with("alpaca:") {
            Self::parse_alpaca(id)
        } else if id.starts_with("indi:") {
            Self::parse_indi(id)
        } else if id.starts_with("native:") {
            Self::parse_native(id)
        } else if id.starts_with("simulator:") || id.starts_with("sim:") || id.starts_with("sim_") {
            Self::parse_simulator(id)
        } else {
            // Try to infer the type from the ID format
            Self::parse_infer(id)
        }
    }

    /// Parse an ASCOM device ID
    fn parse_ascom(id: &str) -> Result<Self, SkotiqError> {
        let prog_id = id
            .strip_prefix("ascom:")
            .ok_or_else(|| SkotiqError::invalid_device_id(id, "Missing 'ascom:' prefix"))?;

        if prog_id.is_empty() {
            return Err(SkotiqError::invalid_device_id(
                id,
                "ASCOM ProgID cannot be empty",
            ));
        }

        // Basic validation: ASCOM ProgIDs should contain at least one dot
        if !prog_id.contains('.') {
            return Err(SkotiqError::invalid_device_id(
                id,
                "Invalid ASCOM ProgID format - expected 'Vendor.Type.Name'",
            ));
        }

        Ok(ParsedDeviceId {
            raw_id: id.to_string(),
            driver_type: DriverType::Ascom,
            connection_info: ConnectionInfo::Ascom {
                prog_id: prog_id.to_string(),
            },
        })
    }

    /// Parse an Alpaca device ID
    fn parse_alpaca(id: &str) -> Result<Self, SkotiqError> {
        let remainder = id
            .strip_prefix("alpaca:")
            .ok_or_else(|| SkotiqError::invalid_device_id(id, "Missing 'alpaca:' prefix"))?;

        // Format: protocol://host:port:device_type:device_num
        // or:     protocol://host:port/api/v1/device_type/device_num

        // First, try the colon-separated format: http://host:port:type:num
        let parts: Vec<&str> = remainder.split(':').collect();

        if parts.len() >= 5 {
            // Format: protocol://host:port:device_type:device_num
            let protocol = parts[0];
            let host = parts[1].trim_start_matches("//");
            let port: u16 = parts[2]
                .parse()
                .map_err(|_| SkotiqError::invalid_device_id(id, "Invalid port number"))?;
            let device_type = parts[3].to_lowercase();
            let device_num: u32 = parts[4]
                .parse()
                .map_err(|_| SkotiqError::invalid_device_id(id, "Invalid device number"))?;

            let base_url = format!("{}://{}:{}", protocol, host, port);

            return Ok(ParsedDeviceId {
                raw_id: id.to_string(),
                driver_type: DriverType::Alpaca,
                connection_info: ConnectionInfo::Alpaca {
                    protocol: protocol.to_string(),
                    host: host.to_string(),
                    port,
                    device_type,
                    device_num,
                    base_url,
                },
            });
        }

        // Try alternate format: base_url:device_type:device_num
        if parts.len() >= 3 {
            // Try parsing as base_url:type:num where base_url contains ://
            let base_url = parts[0..parts.len() - 2].join(":");
            let device_type = parts[parts.len() - 2].to_lowercase();
            let device_num: u32 = parts[parts.len() - 1]
                .parse()
                .map_err(|_| SkotiqError::invalid_device_id(id, "Invalid device number"))?;

            // Extract protocol, host, port from base_url
            let (protocol, host, port) =
                parse_base_url(&base_url).map_err(|e| SkotiqError::invalid_device_id(id, e))?;

            return Ok(ParsedDeviceId {
                raw_id: id.to_string(),
                driver_type: DriverType::Alpaca,
                connection_info: ConnectionInfo::Alpaca {
                    protocol,
                    host,
                    port,
                    device_type,
                    device_num,
                    base_url,
                },
            });
        }

        Err(SkotiqError::invalid_device_id(
            id,
            "Invalid Alpaca device ID format - expected 'protocol://host:port:device_type:device_num'",
        ))
    }

    /// Parse an INDI device ID
    fn parse_indi(id: &str) -> Result<Self, SkotiqError> {
        let remainder = id
            .strip_prefix("indi:")
            .ok_or_else(|| SkotiqError::invalid_device_id(id, "Missing 'indi:' prefix"))?;

        // Format: host:port:device_name
        // Device name can contain colons, so we split carefully
        let parts: Vec<&str> = remainder.splitn(3, ':').collect();

        if parts.len() < 3 {
            return Err(SkotiqError::invalid_device_id(
                id,
                "Invalid INDI device ID format - expected 'indi:host:port:device_name'",
            ));
        }

        let host = parts[0];
        let port: u16 = parts[1]
            .parse()
            .map_err(|_| SkotiqError::invalid_device_id(id, "Invalid port number"))?;
        let device_name = parts[2];

        if host.is_empty() {
            return Err(SkotiqError::invalid_device_id(
                id,
                "INDI host cannot be empty",
            ));
        }
        if device_name.is_empty() {
            return Err(SkotiqError::invalid_device_id(
                id,
                "INDI device name cannot be empty",
            ));
        }

        Ok(ParsedDeviceId {
            raw_id: id.to_string(),
            driver_type: DriverType::Indi,
            connection_info: ConnectionInfo::Indi {
                host: host.to_string(),
                port,
                device_name: device_name.to_string(),
            },
        })
    }

    /// Parse a native SDK device ID.
    ///
    /// Native IDs are emitted by `skotiq_native::discovery` and the
    /// per-vendor modules. Encoded forms in the wild:
    ///
    /// * 3-part: `native:{vendor}:{id}` (camera index, serial, etc.)
    ///   e.g. `native:zwo:0`, `native:qhy:QHY600M-12345`,
    ///   `native:lx200:COM3`.
    /// * 4-part subtype: `native:{vendor}:{subtype}:{id}` for ZWO
    ///   `eaf`/`efw`, QHY `cfw`, Atik `efw`, FLI `focuser`/`fw`.
    ///   e.g. `native:zwo:eaf:0`.
    /// * 4-part composite (alternative encoding emitted by
    ///   `discovery.rs`): `native:{vendor}_{subtype}:{id}`, e.g.
    ///   `native:zwo_eaf:0`. The composite token is in the allow-list
    ///   so this hits the default branch with `device_subtype: None`.
    /// * 4-part Touptek brand: `native:touptek:{brand}:{idx}`
    ///   (multi-brand SDK — brand is "ogma", "altair", "nncam", ...).
    /// * 4-part mount with port + baud: `native:{vendor}:{port}:{baud}`
    ///   for skywatcher / ioptron / lx200 / meade / onstep / losmandy /
    ///   10micron. Treated as the default 3-part form with `{port}:{baud}`
    ///   collapsed into `device_id` (preserves today's call-site
    ///   behaviour in `bridge/src/devices.rs`).
    /// * 5-part gphoto2: `native:gphoto2:{idx}:{port_hex}:{model}`. Same
    ///   collapsing rule.
    ///
    /// CRITICAL: an unknown leading vendor token returns an error. We do
    /// NOT silently default — that would let typo'd or future-vendor IDs
    /// reach hardware dispatch where they trigger far more confusing
    /// failures.
    fn parse_native(id: &str) -> Result<Self, SkotiqError> {
        let remainder = id
            .strip_prefix("native:")
            .ok_or_else(|| SkotiqError::invalid_device_id(id, "Missing 'native:' prefix"))?;

        // Split into all segments up-front so the multi-segment branches
        // below can index without re-splitting. `splitn(2, ':')` would collapse
        // every byte after the vendor into a single string, losing the brand
        // segment the multi-part vendors need.
        let segments: Vec<&str> = remainder.split(':').collect();
        if segments.len() < 2 || segments[0].is_empty() || segments[1].is_empty() {
            return Err(SkotiqError::invalid_device_id(
                id,
                "Invalid native device ID format - expected 'native:vendor:device_id'",
            ));
        }

        let vendor = segments[0].to_lowercase();

        // Validate vendor against the single source of truth. Composite
        // tokens (`zwo_eaf`, `qhy_cfw`, ...) live in the constant
        // because that is what `discovery.rs` emits.
        if !native_id_tokens().contains(&vendor) {
            return Err(SkotiqError::invalid_device_id(
                id,
                format!(
                    "Unknown native vendor '{}'. The known ones are the rows of \
                     skotiq_native::catalog::FAMILIES",
                    vendor,
                ),
            ));
        }

        // Touptek IDs are always 4-part: `native:touptek:{brand}:{idx}`.
        // A 3-part Touptek ID (`native:touptek:0`) is rejected because
        // the bridge dispatch needs the brand to pick the right SDK
        // wrapper — see `bridge/src/devices.rs` Touptek branch.
        if vendor == "touptek" {
            if segments.len() != 3 {
                return Err(SkotiqError::invalid_device_id(
                    id,
                    "Touptek device ID must be 'native:touptek:{brand}:{idx}'",
                ));
            }
            let brand = segments[1].to_lowercase();
            let idx_str = segments[2];
            if brand.is_empty() {
                return Err(SkotiqError::invalid_device_id(
                    id,
                    "Touptek brand segment cannot be empty",
                ));
            }
            let device_index = idx_str.parse::<i32>().ok();
            return Ok(ParsedDeviceId {
                raw_id: id.to_string(),
                driver_type: DriverType::Native,
                connection_info: ConnectionInfo::Native {
                    vendor,
                    device_id: idx_str.to_string(),
                    device_index,
                    vendor_brand: Some(brand),
                    device_subtype: None,
                },
            });
        }

        // 4-part subtype form: `native:{vendor}:{subtype}:{id}` where
        // {subtype} is one of the registered subtype tokens for the
        // vendor (zwo: eaf/efw, qhy: cfw, atik: efw, fli: focuser/fw). We only
        // claim this branch when both conditions hold so legitimate
        // 3-part vendor IDs whose payload happens to contain colons
        // (e.g. `native:lx200:COM3:9600`) still take the default path.
        if segments.len() >= 3 {
            let subtypes = skotiq_native::catalog::subtypes_of(&vendor);
            if !subtypes.is_empty() {
                let candidate = segments[1].to_lowercase();
                if subtypes.contains(&candidate.as_str()) {
                    // Everything after the subtype is the device id —
                    // join with ':' to preserve any legitimate colons in
                    // the trailing payload (paths, serials).
                    let payload = segments[2..].join(":");
                    if payload.is_empty() {
                        return Err(SkotiqError::invalid_device_id(
                            id,
                            "Subtype device ID cannot be empty",
                        ));
                    }
                    let device_index = payload.parse::<i32>().ok();
                    return Ok(ParsedDeviceId {
                        raw_id: id.to_string(),
                        driver_type: DriverType::Native,
                        connection_info: ConnectionInfo::Native {
                            vendor,
                            device_id: payload,
                            device_index,
                            vendor_brand: None,
                            device_subtype: Some(candidate),
                        },
                    });
                }
            }
        }

        // Default: collapse everything after the vendor into device_id.
        // This preserves the historical contract for serial-port mounts
        // (`native:skywatcher:COM3:9600`), gPhoto2 5-part IDs, and the
        // composite-subtype form (`native:zwo_eaf:0`) where the subtype
        // is already baked into the vendor token.
        let device_id_str = segments[1..].join(":");
        let device_index = device_id_str.parse::<i32>().ok();
        Ok(ParsedDeviceId {
            raw_id: id.to_string(),
            driver_type: DriverType::Native,
            connection_info: ConnectionInfo::Native {
                vendor,
                device_id: device_id_str,
                device_index,
                vendor_brand: None,
                device_subtype: None,
            },
        })
    }

    /// Parse a simulator device ID
    fn parse_simulator(id: &str) -> Result<Self, SkotiqError> {
        // Two accepted forms, both producing the same ConnectionInfo::Simulator:
        //   canonical  `simulator:<type>[:<instance>]` / `sim:<type>...`  (colon)
        //   legacy     `sim_<type>_<instance>`                            (under-
        //              score) — the form the rest of the bridge's simulator
        //              device family uses (camera.rs, real_device_ops.rs,
        //              discovery.rs) and what `device_info_from_id` needs so a
        //              sim mount/focuser/rotator/filter-wheel is connectable by
        //              id, not just the sim camera.
        let (remainder, sep): (&str, char) = if let Some(r) = id.strip_prefix("simulator:") {
            (r, ':')
        } else if let Some(r) = id.strip_prefix("sim:") {
            (r, ':')
        } else if let Some(r) = id.strip_prefix("sim_") {
            (r, '_')
        } else {
            return Err(SkotiqError::invalid_device_id(
                id,
                "Missing simulator prefix",
            ));
        };

        // Format: device_type<sep>instance (instance optional, defaults to 0)
        let parts: Vec<&str> = remainder.split(sep).collect();

        let device_type = parts
            .first()
            .ok_or_else(|| SkotiqError::invalid_device_id(id, "Missing device type"))?
            .to_lowercase();

        // Why: simulator instance index defaults to 0
        // when the suffix is malformed or absent. Real driver IDs go
        // through stricter parsing; the simulator is a developer-only
        // device family where "instance 0" is the legacy fallback that
        // matches the pre-multi-instance default behaviour.
        let instance: u32 = if parts.len() > 1 {
            parts[1].parse().unwrap_or(0)
        } else {
            0
        };

        Ok(ParsedDeviceId {
            raw_id: id.to_string(),
            driver_type: DriverType::Simulator,
            connection_info: ConnectionInfo::Simulator {
                device_type,
                instance,
            },
        })
    }

    /// Try to infer the device type from the ID format
    fn parse_infer(id: &str) -> Result<Self, SkotiqError> {
        // Check if it looks like an ASCOM ProgID (contains dots, no scheme)
        if id.contains('.') && !id.contains("://") && !id.contains(':') {
            return Self::parse_ascom(&format!("ascom:{}", id));
        }

        // Check if it looks like a URL
        if id.starts_with("http://") || id.starts_with("https://") {
            // Likely an Alpaca URL without prefix
            return Self::parse_alpaca(&format!("alpaca:{}", id));
        }

        Err(SkotiqError::invalid_device_id(
            id,
            "Unable to infer device type - use a prefix (ascom:, alpaca:, indi:, native:)",
        ))
    }

    // Accessor methods

    /// Get Alpaca connection info if this is an Alpaca device
    pub fn alpaca_info(&self) -> Option<(&str, &str, u16, &str, u32)> {
        match &self.connection_info {
            ConnectionInfo::Alpaca {
                protocol,
                host,
                port,
                device_type,
                device_num,
                ..
            } => Some((protocol, host, *port, device_type, *device_num)),
            _ => None,
        }
    }

    /// Get the Alpaca base URL if this is an Alpaca device
    pub fn alpaca_base_url(&self) -> Option<&str> {
        match &self.connection_info {
            ConnectionInfo::Alpaca { base_url, .. } => Some(base_url),
            _ => None,
        }
    }
}

/// The tokens that may follow `native:`: the vendor catalog's, plus the two
/// devices the bridge itself serves under the native prefix.
fn native_id_tokens() -> Vec<String> {
    let mut tokens = skotiq_native::catalog::id_tokens();
    tokens.extend(["ascom".to_string(), "builtin_guider".to_string()]);
    tokens
}

/// Parse a base URL into protocol, host, and port
fn parse_base_url(url: &str) -> Result<(String, String, u16), &'static str> {
    // Expected format: http://host:port or https://host:port
    // Why: `strip_prefix` returns None only when the
    // prefix does not match, but we've already gated each branch with
    // `starts_with` of the same prefix; the fallback `""` is unreachable
    // but cheaper than `expect("checked above")`. Empty remainder would
    // produce an "Empty host" error downstream, not silent acceptance.
    let (protocol, remainder) = if url.starts_with("https://") {
        (
            "https".to_string(),
            url.strip_prefix("https://").unwrap_or(""),
        )
    } else if url.starts_with("http://") {
        (
            "http".to_string(),
            url.strip_prefix("http://").unwrap_or(""),
        )
    } else {
        return Err("Invalid URL protocol - expected http:// or https://");
    };

    // Split host and port
    let parts: Vec<&str> = remainder.split(':').collect();
    if parts.len() < 2 {
        return Err("Invalid URL format - expected host:port");
    }

    let host = parts[0].to_string();
    let port: u16 = parts[1]
        .split('/')
        .next()
        .and_then(|p| p.parse().ok())
        .ok_or("Invalid port number")?;

    Ok((protocol, host, port))
}

impl std::fmt::Display for ParsedDeviceId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.connection_info {
            ConnectionInfo::Ascom { prog_id } => {
                write!(f, "ASCOM:{}", prog_id)
            }
            ConnectionInfo::Alpaca {
                host,
                port,
                device_type,
                device_num,
                ..
            } => {
                write!(f, "Alpaca:{}:{}/{}:{}", host, port, device_type, device_num)
            }
            ConnectionInfo::Indi {
                host,
                port,
                device_name,
            } => {
                write!(f, "INDI:{}:{}/{}", host, port, device_name)
            }
            ConnectionInfo::Native {
                vendor,
                device_id,
                vendor_brand,
                device_subtype,
                ..
            } => {
                // Render in a form that mirrors the parsed structure so
                // log output makes the brand / subtype distinction
                // visible. We do NOT round-trip back to the raw ID
                // here — `raw()` is the contract for that.
                if let Some(brand) = vendor_brand {
                    write!(f, "Native:{}:{}:{}", vendor, brand, device_id)
                } else if let Some(sub) = device_subtype {
                    write!(f, "Native:{}:{}:{}", vendor, sub, device_id)
                } else {
                    write!(f, "Native:{}:{}", vendor, device_id)
                }
            }
            ConnectionInfo::Simulator {
                device_type,
                instance,
            } => {
                write!(f, "Simulator:{}:{}", device_type, instance)
            }
        }
    }
}

// Tests
