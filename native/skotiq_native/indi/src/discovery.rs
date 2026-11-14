//! INDI device discovery
//!
//! Provides network scanning for INDI servers and device enumeration.

use crate::{IndiClient, INDI_DEFAULT_PORT};
use if_addrs::get_if_addrs;
use mdns_sd::{ServiceDaemon, ServiceEvent};
use skotiq_device::DeviceKind;
use std::collections::HashSet;
use std::time::Duration;
use tokio::sync::RwLock;

/// Discovered INDI server information
#[derive(Debug, Clone)]
pub struct IndiServer {
    pub host: String,
    pub port: u16,
    pub devices: Vec<IndiDeviceInfo>,
}

/// A device on an INDI server that Skotiq drives.
#[derive(Debug, Clone)]
pub struct IndiDeviceInfo {
    pub name: String,
    pub kind: DeviceKind,
}

/// How long the definitions must stop changing before a server counts as
/// having announced all its devices. INDI has no end-of-definitions message.
const DEFINITIONS_QUIET: Duration = Duration::from_millis(300);

/// Waits up to `limit` for a server's device definitions: until every device
/// announced so far has a settled kind and no device or property was added
/// for [`DEFINITIONS_QUIET`].
///
/// A server announces a device's name before its properties, and a classifier
/// that ran at the first name would see only the CONNECTION switch.
pub async fn wait_for_definitions(client: &RwLock<IndiClient>, limit: Duration) {
    let start = tokio::time::Instant::now();
    let mut last_count = None;
    let mut quiet_since = start;
    loop {
        let (count, settled) = {
            let client = client.read().await;
            let devices = client.get_devices().await;
            let mut count = devices.len();
            let mut settled = !devices.is_empty();
            for device in &devices {
                let description = client.describe_device(&device.name).await;
                count += description.properties.len();
                settled &= description.is_settled();
            }
            (count, settled)
        };
        let now = tokio::time::Instant::now();
        if last_count != Some(count) {
            last_count = Some(count);
            quiet_since = now;
        }
        if (settled && now - quiet_since >= DEFINITIONS_QUIET) || now - start >= limit {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// The devices `client` knows of that Skotiq drives, each with its kind.
/// Devices of no kind Skotiq drives are logged and left out.
pub async fn list_devices(client: &IndiClient) -> Vec<IndiDeviceInfo> {
    let mut out = Vec::new();
    for device in client.get_devices().await {
        let description = client.describe_device(&device.name).await;
        match description.kind() {
            Some(kind) => out.push(IndiDeviceInfo {
                name: device.name,
                kind,
            }),
            None => tracing::warn!(
                "Skipping INDI device '{}' of a kind Skotiq does not drive (interface {:?})",
                device.name,
                description.interface
            ),
        }
    }
    out
}

/// Scan localhost for INDI server on default port
pub async fn discover_localhost() -> Option<IndiServer> {
    discover_server("127.0.0.1", INDI_DEFAULT_PORT).await
}

/// Scan a specific host:port for INDI server
pub async fn discover_server(host: &str, port: u16) -> Option<IndiServer> {
    // First, try a quick TCP connect to check if server is listening
    let addr = format!("{}:{}", host, port);
    if !check_port_open(&addr, Duration::from_millis(500)).await {
        return None;
    }

    let mut client = IndiClient::new(host, Some(port));
    if client.connect().await.is_err() {
        return None;
    }
    let client = RwLock::new(client);
    wait_for_definitions(&client, Duration::from_secs(5)).await;
    let mut client = client.into_inner();
    let devices = list_devices(&client).await;
    let _ = client.disconnect().await;

    Some(IndiServer {
        host: host.to_string(),
        port,
        devices,
    })
}

/// Scan common hosts for INDI servers
pub async fn discover_common_hosts() -> Vec<IndiServer> {
    let mut servers = Vec::new();

    let hosts = vec![
        "127.0.0.1",
        "localhost",
        "indiserver",
        "raspberrypi",
        "stellarmate",
        "astroberry",
    ];

    for host in hosts {
        if let Some(server) = discover_server(host, INDI_DEFAULT_PORT).await {
            servers.push(server);
        }
    }

    servers
}

/// Listen for `timeout` on mDNS/Bonjour for servers advertising
/// `_indi._tcp.local.`, and return each one's host and port.
pub async fn discover_mdns(timeout: Duration) -> Vec<IndiServer> {
    let mut discovered_servers = Vec::new();

    let mdns = match ServiceDaemon::new() {
        Ok(d) => d,
        Err(e) => {
            tracing::warn!(
                "Failed to create mDNS daemon: {}. mDNS discovery unavailable.",
                e
            );
            return discovered_servers;
        }
    };

    // Service type for INDI servers
    let service_type = "_indi._tcp.local.";

    let receiver = match mdns.browse(service_type) {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!(
                "Failed to browse mDNS services: {}. mDNS discovery unavailable.",
                e
            );
            return discovered_servers;
        }
    };

    tracing::info!("Searching for INDI servers via mDNS for {:?}...", timeout);

    let start = std::time::Instant::now();
    let mut discovered_addresses = std::collections::HashSet::new();

    while start.elapsed() < timeout {
        let remaining = timeout - start.elapsed();

        match tokio::time::timeout(
            remaining,
            tokio::task::spawn_blocking({
                let receiver = receiver.clone();
                move || receiver.recv()
            }),
        )
        .await
        {
            Ok(Ok(Ok(event))) => {
                match event {
                    ServiceEvent::ServiceResolved(info) => {
                        tracing::debug!("mDNS service resolved: {:?}", info);

                        let _host = info.get_hostname().to_string();
                        let port = info.get_port();

                        // Use first available address
                        if let Some(addr) = info.get_addresses().iter().next() {
                            let host_ip = addr.to_string();
                            let key = format!("{}:{}", host_ip, port);

                            if !discovered_addresses.contains(&key) {
                                discovered_addresses.insert(key);

                                tracing::info!(
                                    "Found INDI server via mDNS: {} ({}:{})",
                                    info.get_fullname(),
                                    host_ip,
                                    port
                                );

                                // Try to connect and enumerate devices
                                if let Some(server) = discover_server(&host_ip, port).await {
                                    discovered_servers.push(server);
                                } else {
                                    // Even if we can't enumerate, add the server info
                                    discovered_servers.push(IndiServer {
                                        host: host_ip,
                                        port,
                                        devices: Vec::new(),
                                    });
                                }
                            }
                        }
                    }
                    ServiceEvent::SearchStarted(_) => {
                        tracing::debug!("mDNS search started");
                    }
                    ServiceEvent::ServiceFound(ty, fullname) => {
                        tracing::debug!("mDNS service found: {} ({})", fullname, ty);
                    }
                    _ => {}
                }
            }
            Ok(Ok(Err(e))) => {
                tracing::warn!("mDNS receive error: {}", e);
                break;
            }
            Ok(Err(e)) => {
                tracing::warn!("mDNS task error: {}", e);
                break;
            }
            Err(_) => {
                // Timeout - this is expected, we've reached our search duration
                break;
            }
        }
    }

    if let Err(e) = mdns.shutdown() {
        tracing::warn!("Failed to shutdown mDNS daemon: {}", e);
    }

    tracing::info!(
        "mDNS discovery complete. Found {} INDI server{}.",
        discovered_servers.len(),
        if discovered_servers.len() == 1 {
            ""
        } else {
            "s"
        }
    );
    discovered_servers
}

/// Scan local subnet for INDI servers (192.168.x.x range)
pub async fn discover_local_network(timeout: Duration) -> Vec<IndiServer> {
    let mut servers = Vec::new();

    // Get local IP addresses to determine subnets to scan
    let subnets = get_local_subnets();

    for subnet in subnets {
        // Scan the subnet in parallel batches
        let mut handles = Vec::new();

        for i in 1..=254u8 {
            let ip = format!("{}.{}.{}.{}", subnet.0, subnet.1, subnet.2, i);

            handles.push(tokio::spawn(async move {
                let addr = format!("{}:{}", ip, INDI_DEFAULT_PORT);
                if check_port_open(&addr, timeout).await {
                    discover_server(&ip, INDI_DEFAULT_PORT).await
                } else {
                    None
                }
            }));

            // Batch processing to avoid overwhelming the system
            if handles.len() >= 50 {
                for handle in handles.drain(..) {
                    if let Ok(Some(server)) = handle.await {
                        servers.push(server);
                    }
                }
            }
        }

        for handle in handles {
            if let Ok(Some(server)) = handle.await {
                servers.push(server);
            }
        }
    }

    servers
}

async fn check_port_open(addr: &str, timeout: Duration) -> bool {
    tokio::time::timeout(timeout, tokio::net::TcpStream::connect(addr))
        .await
        .map(|result| result.is_ok())
        // Why: timeout-elapsed is the dominant "not open" signal during
        // LAN broadcast scans. The whole point of this probe is "did we get a response
        // before the deadline" — Err(_) (timeout) and Ok(Err(_)) (refused/unreachable)
        // are both legitimate "not open" outcomes; treating them as `false` is the
        // intended behavior and the entire scanner is best-effort.
        .unwrap_or(false)
}

/// Get local subnet prefixes (first 3 octets of local IPs)
fn get_local_subnets() -> Vec<(u8, u8, u8)> {
    let mut subnets = HashSet::new();

    if let Ok(ifaces) = get_if_addrs() {
        for iface in ifaces {
            if iface.is_loopback() {
                continue;
            }

            if let std::net::IpAddr::V4(ip) = iface.ip() {
                let octets = ip.octets();
                subnets.insert((octets[0], octets[1], octets[2]));
            }
        }
    }

    let mut subnets: Vec<_> = subnets.into_iter().collect();
    subnets.sort_unstable();
    subnets
}
