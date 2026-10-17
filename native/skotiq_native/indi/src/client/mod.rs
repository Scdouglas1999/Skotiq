//! INDI client implementation
//!
//! This module provides a robust INDI client with:
//! - Proper error handling using IndiError
//! - Reader task supervision with automatic reconnection
//! - XML parse timeout for incomplete messages
//! - Atomic keepalive operations
//! - BLOB format validation
//! - Property min/max extraction
//! - Permission checking before writes
//! - Protocol version negotiation
//! - Exponential backoff with jitter for reconnection
//! - Configurable timeouts for all operations

use crate::error::{IndiError, IndiResult};
use crate::{
    IndiDevice, IndiPermission, IndiProperty, IndiPropertyState, IndiPropertyType, IndiSwitchRule,
    IndiTimeoutConfig, IndiTimeoutError, INDI_DEFAULT_PORT,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use quick_xml::events::Event;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{broadcast, mpsc, oneshot, RwLock};
use tokio::time::{sleep, timeout, Instant};

mod config;
mod event;
mod health;
mod jitter;
mod properties;
mod reader;
#[cfg(test)]
mod tests;
mod xml;

pub use config::*;
pub use event::*;
use jitter::*;
pub(crate) use xml::*;

/// Supported INDI protocol versions
pub const INDI_PROTOCOL_VERSIONS: &[&str] = &["1.7", "1.8", "1.9"];

/// Default protocol version to use
pub const DEFAULT_PROTOCOL_VERSION: &str = "1.7";

const EVENT_CHANNEL_CAPACITY: usize = 1024;

/// Number element limits (min, max, step)
#[derive(Debug, Clone, Default)]
pub struct NumberLimits {
    pub min: Option<f64>,
    pub max: Option<f64>,
    pub step: Option<f64>,
    pub format: Option<String>,
}

/// Type alias for property value storage
type PropertyValueMap = HashMap<(String, String, String), String>;

/// Type alias for number limits storage
type NumberLimitsMap = HashMap<(String, String, String), NumberLimits>;

/// Type alias for latest BLOB payload storage.
type BlobMap = HashMap<(String, String, String), Vec<u8>>;

/// Milliseconds since UNIX epoch when a property last received a `set*Vector` update.
type PropertyUpdateMap = HashMap<(String, String), u64>;

/// INDI client for communicating with an INDI server
pub struct IndiClient {
    host: String,
    port: u16,
    connected: Arc<AtomicBool>,
    devices: Arc<RwLock<HashMap<String, IndiDevice>>>,
    properties: Arc<RwLock<HashMap<(String, String), IndiProperty>>>,
    property_values: Arc<RwLock<PropertyValueMap>>,
    /// Per-property last server update time (audit ND-/ ND-partial).
    property_updated_ms: Arc<RwLock<PropertyUpdateMap>>,
    number_limits: Arc<RwLock<NumberLimitsMap>>,
    latest_blobs: Arc<RwLock<BlobMap>>,
    tx: Option<mpsc::Sender<String>>,
    event_tx: broadcast::Sender<IndiEvent>,
    timeout_config: IndiTimeoutConfig,
    /// Atomic timestamp for last keepalive sent (milliseconds since UNIX epoch)
    last_keepalive_ms: Arc<AtomicU64>,
    /// Atomic timestamp for last keepalive response received (milliseconds since UNIX epoch)
    last_keepalive_response_ms: Arc<AtomicU64>,
    /// Atomic flag to prevent overlapping keepalive checks
    keepalive_in_progress: Arc<AtomicBool>,
    /// Atomic flag indicating reconnection is in progress
    reconnecting: Arc<AtomicBool>,
    /// Atomic reconnection attempt counter
    reconnect_attempts: Arc<AtomicU32>,
    /// Reader task status
    reader_status: Arc<RwLock<ReaderStatus>>,
    /// Consecutive reader failure count (for supervision)
    reader_consecutive_failures: Arc<AtomicU32>,
    /// Shutdown signal sender
    shutdown_tx: Option<oneshot::Sender<()>>,
    /// Protocol configuration
    protocol_config: ProtocolConfig,
    /// Detected server protocol version
    server_version: Arc<RwLock<Option<String>>>,
    /// Reconnection configuration
    reconnection_config: ReconnectionConfig,
    /// Reader task supervision configuration
    reader_task_config: ReaderTaskConfig,
    /// Per-instance jitter PRNG used for reconnect/restart backoff. See
    /// [`make_jitter_rng`] for the seeding rationale.
    jitter_rng: JitterRng,
}

impl IndiClient {
    /// Create a new INDI client
    pub fn new(host: &str, port: Option<u16>) -> Self {
        Self::with_timeout_config(host, port, IndiTimeoutConfig::default())
    }

    /// Create a new INDI client with custom timeout configuration
    pub fn with_timeout_config(
        host: &str,
        port: Option<u16>,
        timeout_config: IndiTimeoutConfig,
    ) -> Self {
        let (event_tx, _) = broadcast::channel(EVENT_CHANNEL_CAPACITY);
        let now = current_time_ms();
        // Why: `port: Option<u16>` is the caller-supplied override; `None`
        // means "use the INDI default (7624)" — this is the documented constructor contract,
        // not a silent error fallback.
        let resolved_port = port.unwrap_or(INDI_DEFAULT_PORT);
        let jitter_rng = make_jitter_rng(host, resolved_port);
        Self {
            host: host.to_string(),
            port: resolved_port,
            connected: Arc::new(AtomicBool::new(false)),
            devices: Arc::new(RwLock::new(HashMap::new())),
            properties: Arc::new(RwLock::new(HashMap::new())),
            property_values: Arc::new(RwLock::new(HashMap::new())),
            property_updated_ms: Arc::new(RwLock::new(HashMap::new())),
            number_limits: Arc::new(RwLock::new(HashMap::new())),
            latest_blobs: Arc::new(RwLock::new(HashMap::new())),
            tx: None,
            event_tx,
            timeout_config,
            last_keepalive_ms: Arc::new(AtomicU64::new(now)),
            last_keepalive_response_ms: Arc::new(AtomicU64::new(now)),
            keepalive_in_progress: Arc::new(AtomicBool::new(false)),
            reconnecting: Arc::new(AtomicBool::new(false)),
            reconnect_attempts: Arc::new(AtomicU32::new(0)),
            reader_status: Arc::new(RwLock::new(ReaderStatus::Stopped)),
            reader_consecutive_failures: Arc::new(AtomicU32::new(0)),
            shutdown_tx: None,
            protocol_config: ProtocolConfig::default(),
            server_version: Arc::new(RwLock::new(None)),
            reconnection_config: ReconnectionConfig::default(),
            reader_task_config: ReaderTaskConfig::default(),
            jitter_rng,
        }
    }

    /// Create a new INDI client with full configuration
    pub fn with_full_config(
        host: &str,
        port: Option<u16>,
        timeout_config: IndiTimeoutConfig,
        protocol_config: ProtocolConfig,
        reconnection_config: ReconnectionConfig,
    ) -> Self {
        Self::with_all_config(
            host,
            port,
            timeout_config,
            protocol_config,
            reconnection_config,
            ReaderTaskConfig::default(),
        )
    }

    /// Create a new INDI client with all configuration options including reader task config
    pub fn with_all_config(
        host: &str,
        port: Option<u16>,
        timeout_config: IndiTimeoutConfig,
        protocol_config: ProtocolConfig,
        reconnection_config: ReconnectionConfig,
        reader_task_config: ReaderTaskConfig,
    ) -> Self {
        let (event_tx, _) = broadcast::channel(EVENT_CHANNEL_CAPACITY);
        let now = current_time_ms();
        // Why: `port: Option<u16>` is the caller-supplied override; `None`
        // means "use the INDI default (7624)" — this is the documented constructor contract,
        // not a silent error fallback.
        let resolved_port = port.unwrap_or(INDI_DEFAULT_PORT);
        let jitter_rng = make_jitter_rng(host, resolved_port);
        Self {
            host: host.to_string(),
            port: resolved_port,
            connected: Arc::new(AtomicBool::new(false)),
            devices: Arc::new(RwLock::new(HashMap::new())),
            properties: Arc::new(RwLock::new(HashMap::new())),
            property_values: Arc::new(RwLock::new(HashMap::new())),
            property_updated_ms: Arc::new(RwLock::new(HashMap::new())),
            number_limits: Arc::new(RwLock::new(HashMap::new())),
            latest_blobs: Arc::new(RwLock::new(HashMap::new())),
            tx: None,
            event_tx,
            timeout_config,
            last_keepalive_ms: Arc::new(AtomicU64::new(now)),
            last_keepalive_response_ms: Arc::new(AtomicU64::new(now)),
            keepalive_in_progress: Arc::new(AtomicBool::new(false)),
            reconnecting: Arc::new(AtomicBool::new(false)),
            reconnect_attempts: Arc::new(AtomicU32::new(0)),
            reader_status: Arc::new(RwLock::new(ReaderStatus::Stopped)),
            reader_consecutive_failures: Arc::new(AtomicU32::new(0)),
            shutdown_tx: None,
            protocol_config,
            server_version: Arc::new(RwLock::new(None)),
            reconnection_config,
            reader_task_config,
            jitter_rng,
        }
    }

    /// Get the timeout configuration
    pub fn timeout_config(&self) -> &IndiTimeoutConfig {
        &self.timeout_config
    }

    /// Set the timeout configuration
    pub fn set_timeout_config(&mut self, config: IndiTimeoutConfig) {
        self.timeout_config = config;
    }

    /// Get the protocol configuration
    pub fn protocol_config(&self) -> &ProtocolConfig {
        &self.protocol_config
    }

    /// Set the protocol configuration
    pub fn set_protocol_config(&mut self, config: ProtocolConfig) {
        self.protocol_config = config;
    }

    /// Get the reconnection configuration
    pub fn reconnection_config(&self) -> &ReconnectionConfig {
        &self.reconnection_config
    }

    /// Set the reconnection configuration
    pub fn set_reconnection_config(&mut self, config: ReconnectionConfig) {
        self.reconnection_config = config;
    }

    /// Get the reader task configuration
    pub fn reader_task_config(&self) -> &ReaderTaskConfig {
        &self.reader_task_config
    }

    /// Set the reader task configuration
    pub fn set_reader_task_config(&mut self, config: ReaderTaskConfig) {
        self.reader_task_config = config;
    }

    /// Get the detected server protocol version
    pub async fn server_version(&self) -> Option<String> {
        self.server_version.read().await.clone()
    }

    /// Get the detected server protocol version as a Result
    /// Returns Ok with the version string if available, or Err if not detected
    pub async fn get_server_version(&self) -> IndiResult<String> {
        self.server_version
            .read()
            .await
            .clone()
            .ok_or_else(|| IndiError::ProtocolError("Server version not detected".to_string()))
    }

    /// Subscribe to INDI events
    pub fn subscribe(&self) -> broadcast::Receiver<IndiEvent> {
        self.event_tx.subscribe()
    }

    pub async fn clear_blob(&self, device: &str, property: &str, element: &str) {
        self.latest_blobs.write().await.remove(&(
            device.to_string(),
            property.to_string(),
            element.to_string(),
        ));
    }

    pub async fn take_blob(&self, device: &str, property: &str, element: &str) -> Option<Vec<u8>> {
        self.latest_blobs.write().await.remove(&(
            device.to_string(),
            property.to_string(),
            element.to_string(),
        ))
    }

    /// Connect to the INDI server
    pub async fn connect(&mut self) -> IndiResult<()> {
        let addr = format!("{}:{}", self.host, self.port);
        let connection_timeout = self.timeout_config.connection_timeout();

        // Apply connection timeout
        let stream = match timeout(connection_timeout, TcpStream::connect(&addr)).await {
            Ok(Ok(stream)) => stream,
            Ok(Err(e)) => {
                return Err(IndiError::ConnectionFailed(format!(
                    "Failed to connect to INDI server at {}: {}. Check that the server is running and the address is correct.",
                    addr, e
                )));
            }
            Err(_) => {
                return Err(IndiError::ConnectionTimeout {
                    host: self.host.clone(),
                    port: self.port,
                    duration: connection_timeout,
                });
            }
        };

        let (read_half, write_half) = stream.into_split();

        // Create channel for sending commands
        let (tx, rx) = mpsc::channel::<String>(100);
        self.tx = Some(tx);

        // Create shutdown channel for reader task supervision
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        self.shutdown_tx = Some(shutdown_tx);

        // Spawn writer task
        tokio::spawn(Self::writer_task(
            write_half,
            rx,
            self.connected.clone(),
            self.event_tx.clone(),
        ));

        // Reset keepalive state before spawning reader task
        // This prevents stale keepalive data from causing false disconnections
        let now = current_time_ms();
        self.last_keepalive_ms.store(now, Ordering::SeqCst);
        self.last_keepalive_response_ms.store(now, Ordering::SeqCst);
        self.keepalive_in_progress.store(false, Ordering::SeqCst);

        // Spawn supervised reader task
        let devices = self.devices.clone();
        let properties = self.properties.clone();
        let property_values = self.property_values.clone();
        let property_updated_ms = self.property_updated_ms.clone();
        let number_limits = self.number_limits.clone();
        let latest_blobs = self.latest_blobs.clone();
        let connected = self.connected.clone();
        let event_tx = self.event_tx.clone();
        let reader_status = self.reader_status.clone();
        let reader_consecutive_failures = self.reader_consecutive_failures.clone();
        let server_version = self.server_version.clone();
        let last_keepalive_response_ms = self.last_keepalive_response_ms.clone();
        let timeout_config = self.timeout_config.clone();
        let reader_task_config = self.reader_task_config.clone();
        // Clone the per-instance jitter PRNG handle so the supervised reader
        // task can compute its own restart-delay jitter without falling back
        // to a shared global PRNG.
        let jitter_rng = self.jitter_rng.clone();

        // Reset consecutive failures on successful connect
        self.reader_consecutive_failures.store(0, Ordering::SeqCst);

        // Update reader status
        *self.reader_status.write().await = ReaderStatus::Running;

        // Emit health changed event - reader is now healthy
        send_indi_event(
            &self.event_tx,
            IndiEvent::ReaderHealthChanged {
                healthy: true,
                status: ReaderStatus::Running,
                consecutive_failures: 0,
            },
            "connect.reader_health_running",
        );

        tokio::spawn(async move {
            Self::supervised_reader_task(
                read_half,
                devices,
                properties,
                property_values,
                property_updated_ms,
                number_limits,
                latest_blobs,
                connected,
                event_tx,
                reader_status,
                reader_consecutive_failures,
                server_version,
                last_keepalive_response_ms,
                timeout_config,
                reader_task_config,
                jitter_rng,
                shutdown_rx,
            )
            .await;
        });

        // Mark as connected
        self.connected.store(true, Ordering::SeqCst);
        send_indi_event(
            &self.event_tx,
            IndiEvent::ConnectionStateChanged(true),
            "connect.connection_state_connected",
        );

        // Request device list with configured protocol version
        let version = &self.protocol_config.preferred_version;
        self.send_command(&format!("<getProperties version=\"{}\"/>", version))
            .await?;

        Ok(())
    }

    /// Disconnect from the INDI server
    ///
    /// This performs a graceful shutdown:
    /// 1. Sends shutdown signal to reader task
    /// 2. Closes the writer channel
    /// 3. Clears all cached device/property state
    /// 4. Resets failure counters and keepalive state (since this is intentional disconnect)
    /// 5. Emits connection state change event
    pub async fn disconnect(&mut self) -> IndiResult<()> {
        tracing::info!("Disconnecting from INDI server {}:{}", self.host, self.port);

        // Send shutdown signal to reader task
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(());
        }

        self.tx = None; // Drop sender, which will close the writer task
        self.connected.store(false, Ordering::SeqCst);

        // Clear cached state. `latest_blobs` holds a whole decoded frame and
        // `property_updated_ms` feeds staleness checks that would otherwise read
        // pre-disconnect timestamps as fresh after a reconnect.
        self.devices.write().await.clear();
        self.properties.write().await.clear();
        self.property_values.write().await.clear();
        self.property_updated_ms.write().await.clear();
        self.number_limits.write().await.clear();
        self.latest_blobs.write().await.clear();

        // Reset failure counter since this is intentional disconnect
        self.reader_consecutive_failures.store(0, Ordering::SeqCst);

        // Reset keepalive state to clean up any in-flight keepalive checks
        self.keepalive_in_progress.store(false, Ordering::SeqCst);
        self.reconnecting.store(false, Ordering::SeqCst);
        self.reconnect_attempts.store(0, Ordering::SeqCst);

        // Update reader status
        *self.reader_status.write().await = ReaderStatus::Stopped;

        // Emit events
        send_indi_event(
            &self.event_tx,
            IndiEvent::ReaderHealthChanged {
                healthy: false,
                status: ReaderStatus::Stopped,
                consecutive_failures: 0,
            },
            "disconnect.reader_health_stopped",
        );
        send_indi_event(
            &self.event_tx,
            IndiEvent::ConnectionStateChanged(false),
            "disconnect.connection_state_disconnected",
        );

        Ok(())
    }

    /// Check if connected
    pub async fn is_connected(&self) -> bool {
        self.connected.load(Ordering::SeqCst)
    }

    /// Get reader task status
    pub async fn reader_status(&self) -> ReaderStatus {
        *self.reader_status.read().await
    }

    /// Check if the reader task is healthy (running with no recent failures)
    ///
    /// Returns true if:
    /// - Reader status is Running
    /// - Consecutive failure count is 0
    ///
    /// Returns false if:
    /// - Reader is Stopped, Crashed, or Restarting
    /// - There have been any consecutive failures (even if currently running)
    pub fn is_reader_healthy(&self) -> bool {
        // Non-async version for quick health checks
        let failures = self.reader_consecutive_failures.load(Ordering::SeqCst);
        failures == 0 && self.connected.load(Ordering::SeqCst)
    }

    /// Get the number of consecutive reader failures
    pub fn reader_consecutive_failures(&self) -> u32 {
        self.reader_consecutive_failures.load(Ordering::SeqCst)
    }

    /// Check if the reader has exceeded the maximum failure threshold
    pub fn is_reader_failed_permanently(&self) -> bool {
        let failures = self.reader_consecutive_failures.load(Ordering::SeqCst);
        failures >= self.reader_task_config.max_consecutive_failures
    }

    /// Reset the consecutive failure counter (call after successful manual recovery)
    pub fn reset_reader_failures(&self) {
        self.reader_consecutive_failures.store(0, Ordering::SeqCst);
    }

    /// Send a raw INDI command
    pub async fn send_command(&mut self, command: &str) -> IndiResult<()> {
        if let Some(tx) = &self.tx {
            tx.send(command.to_string()).await.map_err(|e| {
                IndiError::ChannelClosed(format!(
                    "Failed to send INDI command to {}:{}: {}. The connection may have been lost.",
                    self.host, self.port, e
                ))
            })
        } else {
            Err(IndiError::NotConnected)
        }
    }
}

impl Default for IndiClient {
    fn default() -> Self {
        Self::new("localhost", None)
    }
}
