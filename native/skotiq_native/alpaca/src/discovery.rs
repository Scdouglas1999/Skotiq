//! Alpaca device discovery
//!
//! IPv4 discovery broadcasts to each interface's subnet broadcast address (not only
//! `255.255.255.255`). IPv6 discovery uses link-local all-nodes multicast (`ff02::1`)
//! scoped per interface, per the ASCOM Alpaca discovery protocol.

use crate::{AlpacaDevice, AlpacaDeviceType, AlpacaError, ApiVersion, ALPACA_DISCOVERY_PORT};
use if_addrs::{get_if_addrs, IfAddr};
use serde::Deserialize;
use socket2::{Domain, Protocol, Socket, Type};
use std::collections::HashSet;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;
use tokio::net::UdpSocket;
use tokio::time::timeout;
use tracing::{debug, info, warn};

/// Alpaca discovery probe (ASCOM Alpaca protocol).
pub const ALPACA_DISCOVERY_MESSAGE: &[u8] = b"alpacadiscovery1";

/// Process-global dedupe for device-fetch failure warnings. Discovery runs
/// once per device type (~11x per startup sweep) and re-queries every known
/// Alpaca server each time, so a single non-compliant/unreachable server would
/// otherwise emit the identical WARN ~11x. Returns `true` the first time a
/// given `ip:port` fails so we WARN once and DEBUG the repeats.
fn first_device_fetch_failure(addr: &str) -> bool {
    use std::sync::{Mutex, OnceLock};
    static WARNED: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    WARNED
        .get_or_init(|| Mutex::new(HashSet::new()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(addr.to_string())
}

/// IPv6 all-nodes link-local multicast (Alpaca discovery uses multicast instead of broadcast).
const IPV6_DISCOVERY_MULTICAST: &str = "ff02::1";

/// Discovery response from an Alpaca server
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct DiscoveryResponse {
    pub alpaca_port: u16,
}

/// Configured device from management API
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct ConfiguredDevice {
    pub device_name: String,
    pub device_type: String,
    pub device_number: u32,
    // The ASCOM Alpaca management spec spells this "UniqueID" (capital D), which
    // PascalCase derivation would render as "UniqueId" — so without this explicit
    // rename every device fails to deserialize and discovery against any
    // spec-compliant Alpaca server (incl. the ASCOM Omni Simulator) silently
    // returns nothing. Default to empty so a server that omits it still lists.
    #[serde(rename = "UniqueID", default)]
    pub unique_id: String,
}

/// An Alpaca device server discovered on the network.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DiscoveredAlpacaServer {
    pub host: String,
    pub alpaca_port: u16,
    /// Values from `GET /management/apiversions` (empty if the query failed).
    pub supported_api_versions: Vec<u32>,
}

impl DiscoveredAlpacaServer {
    /// Pick the highest API version this client supports.
    pub fn negotiated_api_version(&self) -> Option<ApiVersion> {
        ApiVersion::negotiate(&self.supported_api_versions)
    }
}

/// Discovery configuration
#[derive(Debug, Clone)]
pub struct DiscoveryConfig {
    /// Total discovery timeout
    pub discovery_timeout: Duration,
    /// Time to wait for individual responses
    pub response_wait: Duration,
    /// Timeout for HTTP requests to get device info
    pub http_timeout: Duration,
    /// Number of discovery broadcasts to send
    pub broadcast_count: u32,
    /// Delay between broadcasts
    pub broadcast_delay: Duration,
    /// Send IPv4 subnet broadcasts (per network interface).
    pub use_ipv4: bool,
    /// Send IPv6 link-local multicast discovery probes.
    pub use_ipv6: bool,
}

impl Default for DiscoveryConfig {
    fn default() -> Self {
        Self {
            discovery_timeout: Duration::from_secs(5),
            response_wait: Duration::from_millis(500),
            http_timeout: Duration::from_secs(10),
            broadcast_count: 3,
            broadcast_delay: Duration::from_millis(200),
            use_ipv4: true,
            use_ipv6: true,
        }
    }
}

fn ipv4_broadcast_addr(ip: Ipv4Addr, netmask: Ipv4Addr) -> Ipv4Addr {
    Ipv4Addr::from(u32::from(ip) | !u32::from(netmask))
}

/// Per-interface IPv4 broadcast targets for Alpaca discovery.
pub fn ipv4_broadcast_targets(port: u16) -> Vec<SocketAddr> {
    let mut targets = HashSet::new();

    if let Ok(ifaces) = get_if_addrs() {
        for iface in ifaces {
            if iface.is_loopback() {
                continue;
            }
            let IfAddr::V4(v4) = iface.addr else {
                continue;
            };
            if v4.netmask == Ipv4Addr::UNSPECIFIED {
                continue;
            }
            let broadcast = v4
                .broadcast
                .unwrap_or_else(|| ipv4_broadcast_addr(v4.ip, v4.netmask));
            if broadcast != Ipv4Addr::BROADCAST {
                targets.insert(SocketAddr::from((broadcast, port)));
            }
        }
    }

    let mut targets: Vec<_> = targets.into_iter().collect();
    targets.sort_unstable();
    targets
}

/// Send Alpaca discovery probes on IPv6 link-local multicast, one socket per interface.
pub fn send_ipv6_discovery_probes(message: &[u8], port: u16) {
    let multicast: SocketAddr = match format!("[{IPV6_DISCOVERY_MULTICAST}]:{port}").parse() {
        Ok(addr) => addr,
        Err(e) => {
            warn!("Failed to parse IPv6 Alpaca multicast address: {e}");
            return;
        }
    };

    let Ok(ifaces) = get_if_addrs() else {
        return;
    };

    for iface in ifaces {
        if iface.is_loopback() {
            continue;
        }
        if !matches!(iface.addr, IfAddr::V6(_)) {
            continue;
        }

        let Ok(socket) = Socket::new(Domain::IPV6, Type::DGRAM, Some(Protocol::UDP)) else {
            continue;
        };
        let bind_addr = SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0);
        if socket.bind(&bind_addr.into()).is_err() {
            continue;
        }
        if let Some(index) = iface.index {
            let _ = socket.set_multicast_if_v6(index);
        }
        let _ = socket.set_multicast_loop_v6(false);
        if let Err(e) = socket.send_to(message, &multicast.into()) {
            debug!(
                "IPv6 Alpaca discovery send on interface {} failed: {}",
                iface.name, e
            );
        }
    }
}

impl DiscoveryConfig {
    /// Create a quick discovery config for fast scans
    pub fn quick() -> Self {
        Self {
            discovery_timeout: Duration::from_secs(2),
            response_wait: Duration::from_millis(200),
            http_timeout: Duration::from_secs(5),
            broadcast_count: 1,
            broadcast_delay: Duration::from_millis(100),
            use_ipv4: true,
            use_ipv6: true,
        }
    }

    /// Create a thorough discovery config for comprehensive scans
    pub fn thorough() -> Self {
        Self {
            discovery_timeout: Duration::from_secs(10),
            response_wait: Duration::from_millis(1000),
            http_timeout: Duration::from_secs(15),
            broadcast_count: 5,
            broadcast_delay: Duration::from_millis(500),
            use_ipv4: true,
            use_ipv6: true,
        }
    }
}

/// Discover Alpaca servers on the local network using async UDP
pub async fn discover_servers(timeout_duration: Duration) -> Vec<(String, u16)> {
    discover_servers_with_config(DiscoveryConfig {
        discovery_timeout: timeout_duration,
        ..Default::default()
    })
    .await
}

/// Discover Alpaca servers with custom configuration (host, port tuples).
pub async fn discover_servers_with_config(config: DiscoveryConfig) -> Vec<(String, u16)> {
    discover_servers_detailed_with_config(config)
        .await
        .into_iter()
        .map(|s| (s.host, s.alpaca_port))
        .collect()
}

/// Discover Alpaca servers including supported management API versions.
pub async fn discover_servers_detailed_with_config(
    config: DiscoveryConfig,
) -> Vec<DiscoveredAlpacaServer> {
    let mut servers = HashSet::new();

    let socket = match UdpSocket::bind("0.0.0.0:0").await {
        Ok(s) => s,
        Err(e) => {
            warn!("Failed to bind UDP socket for discovery: {e}");
            return Vec::new();
        }
    };

    if let Err(e) = socket.set_broadcast(true) {
        warn!("Failed to enable broadcast on discovery socket: {e}");
        return Vec::new();
    }

    let ipv4_targets = if config.use_ipv4 {
        ipv4_broadcast_targets(ALPACA_DISCOVERY_PORT)
    } else {
        Vec::new()
    };

    for broadcast_num in 0..config.broadcast_count {
        if config.use_ipv4 {
            for target in &ipv4_targets {
                if let Err(e) = socket.send_to(ALPACA_DISCOVERY_MESSAGE, *target).await {
                    debug!("IPv4 Alpaca discovery send to {target} failed: {e}");
                }
            }
        }
        if config.use_ipv6 {
            send_ipv6_discovery_probes(ALPACA_DISCOVERY_MESSAGE, ALPACA_DISCOVERY_PORT);
        }
        debug!(
            "Sent discovery probe {}/{} ({} IPv4 targets, IPv6={})",
            broadcast_num + 1,
            config.broadcast_count,
            ipv4_targets.len(),
            config.use_ipv6
        );

        if broadcast_num + 1 < config.broadcast_count {
            tokio::time::sleep(config.broadcast_delay).await;
        }
    }

    // Receive responses with timeout
    let mut buf = [0u8; 1024];
    let deadline = tokio::time::Instant::now() + config.discovery_timeout;

    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }

        // Use the configured response wait time or remaining time, whichever is shorter
        let wait_time = remaining.min(config.response_wait);

        match timeout(wait_time, socket.recv_from(&mut buf)).await {
            Ok(Ok((len, addr))) => {
                if let Ok(response) = serde_json::from_slice::<DiscoveryResponse>(&buf[..len]) {
                    let server = (addr.ip().to_string(), response.alpaca_port);
                    if servers.insert(server.clone()) {
                        // debug, not info: discovery runs once per device-type
                        // (Camera, Mount, Focuser, ...), so the same server is
                        // re-discovered ~11x per startup sweep — noise at INFO.
                        debug!("Discovered Alpaca server at {}:{}", server.0, server.1);
                    }
                } else {
                    debug!("Received non-JSON response from {}", addr);
                }
            }
            Ok(Err(e)) => {
                debug!("Error receiving discovery response: {}", e);
            }
            Err(_) => {
                // Timeout on this receive, continue to check remaining time
                continue;
            }
        }
    }

    let mut discovered = Vec::with_capacity(servers.len());
    for (host, alpaca_port) in servers {
        let supported_api_versions = match get_api_versions(&host, alpaca_port).await {
            Ok(versions) if !versions.is_empty() => versions,
            Ok(_) => vec![ApiVersion::V1 as u32],
            Err(e) => {
                warn!("Failed to query API versions from {host}:{alpaca_port}: {e}");
                vec![ApiVersion::V1 as u32]
            }
        };
        if ApiVersion::negotiate(&supported_api_versions).is_none() {
            warn!(
                "Alpaca server {host}:{alpaca_port} reports no supported API versions: {supported_api_versions:?}"
            );
        }
        discovered.push(DiscoveredAlpacaServer {
            host,
            alpaca_port,
            supported_api_versions,
        });
    }
    discovered
}

/// Get configured devices from an Alpaca server
pub async fn get_configured_devices(
    server_ip: &str,
    port: u16,
) -> Result<Vec<AlpacaDevice>, String> {
    get_configured_devices_with_timeout(server_ip, port, Duration::from_secs(10)).await
}

/// Get configured devices from an Alpaca server with custom timeout
pub async fn get_configured_devices_with_timeout(
    server_ip: &str,
    port: u16,
    timeout_duration: Duration,
) -> Result<Vec<AlpacaDevice>, String> {
    let url = format!(
        "http://{}:{}/management/v1/configureddevices",
        server_ip, port
    );

    let client = reqwest::Client::builder()
        .timeout(timeout_duration)
        .build()
        .map_err(|e| e.to_string())?;

    let response = client.get(&url).send().await.map_err(|e| e.to_string())?;

    if !response.status().is_success() {
        return Err(format!(
            "Failed to get configured devices: HTTP {}",
            response.status()
        ));
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "PascalCase")]
    struct ApiResponse {
        value: Vec<ConfiguredDevice>,
    }

    let api_response: ApiResponse = response.json().await.map_err(|e| e.to_string())?;

    let base_url = format!("http://{}:{}", server_ip, port);

    let devices: Vec<AlpacaDevice> = api_response
        .value
        .into_iter()
        .filter_map(|d| {
            let device_type = match d.device_type.to_lowercase().as_str() {
                "camera" => Some(AlpacaDeviceType::Camera),
                "telescope" => Some(AlpacaDeviceType::Telescope),
                "focuser" => Some(AlpacaDeviceType::Focuser),
                "filterwheel" => Some(AlpacaDeviceType::FilterWheel),
                "dome" => Some(AlpacaDeviceType::Dome),
                "rotator" => Some(AlpacaDeviceType::Rotator),
                "safetymonitor" => Some(AlpacaDeviceType::SafetyMonitor),
                "observingconditions" => Some(AlpacaDeviceType::ObservingConditions),
                "switch" => Some(AlpacaDeviceType::Switch),
                "covercalibrator" => Some(AlpacaDeviceType::CoverCalibrator),
                _ => {
                    debug!("Unknown device type: {}", d.device_type);
                    None
                }
            }?;

            Some(AlpacaDevice {
                device_type,
                device_number: d.device_number,
                server_name: server_ip.to_string(),
                manufacturer: String::new(),
                device_name: d.device_name,
                unique_id: d.unique_id,
                base_url: base_url.clone(),
            })
        })
        .collect();

    Ok(devices)
}

/// Discover all Alpaca devices on the network
pub async fn discover_all_devices(timeout_duration: Duration) -> Vec<AlpacaDevice> {
    discover_all_devices_with_config(DiscoveryConfig {
        discovery_timeout: timeout_duration,
        ..Default::default()
    })
    .await
}

/// Discover all Alpaca devices with custom configuration
pub async fn discover_all_devices_with_config(config: DiscoveryConfig) -> Vec<AlpacaDevice> {
    let mut all_devices = Vec::new();

    let servers = discover_servers_detailed_with_config(config.clone()).await;

    // Fetch devices from all servers in parallel
    let fetch_futures: Vec<_> = servers
        .iter()
        .filter_map(|server| {
            if server.negotiated_api_version().is_none() {
                warn!(
                    "Skipping Alpaca server {}:{} — unsupported API versions {:?}",
                    server.host, server.alpaca_port, server.supported_api_versions
                );
                return None;
            }
            let ip = server.host.clone();
            let port = server.alpaca_port;
            let timeout = config.http_timeout;
            Some(async move {
                match get_configured_devices_with_timeout(&ip, port, timeout).await {
                    Ok(devices) => {
                        info!("Found {} devices at {}:{}", devices.len(), ip, port);
                        devices
                    }
                    Err(e) => {
                        let addr = format!("{}:{}", ip, port);
                        if first_device_fetch_failure(&addr) {
                            warn!("Failed to get devices from {}: {}", addr, e);
                        } else {
                            debug!("Failed to get devices from {} (repeat): {}", addr, e);
                        }
                        Vec::new()
                    }
                }
            })
        })
        .collect();

    // Execute all fetches in parallel
    let results = futures::future::join_all(fetch_futures).await;

    for devices in results {
        all_devices.extend(devices);
    }

    all_devices
}

/// Discover a specific type of device on the network
pub async fn discover_devices_of_type(
    device_type: AlpacaDeviceType,
    timeout_duration: Duration,
) -> Vec<AlpacaDevice> {
    discover_all_devices(timeout_duration)
        .await
        .into_iter()
        .filter(|d| d.device_type == device_type)
        .collect()
}

/// Check if a specific server is reachable
pub async fn ping_server(server_ip: &str, port: u16) -> Result<Duration, AlpacaError> {
    let url = format!("http://{}:{}/management/v1/description", server_ip, port);
    let start = std::time::Instant::now();

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .map_err(|e| AlpacaError::RequestFailed(e.to_string()))?;

    match client.get(&url).send().await {
        Ok(response) => {
            if response.status().is_success() {
                Ok(start.elapsed())
            } else {
                Err(AlpacaError::HttpError {
                    status: response.status().as_u16(),
                    message: "Server not responding correctly".to_string(),
                    retry_after: None,
                })
            }
        }
        Err(e) => {
            if e.is_timeout() {
                Err(AlpacaError::timeout("server configuration query", 5000))
            } else if e.is_connect() {
                Err(AlpacaError::connection_refused(url, e.to_string()))
            } else {
                Err(AlpacaError::RequestFailed(e.to_string()))
            }
        }
    }
}

/// Get server description
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct ServerDescription {
    pub server_name: String,
    pub manufacturer: String,
    pub manufacturer_version: String,
    pub location: String,
}

/// Get the description of an Alpaca server
pub async fn get_server_description(
    server_ip: &str,
    port: u16,
) -> Result<ServerDescription, AlpacaError> {
    let url = format!("http://{}:{}/management/v1/description", server_ip, port);

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| AlpacaError::RequestFailed(e.to_string()))?;

    let response = client.get(&url).send().await.map_err(|e| {
        if e.is_timeout() {
            AlpacaError::timeout("server description query", 10000)
        } else if e.is_connect() {
            AlpacaError::connection_refused(&url, e.to_string())
        } else {
            AlpacaError::RequestFailed(e.to_string())
        }
    })?;

    if !response.status().is_success() {
        return Err(AlpacaError::HttpError {
            status: response.status().as_u16(),
            message: "Failed to get server description".to_string(),
            retry_after: None,
        });
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "PascalCase")]
    struct ApiResponse {
        value: ServerDescription,
    }

    let api_response: ApiResponse = response
        .json()
        .await
        .map_err(|e| AlpacaError::ParseError(e.to_string()))?;

    Ok(api_response.value)
}

/// Get supported API versions from a server
pub async fn get_api_versions(server_ip: &str, port: u16) -> Result<Vec<u32>, AlpacaError> {
    let url = format!("http://{}:{}/management/apiversions", server_ip, port);

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .map_err(|e| AlpacaError::RequestFailed(e.to_string()))?;

    let response = client.get(&url).send().await.map_err(|e| {
        if e.is_timeout() {
            AlpacaError::timeout("API versions query", 5000)
        } else if e.is_connect() {
            AlpacaError::connection_refused(&url, e.to_string())
        } else {
            AlpacaError::RequestFailed(e.to_string())
        }
    })?;

    if !response.status().is_success() {
        return Err(AlpacaError::HttpError {
            status: response.status().as_u16(),
            message: "Failed to get API versions".to_string(),
            retry_after: None,
        });
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "PascalCase")]
    struct ApiResponse {
        value: Vec<u32>,
    }

    let api_response: ApiResponse = response
        .json()
        .await
        .map_err(|e| AlpacaError::ParseError(e.to_string()))?;

    Ok(api_response.value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_discovery_config_defaults() {
        let config = DiscoveryConfig::default();
        assert_eq!(config.discovery_timeout, Duration::from_secs(5));
        assert_eq!(config.broadcast_count, 3);
    }

    #[test]
    fn test_discovery_config_quick() {
        let config = DiscoveryConfig::quick();
        assert_eq!(config.discovery_timeout, Duration::from_secs(2));
        assert_eq!(config.broadcast_count, 1);
    }

    #[test]
    fn test_ipv4_broadcast_targets_non_empty_on_loopback_free_host() {
        let targets = ipv4_broadcast_targets(ALPACA_DISCOVERY_PORT);
        for addr in &targets {
            assert_eq!(addr.port(), ALPACA_DISCOVERY_PORT);
            assert!(addr.ip().is_ipv4());
        }
    }

    #[test]
    fn test_discovered_server_negotiates_supported_api_version() {
        let server = DiscoveredAlpacaServer {
            host: "192.0.2.10".to_string(),
            alpaca_port: 11111,
            supported_api_versions: vec![2, 1],
        };

        assert_eq!(server.negotiated_api_version(), Some(ApiVersion::V1));
    }

    #[test]
    fn test_discovered_server_rejects_unsupported_api_versions() {
        let server = DiscoveredAlpacaServer {
            host: "192.0.2.10".to_string(),
            alpaca_port: 11111,
            supported_api_versions: vec![2, 3],
        };

        assert_eq!(server.negotiated_api_version(), None);
    }

    #[test]
    fn test_discovery_config_thorough() {
        let config = DiscoveryConfig::thorough();
        assert_eq!(config.discovery_timeout, Duration::from_secs(10));
        assert_eq!(config.broadcast_count, 5);
    }
}
