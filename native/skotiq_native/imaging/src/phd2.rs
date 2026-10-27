//! Real PHD2 Guiding Integration
//!
//! Implements the PHD2 server protocol for communication with PHD2.
//! PHD2 uses a JSON-RPC style protocol over TCP on port 4400.
//!
//! Reference: https://github.com/OpenPHDGuiding/phd2/wiki/EventMonitoring

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Normalize a PHD2 TCP host for reliable local connections.
///
/// On Windows, `localhost` often resolves to `::1` while PHD2 listens on IPv4
/// `127.0.0.1`, which makes port probes fail and triggers duplicate launches.
pub fn normalize_phd2_tcp_host(host: &str) -> String {
    match host.trim().to_lowercase().as_str() {
        "" | "localhost" | "::1" => "127.0.0.1".to_string(),
        other => other.to_string(),
    }
}

/// Returns true when PHD2's event server accepts TCP connections on [host]:[port].
pub fn is_phd2_server_listening(host: &str, port: u16) -> bool {
    let host = normalize_phd2_tcp_host(host);
    let Ok(addr) = format!("{host}:{port}").parse() else {
        return false;
    };
    TcpStream::connect_timeout(&addr, Duration::from_millis(500)).is_ok()
}

/// PHD2 connection state
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Phd2State {
    /// Not connected to PHD2
    Disconnected,
    /// Connected but not guiding
    Connected,
    /// Calibrating
    Calibrating,
    /// Guiding
    Guiding,
    /// Looping (exposures without guiding)
    Looping,
    /// Paused
    Paused,
    /// Settling after dither
    Settling,
    /// Lost lock on guide star
    LostLock,
    /// PHD2 reported a state name we do not recognise. Preserves the raw
    /// string so callers can log or surface it instead of being lied to with
    /// a synthesised `Connected`.
    ///
    /// Why: PHD2 adds states over time (e.g. `GuidingPaused`, `StarFound`),
    /// and mapping an unknown one to `Connected` hides a guiding regression
    /// until the session-end review.
    Unknown(String),
}

/// PHD2 guide statistics
#[derive(Debug, Clone, Default)]
pub struct GuideStats {
    /// RMS error in RA (arcseconds)
    pub rms_ra: f64,
    /// RMS error in Dec (arcseconds)
    pub rms_dec: f64,
    /// Total RMS error (arcseconds)
    pub rms_total: f64,
    /// Peak RA error (arcseconds)
    pub peak_ra: f64,
    /// Peak Dec error (arcseconds)
    pub peak_dec: f64,
    /// Number of guide frames
    pub frame_count: u32,
    /// SNR of guide star
    pub snr: f64,
    /// Guide star mass (brightness)
    pub star_mass: f64,
}

/// Star image data from PHD2
#[derive(Debug, Clone)]
pub struct StarImageData {
    /// Frame number
    pub frame: u32,
    /// Image width in pixels
    pub width: u32,
    /// Image height in pixels
    pub height: u32,
    /// Star centroid X position within the subframe
    pub star_x: f64,
    /// Star centroid Y position within the subframe
    pub star_y: f64,
    /// Raw pixel data (16-bit grayscale, row-major)
    pub pixels: Vec<u8>,
}

/// PHD2 Brain algorithm parameter
#[derive(Debug, Clone)]
pub struct AlgoParam {
    /// Parameter name
    pub name: String,
    /// Parameter value
    pub value: f64,
}

/// Rolling statistics calculator for guide frames
/// Uses Welford's online algorithm for numerically stable variance calculation
#[derive(Debug, Clone)]
pub struct RollingGuideStats {
    /// Maximum number of samples to keep
    max_samples: usize,
    /// Recent RA errors
    ra_samples: Vec<f64>,
    /// Recent Dec errors
    dec_samples: Vec<f64>,
    /// Recent SNR values
    snr_samples: Vec<f64>,
    /// Recent star masses
    mass_samples: Vec<f64>,
    /// Running count of all frames
    total_frame_count: u32,
    /// Peak RA error seen
    peak_ra: f64,
    /// Peak Dec error seen
    peak_dec: f64,
    /// Last calculated stats
    cached_stats: GuideStats,
    /// Whether cache is valid
    cache_valid: bool,
}

impl Default for RollingGuideStats {
    fn default() -> Self {
        Self::new(100) // Default to 100 sample window
    }
}

impl RollingGuideStats {
    /// Create a new rolling stats calculator with specified window size
    pub fn new(max_samples: usize) -> Self {
        Self {
            max_samples,
            ra_samples: Vec::with_capacity(max_samples),
            dec_samples: Vec::with_capacity(max_samples),
            snr_samples: Vec::with_capacity(max_samples),
            mass_samples: Vec::with_capacity(max_samples),
            total_frame_count: 0,
            peak_ra: 0.0,
            peak_dec: 0.0,
            cached_stats: GuideStats::default(),
            cache_valid: false,
        }
    }

    /// Add a new guide frame to the rolling statistics
    pub fn add_frame(&mut self, frame: &GuideFrame) {
        self.total_frame_count += 1;
        self.cache_valid = false;

        // Add samples, removing oldest if at capacity
        if self.ra_samples.len() >= self.max_samples {
            self.ra_samples.remove(0);
            self.dec_samples.remove(0);
            self.snr_samples.remove(0);
            self.mass_samples.remove(0);
        }

        self.ra_samples.push(frame.ra_distance);
        self.dec_samples.push(frame.dec_distance);
        self.snr_samples.push(frame.snr);
        self.mass_samples.push(frame.star_mass);

        // Track peak errors
        let ra_abs = frame.ra_distance.abs();
        let dec_abs = frame.dec_distance.abs();
        if ra_abs > self.peak_ra {
            self.peak_ra = ra_abs;
        }
        if dec_abs > self.peak_dec {
            self.peak_dec = dec_abs;
        }
    }

    /// Calculate current statistics
    pub fn get_stats(&mut self) -> GuideStats {
        if self.cache_valid {
            return self.cached_stats.clone();
        }

        let n = self.ra_samples.len();
        if n == 0 {
            return GuideStats::default();
        }

        // Calculate RMS for RA
        let ra_sum_sq: f64 = self.ra_samples.iter().map(|x| x * x).sum();
        let rms_ra = (ra_sum_sq / n as f64).sqrt();

        // Calculate RMS for Dec
        let dec_sum_sq: f64 = self.dec_samples.iter().map(|x| x * x).sum();
        let rms_dec = (dec_sum_sq / n as f64).sqrt();

        // Total RMS (pythagorean)
        let rms_total = (rms_ra * rms_ra + rms_dec * rms_dec).sqrt();

        // Average SNR
        let snr = self.snr_samples.iter().sum::<f64>() / n as f64;
        let star_mass = self.mass_samples.iter().sum::<f64>() / n as f64;

        self.cached_stats = GuideStats {
            rms_ra,
            rms_dec,
            rms_total,
            peak_ra: self.peak_ra,
            peak_dec: self.peak_dec,
            frame_count: self.total_frame_count,
            snr,
            star_mass,
        };
        self.cache_valid = true;

        self.cached_stats.clone()
    }

    /// Reset all statistics
    pub fn reset(&mut self) {
        self.ra_samples.clear();
        self.dec_samples.clear();
        self.snr_samples.clear();
        self.mass_samples.clear();
        self.total_frame_count = 0;
        self.peak_ra = 0.0;
        self.peak_dec = 0.0;
        self.cache_valid = false;
    }

    /// Get the number of samples in the rolling window
    pub fn sample_count(&self) -> usize {
        self.ra_samples.len()
    }
}

/// Connection configuration for auto-reconnect
#[derive(Debug, Clone)]
pub struct Phd2ConnectionConfig {
    /// Maximum number of reconnection attempts
    pub max_reconnect_attempts: u32,
    /// Initial delay between reconnection attempts (ms)
    pub initial_reconnect_delay_ms: u64,
    /// Maximum delay between reconnection attempts (ms)
    pub max_reconnect_delay_ms: u64,
    /// Whether to auto-reconnect on disconnect
    pub auto_reconnect: bool,
}

impl Default for Phd2ConnectionConfig {
    fn default() -> Self {
        Self {
            max_reconnect_attempts: 5,
            initial_reconnect_delay_ms: 1000,
            max_reconnect_delay_ms: 30000,
            auto_reconnect: true,
        }
    }
}

/// PHD2 guide frame data
#[derive(Debug, Clone)]
pub struct GuideFrame {
    /// Frame number
    pub frame: u32,
    /// Timestamp
    pub timestamp: f64,
    /// RA offset in arcseconds
    pub ra_distance: f64,
    /// Dec offset in arcseconds
    pub dec_distance: f64,
    /// RA guide pulse duration (ms)
    pub ra_duration: i32,
    /// Dec guide pulse duration (ms)
    pub dec_duration: i32,
    /// RA guide direction ("East" or "West")
    pub ra_direction: String,
    /// Dec guide direction ("North" or "South")
    pub dec_direction: String,
    /// Guide star SNR
    pub snr: f64,
    /// Guide star mass (brightness)
    pub star_mass: f64,
    /// Star position X
    pub star_x: f64,
    /// Star position Y
    pub star_y: f64,
    /// Average distance (RMS)
    pub avg_dist: f64,
}

/// Events from PHD2
#[derive(Debug, Clone)]
pub enum Phd2Event {
    /// State changed
    StateChanged(Phd2State),
    /// New guide frame
    GuideStep(GuideFrame),
    /// Settling started
    SettleBegin,
    /// Settling complete
    SettleDone {
        /// PHD2 settle status: 0 = success, non-zero = settle failed.
        status: i32,
        /// Human-readable error string when `status != 0` (empty on success).
        error: String,
        total_frames: u32,
        dropped_frames: u32,
    },
    /// Star lost
    StarLost,
    /// Star selected
    StarSelected { x: f64, y: f64 },
    /// Calibration complete
    CalibrationComplete,
    /// Alert from PHD2
    Alert { message: String, alert_type: String },
    /// Connection lost
    Disconnected,
    /// Error occurred
    Error(String),
}

/// PHD2 JSON-RPC messages
#[derive(Serialize)]
struct JsonRpcRequest {
    method: String,
    /// PHD2 rejects `"params": null` (-32600). Omit the field when there are
    /// no parameters (matches PHD2 wiki examples: `{"method":"…","id":N}`).
    #[serde(skip_serializing_if = "Option::is_none")]
    params: Option<serde_json::Value>,
    id: u32,
}

#[derive(Deserialize, Debug)]
struct JsonRpcResponse {
    result: Option<serde_json::Value>,
    error: Option<JsonRpcError>,
}

#[derive(Deserialize, Debug)]
struct JsonRpcError {
    #[allow(dead_code)]
    code: i32,
    message: String,
}

#[derive(Deserialize, Debug)]
#[allow(dead_code)]
struct Phd2EventMessage {
    #[serde(rename = "Event")]
    event: String,
    #[serde(rename = "Timestamp")]
    timestamp: Option<f64>,
    #[serde(rename = "Host")]
    host: Option<String>,
    #[serde(rename = "Inst")]
    inst: Option<u32>,
    // Event-specific fields stored in remaining
    #[serde(flatten)]
    extra: serde_json::Value,
}

type Phd2EventCallback = Arc<Mutex<dyn Fn(Phd2Event) + Send>>;

/// Outcome of a PHD2 settle (after `guide` or `dither`), populated by the
/// reader thread when a `SettleDone` event arrives.
#[derive(Debug, Clone)]
pub struct SettleOutcome {
    /// PHD2 settle status: 0 = success, non-zero = failed.
    pub status: i32,
    /// Error string when the settle failed (empty on success).
    pub error: String,
    pub total_frames: u32,
    pub dropped_frames: u32,
}

/// A detached handle that can wait for the current settle to complete WITHOUT
/// borrowing the `Phd2Client`.
///
/// Why: the bridge's `api_phd2_dither` holds a global async write-lock over the
/// PHD2 client storage. Blocking on the multi-second settle while holding that
/// lock would stall every other PHD2 operation (status polls, stop, etc.). The
/// bridge instead issues the dither RPC under the lock, takes one of these
/// handles (which only clones the shared `Arc`s), releases the storage lock,
/// and polls the handle on a blocking task.
#[derive(Clone)]
pub struct SettleWaiter {
    settle_tracker: Arc<Mutex<SettleTracker>>,
    running: Arc<AtomicBool>,
    state: Arc<Mutex<Phd2State>>,
    generation: u64,
}

impl SettleWaiter {
    /// The settle's result if it is decided: PHD2 reported `SettleDone`, the
    /// settle was superseded, or PHD2 disconnected. `None` while it runs.
    ///
    /// Same fail-closed contract as [`Self::wait`]: a non-zero PHD2 status,
    /// a disconnect or a superseding settle are `Err`.
    pub fn check(&self) -> Option<Result<SettleOutcome, String>> {
        {
            let mut tracker = match self.settle_tracker.lock() {
                Ok(t) => t,
                Err(poison) => poison.into_inner(),
            };
            if tracker.generation != self.generation {
                return Some(Err(format!(
                    "PHD2 settle wait superseded (expected generation {}, found {})",
                    self.generation, tracker.generation
                )));
            }
            if let Some(outcome) = tracker.outcome.take() {
                tracker.awaiting = false;
                if outcome.status == 0 {
                    return Some(Ok(outcome));
                }
                return Some(Err(format!(
                    "PHD2 settle failed (status {}): {}",
                    outcome.status,
                    if outcome.error.is_empty() {
                        "no error detail"
                    } else {
                        outcome.error.as_str()
                    }
                )));
            }
        }
        if !self.running.load(Ordering::SeqCst) {
            return Some(Err("PHD2 disconnected while waiting for settle".to_string()));
        }
        None
    }

    /// Whether PHD2 is calibrating. PHD2 starts its settle clock only once
    /// calibration is done, so a wait for the settle must not count it.
    pub fn is_calibrating(&self) -> bool {
        let state = match self.state.lock() {
            Ok(state) => state,
            Err(poison) => poison.into_inner(),
        };
        matches!(*state, Phd2State::Calibrating)
    }

    /// Block until the armed settle completes or [timeout] elapses.
    ///
    /// Fail closed: non-zero PHD2 status, timeout, disconnect, or a
    /// superseding settle all return `Err`.
    pub fn wait(&self, timeout: Duration) -> Result<SettleOutcome, String> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(result) = self.check() {
                return result;
            }
            if Instant::now() >= deadline {
                return Err(format!(
                    "PHD2 settle did not complete within {:.1}s",
                    timeout.as_secs_f64()
                ));
            }
            thread::sleep(Duration::from_millis(100));
        }
    }
}

/// Tracks the in-flight settle so a caller (e.g. `dither`) can block until
/// PHD2 asynchronously reports completion via `SettleDone`.
///
/// Why: PHD2's `dither`/`guide` RPCs return immediately; the actual settle
/// completes seconds later and is announced ONLY by the `SettleDone` event on
/// the event channel. Without correlating the RPC with that event, the
/// sequencer resumed exposing mid-settle and trailed every sub after a dither.
#[derive(Debug, Default)]
struct SettleTracker {
    /// Monotonic generation incremented each time a settle is armed. The
    /// reader thread only records an outcome whose generation matches, so a
    /// stale `SettleDone` from a previous/aborted settle cannot satisfy a new
    /// wait.
    generation: u64,
    /// Whether a settle is currently armed and awaiting `SettleDone`.
    awaiting: bool,
    /// The outcome of the most recent settle for the armed generation.
    outcome: Option<SettleOutcome>,
}

/// The star PHD2 measured in a looping frame once a star is selected.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LoopingStar {
    /// This connection's count of looping frames when the star was measured
    /// (see [`Phd2Client::looping_frame_count`]).
    pub frame: u64,
    pub snr: f64,
    pub star_mass: f64,
}

/// Looping frames received on a connection, and the star the latest one
/// measured.
#[derive(Debug, Default)]
struct LoopingFrames {
    count: std::sync::atomic::AtomicU64,
    star: Mutex<Option<LoopingStar>>,
}

impl LoopingFrames {
    /// Count a `LoopingExposures` event. PHD2 adds `SNR` and `StarMass` only
    /// when a star is selected; a frame without them clears the last star.
    fn record(&self, extra: &serde_json::Value) {
        let frame = self.count.fetch_add(1, Ordering::SeqCst) + 1;
        let field = |name: &str| extra.get(name).and_then(|v| v.as_f64());
        let star = match (field("SNR"), field("StarMass")) {
            (Some(snr), Some(star_mass)) => Some(LoopingStar {
                frame,
                snr,
                star_mass,
            }),
            _ => None,
        };
        match self.star.lock() {
            Ok(mut last) => *last = star,
            Err(poison) => *poison.into_inner() = star,
        }
    }
}

/// PHD2 client for real guiding control.
///
/// Uses a single reader thread for the TCP socket to avoid race conditions
/// between event monitoring and RPC request/response handling.
/// The reader thread routes:
///   - JSON-RPC responses (messages with "id") to pending request waiters
///   - PHD2 events (messages with "Event") to the event callback
pub struct Phd2Client {
    /// Write half of the TCP stream for sending commands
    write_stream: Option<TcpStream>,
    /// Explicit disconnect disables automatic transport recovery.
    connection_wanted: bool,
    received_lines: Arc<std::sync::atomic::AtomicU64>,
    host: String,
    port: u16,
    request_id: u32,
    running: Arc<AtomicBool>,
    event_callback: Option<Phd2EventCallback>,
    /// Rolling guide statistics
    rolling_stats: Arc<Mutex<RollingGuideStats>>,
    /// Connection configuration
    config: Phd2ConnectionConfig,
    /// Current connection state
    state: Arc<Mutex<Phd2State>>,
    /// Number of reconnection attempts
    reconnect_attempts: Arc<std::sync::atomic::AtomicU32>,
    /// Registry of pending RPC response senders, keyed by request ID.
    /// The reader thread sends response lines to the matching sender.
    response_registry: Arc<Mutex<HashMap<u32, mpsc::Sender<String>>>>,
    /// Suppress `Phd2Event::Disconnected` while we intentionally tear down the socket.
    suppress_disconnect_events: Arc<AtomicBool>,
    /// Tracks the in-flight settle so `dither`/`wait_for_settle` can block on
    /// PHD2's asynchronous `SettleDone` event and fail closed on failure.
    settle_tracker: Arc<Mutex<SettleTracker>>,
    looping: Arc<LoopingFrames>,
}

impl Phd2Client {
    /// Create a new PHD2 client
    pub fn new(host: &str, port: u16) -> Self {
        Self {
            write_stream: None,
            connection_wanted: false,
            received_lines: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            host: normalize_phd2_tcp_host(host),
            port,
            request_id: 0,
            running: Arc::new(AtomicBool::new(false)),
            event_callback: None,
            rolling_stats: Arc::new(Mutex::new(RollingGuideStats::default())),
            config: Phd2ConnectionConfig::default(),
            state: Arc::new(Mutex::new(Phd2State::Disconnected)),
            reconnect_attempts: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            response_registry: Arc::new(Mutex::new(HashMap::new())),
            suppress_disconnect_events: Arc::new(AtomicBool::new(false)),
            settle_tracker: Arc::new(Mutex::new(SettleTracker::default())),
            looping: Arc::new(LoopingFrames::default()),
        }
    }

    /// Create a new PHD2 client with custom configuration
    pub fn with_config(host: &str, port: u16, config: Phd2ConnectionConfig) -> Self {
        Self {
            write_stream: None,
            connection_wanted: false,
            received_lines: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            host: normalize_phd2_tcp_host(host),
            port,
            request_id: 0,
            running: Arc::new(AtomicBool::new(false)),
            event_callback: None,
            rolling_stats: Arc::new(Mutex::new(RollingGuideStats::default())),
            config,
            state: Arc::new(Mutex::new(Phd2State::Disconnected)),
            reconnect_attempts: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            response_registry: Arc::new(Mutex::new(HashMap::new())),
            suppress_disconnect_events: Arc::new(AtomicBool::new(false)),
            settle_tracker: Arc::new(Mutex::new(SettleTracker::default())),
            looping: Arc::new(LoopingFrames::default()),
        }
    }

    /// Connect to PHD2 on localhost with default port
    pub fn localhost() -> Self {
        Self::new("127.0.0.1", 4400)
    }

    /// Get rolling guide statistics
    pub fn get_rolling_stats(&self) -> GuideStats {
        // Why: `std::sync::Mutex::lock()` only fails on
        // *poison* (a previous holder panicked while the guard was live).
        // The lock holders here (`add_frame`, `get_stats`, `reset`) are pure
        // arithmetic — none can panic in production. If poison ever does
        // occur the runtime is already in an unrecoverable state; returning
        // default zeroed stats keeps the UI from crashing while the warning
        // emitted at the poison site (reader thread) surfaces the cause.
        match self.rolling_stats.lock() {
            Ok(mut s) => s.get_stats(),
            Err(poison) => {
                tracing::error!(
                    "PHD2: rolling_stats mutex poisoned: {} — returning zeroed GuideStats",
                    poison
                );
                GuideStats::default()
            }
        }
    }

    /// Reset rolling guide statistics
    pub fn reset_stats(&self) {
        if let Ok(mut stats) = self.rolling_stats.lock() {
            stats.reset();
        }
    }

    /// Get current connection state
    pub fn get_state(&self) -> Phd2State {
        // Why: Mutex poison here would mean the reader
        // thread crashed mid-update. The TCP connection is therefore
        // effectively dead from our side regardless of the device's view;
        // reporting `Disconnected` matches reality. We log so the operator
        // can correlate the poison with whatever caused the reader panic.
        match self.state.lock() {
            Ok(s) => s.clone(),
            Err(poison) => {
                tracing::error!(
                    "PHD2: state mutex poisoned: {} — reporting Disconnected",
                    poison
                );
                Phd2State::Disconnected
            }
        }
    }

    /// Set event callback
    pub fn set_event_callback<F>(&mut self, callback: F)
    where
        F: Fn(Phd2Event) + Send + 'static,
    {
        self.event_callback = Some(Arc::new(Mutex::new(callback)));
    }

    /// Attempt to reconnect with exponential backoff
    pub fn reconnect(&mut self) -> Result<(), String> {
        if !self.config.auto_reconnect {
            return Err("Auto-reconnect is disabled".to_string());
        }

        let max_attempts = self.config.max_reconnect_attempts;
        let mut delay = self.config.initial_reconnect_delay_ms;

        for attempt in 1..=max_attempts {
            self.reconnect_attempts
                .store(attempt, std::sync::atomic::Ordering::SeqCst);
            tracing::info!("PHD2 reconnection attempt {}/{}", attempt, max_attempts);

            match self.connect() {
                Ok(()) => {
                    self.reconnect_attempts
                        .store(0, std::sync::atomic::Ordering::SeqCst);
                    tracing::info!("PHD2 reconnection successful");
                    return Ok(());
                }
                Err(e) => {
                    tracing::warn!("PHD2 reconnection failed: {}", e);
                    if attempt < max_attempts {
                        std::thread::sleep(Duration::from_millis(delay));
                        // Exponential backoff with cap
                        delay = (delay * 2).min(self.config.max_reconnect_delay_ms);
                    }
                }
            }
        }

        Err(format!(
            "Failed to reconnect after {} attempts",
            max_attempts
        ))
    }

    /// Wait until PHD2 responds to RPC after the TCP connection is established.
    ///
    /// PHD2 sends initial event messages on connect; the server may not answer
    /// RPC until that burst completes. Retries avoid racing `get_app_state`.
    pub fn wait_until_ready(&mut self, timeout: Duration) -> Result<(), String> {
        let deadline = Instant::now() + timeout;
        let mut last_error = String::from("PHD2 did not respond");

        while Instant::now() < deadline {
            match self.get_app_state() {
                Ok(_) => return Ok(()),
                Err(e) => {
                    last_error = e;
                    std::thread::sleep(Duration::from_millis(200));
                }
            }
        }

        Err(format!(
            "PHD2 did not become ready within {}s: {}",
            timeout.as_secs(),
            last_error
        ))
    }

    /// Connect to PHD2
    pub fn connect(&mut self) -> Result<(), String> {
        self.close_transport();
        self.connection_wanted = true;

        let addr = format!("{}:{}", self.host, self.port);
        tracing::info!("Connecting to PHD2 at {}", addr);

        let stream = TcpStream::connect_timeout(
            &addr
                .parse()
                .map_err(|e| format!("Invalid address: {}", e))?,
            Duration::from_secs(5),
        )
        .map_err(|e| format!("Failed to connect to PHD2: {}", e))?;

        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .map_err(|e| format!("Failed to set write timeout: {e}"))?;

        // Clone the stream: one for reading (event listener), one for writing (commands)
        let read_stream = stream
            .try_clone()
            .map_err(|e| format!("Failed to clone stream for reader: {}", e))?;
        read_stream
            .set_read_timeout(Some(Duration::from_millis(100)))
            .map_err(|e| format!("Failed to set read timeout: {}", e))?;

        // A retired reader and any outstanding settle waiter retain the old
        // connection's state. They must never mark a replacement disconnected
        // or complete a settle belonging to the new connection.
        self.running = Arc::new(AtomicBool::new(true));
        self.suppress_disconnect_events = Arc::new(AtomicBool::new(false));
        self.state = Arc::new(Mutex::new(Phd2State::Connected));
        self.response_registry = Arc::new(Mutex::new(HashMap::new()));
        self.settle_tracker = Arc::new(Mutex::new(SettleTracker::default()));
        self.looping = Arc::new(LoopingFrames::default());
        self.rolling_stats = Arc::new(Mutex::new(RollingGuideStats::default()));
        self.received_lines = Arc::new(std::sync::atomic::AtomicU64::new(0));
        self.write_stream = Some(stream);

        // Start event listener thread with the dedicated read stream
        self.start_event_listener(read_stream);

        tracing::info!("Connected to PHD2");
        Ok(())
    }

    /// Disconnect from PHD2
    pub fn disconnect(&mut self) {
        self.connection_wanted = false;
        self.close_transport();
    }

    /// Retire this connection without changing the operator's connect intent.
    fn close_transport(&mut self) {
        self.suppress_disconnect_events
            .store(true, std::sync::atomic::Ordering::SeqCst);
        self.running.store(false, Ordering::SeqCst);
        if let Some(stream) = self.write_stream.take() {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }

        // Clear any pending response waiters so they don't hang
        if let Ok(mut registry) = self.response_registry.lock() {
            registry.clear();
        }

        // Update connection state
        if let Ok(mut state) = self.state.lock() {
            *state = Phd2State::Disconnected;
        }

        tracing::info!("Disconnected from PHD2");
    }

    /// Check if connected
    pub fn is_connected(&self) -> bool {
        self.write_stream.is_some() && self.running.load(Ordering::SeqCst)
    }

    /// Start the event listener thread.
    ///
    /// This single thread owns the read side of the TCP stream and routes
    /// all incoming lines:
    ///   - JSON-RPC responses (lines containing "id") -> pending request waiter
    ///   - PHD2 events (lines containing "Event") -> event callback
    ///
    /// Uses manual line reading instead of BufReader::lines() to avoid data
    /// loss when read timeouts occur mid-line. A persistent line buffer
    /// accumulates bytes across read calls until a complete newline-terminated
    /// line is available.
    fn start_event_listener(&self, read_stream: TcpStream) {
        let running = Arc::clone(&self.running);
        let callback = self.event_callback.clone();
        let rolling_stats = Arc::clone(&self.rolling_stats);
        let state = Arc::clone(&self.state);
        let response_registry = Arc::clone(&self.response_registry);
        let suppress_disconnect_events = Arc::clone(&self.suppress_disconnect_events);
        let settle_tracker = Arc::clone(&self.settle_tracker);
        let looping = Arc::clone(&self.looping);
        let received_lines = Arc::clone(&self.received_lines);

        thread::spawn(move || {
            tracing::info!("PHD2: Reader thread started");
            let mut reader = BufReader::new(read_stream);
            // Persistent line buffer: survives across read timeouts so partial
            // lines are not lost when the 100ms read timeout fires mid-line.
            // read_line() appends to this buffer; we only clear it after
            // successfully processing a complete line.
            let mut line_buf = String::new();

            loop {
                if !running.load(Ordering::SeqCst) {
                    tracing::info!("PHD2: Reader thread stopping (running=false)");
                    break;
                }

                let result = reader.read_line(&mut line_buf);
                if !running.load(Ordering::SeqCst) {
                    break;
                }
                match result {
                    Ok(0) => {
                        // EOF - connection closed
                        tracing::info!("PHD2: Reader thread got EOF, connection closed");
                        running.store(false, Ordering::SeqCst);
                        let request_waiting = response_registry
                            .lock()
                            .map(|mut registry| {
                                let waiting = !registry.is_empty();
                                registry.clear();
                                waiting
                            })
                            .unwrap_or(false);
                        if let Ok(mut s) = state.lock() {
                            *s = Phd2State::Disconnected;
                        }
                        // A waiting RPC owns its bounded recovery. Emitting a
                        // disconnect now would make the UI tear down its replacement.
                        if !request_waiting && !suppress_disconnect_events.load(Ordering::SeqCst) {
                            if let Some(ref cb) = callback {
                                if let Ok(cb) = cb.lock() {
                                    cb(Phd2Event::Disconnected);
                                }
                            }
                        }
                        break;
                    }
                    Ok(_n) => {
                        // read_line returns Ok(n) where n includes the \n.
                        // Only process if we have a complete line (ends with \n).
                        if !line_buf.ends_with('\n') {
                            // Partial line in buffer - keep accumulating
                            continue;
                        }

                        // Got a complete line (terminated by \n)
                        let json = line_buf.trim();
                        if json.is_empty() {
                            line_buf.clear();
                            continue;
                        }

                        received_lines.fetch_add(1, Ordering::Relaxed);
                        // Process the complete line
                        Self::process_line(
                            json,
                            &response_registry,
                            &rolling_stats,
                            &state,
                            &callback,
                            &settle_tracker,
                            &looping,
                        );

                        // Clear buffer for next line
                        line_buf.clear();
                    }
                    Err(e) => {
                        if e.kind() == std::io::ErrorKind::WouldBlock
                            || e.kind() == std::io::ErrorKind::TimedOut
                        {
                            // Read timeout - normal polling interval.
                            // IMPORTANT: Do NOT clear line_buf here. If read_line()
                            // already moved bytes from BufReader's internal buffer
                            // into line_buf before the timeout, those bytes are
                            // preserved. On the next read_line() call, it will
                            // continue appending to line_buf.
                            continue;
                        }

                        tracing::warn!("PHD2: Read error (kind={:?}): {}", e.kind(), e);

                        running.store(false, Ordering::SeqCst);
                        let request_waiting = response_registry
                            .lock()
                            .map(|mut registry| {
                                let waiting = !registry.is_empty();
                                registry.clear();
                                waiting
                            })
                            .unwrap_or(false);
                        // Update state to disconnected
                        if let Ok(mut s) = state.lock() {
                            *s = Phd2State::Disconnected;
                        }

                        // A waiting RPC owns its bounded recovery. Emitting a
                        // disconnect now would make the UI tear down its replacement.
                        if !request_waiting && !suppress_disconnect_events.load(Ordering::SeqCst) {
                            if let Some(ref cb) = callback {
                                if let Ok(cb) = cb.lock() {
                                    cb(Phd2Event::Disconnected);
                                }
                            }
                        }
                        break;
                    }
                }
            }

            tracing::info!("PHD2: Reader thread exited");
        });
    }

    /// Process a single complete JSON line from the PHD2 TCP stream.
    ///
    /// Routes the line to either the response registry (for JSON-RPC responses)
    /// or the event callback (for PHD2 events).
    fn process_line(
        json: &str,
        response_registry: &Arc<Mutex<HashMap<u32, mpsc::Sender<String>>>>,
        rolling_stats: &Arc<Mutex<RollingGuideStats>>,
        state: &Arc<Mutex<Phd2State>>,
        callback: &Option<Phd2EventCallback>,
        settle_tracker: &Arc<Mutex<SettleTracker>>,
        looping: &LoopingFrames,
    ) {
        // Parse JSON
        let parsed: serde_json::Value = match serde_json::from_str(json) {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!("PHD2: Failed to parse JSON line: {} (line: {})", e, json);
                return;
            }
        };

        // JSON-RPC response (numeric id) — includes success and error bodies.
        if let Some(id_val) = parsed.get("id") {
            if let Some(id) = id_val.as_u64() {
                let id = id as u32;
                if let Ok(mut registry) = response_registry.lock() {
                    if let Some(sender) = registry.remove(&id) {
                        if let Err(e) = sender.send(json.to_string()) {
                            tracing::warn!("PHD2: Failed to send response for id {}: {}", id, e);
                        }
                    } else {
                        tracing::debug!("PHD2: Received response for unknown id {}", id);
                    }
                }
                return;
            }
            // PHD2 may return parse/validation errors with `"id": null`; not an event.
            if id_val.is_null() && parsed.get("error").is_some() {
                tracing::debug!("PHD2: Ignoring JSON-RPC error with null id: {}", json);
                return;
            }
        }

        // Otherwise treat as event message
        match serde_json::from_str::<Phd2EventMessage>(json) {
            Ok(event_msg) => {
                if event_msg.event == "LoopingExposures"
                    && event_msg
                        .extra
                        .get("Frame")
                        .and_then(|v| v.as_u64())
                        .is_some()
                {
                    looping.record(&event_msg.extra);
                }
                // Every looping/guide frame is an event (~1 Hz); trace, don't info.
                tracing::debug!("PHD2: Received event: {}", event_msg.event);
                // A new guiding session starts a new RMS window. Samples from
                // before the guider was stopped and started again describe
                // guiding that has ended, and left in place they kept a
                // re-acquired guider over the recovery settle bound for the
                // next hundred frames.
                if event_msg.event == "StartGuiding" {
                    if let Ok(mut stats) = rolling_stats.lock() {
                        stats.reset();
                    }
                }
                if let Some(event) = parse_phd2_event(&event_msg) {
                    // Update rolling stats for guide frames
                    if let Phd2Event::GuideStep(ref frame) = event {
                        if let Ok(mut stats) = rolling_stats.lock() {
                            stats.add_frame(frame);
                        }
                    }

                    // Update state for state change events
                    if let Phd2Event::StateChanged(ref new_state) = event {
                        if let Ok(mut s) = state.lock() {
                            *s = new_state.clone();
                        }
                    }

                    // Record settle completion so a blocking `wait_for_settle`
                    // (called by `dither`) can observe the outcome and fail
                    // closed on a non-zero PHD2 settle status. Only record while
                    // a settle is armed so a stray/duplicate SettleDone cannot
                    // prematurely release a future wait.
                    if let Phd2Event::SettleDone {
                        status,
                        ref error,
                        total_frames,
                        dropped_frames,
                    } = event
                    {
                        if let Ok(mut tracker) = settle_tracker.lock() {
                            if tracker.awaiting {
                                tracker.awaiting = false;
                                tracker.outcome = Some(SettleOutcome {
                                    status,
                                    error: error.clone(),
                                    total_frames,
                                    dropped_frames,
                                });
                            } else {
                                tracing::debug!(
                                    "PHD2: SettleDone received with no settle armed (status={})",
                                    status
                                );
                            }
                        }
                    }

                    // Call user callback
                    if let Some(ref cb) = callback {
                        tracing::debug!("PHD2: Dispatching event to callback: {:?}", event);
                        match cb.lock() {
                            Ok(cb) => {
                                cb(event);
                                tracing::debug!("PHD2: Event callback completed successfully");
                            }
                            Err(e) => {
                                tracing::error!("PHD2: Event callback mutex poisoned: {}", e);
                            }
                        }
                    } else {
                        tracing::warn!("PHD2: No event callback registered, dropping event");
                    }
                } else {
                    tracing::debug!("PHD2: Unhandled event type: {}", event_msg.event);
                }
            }
            Err(e) => {
                tracing::warn!(
                    "PHD2: Failed to parse event message: {} (line: {})",
                    e,
                    json
                );
            }
        }
    }

    /// Send a JSON-RPC request and wait for the response.
    ///
    /// The write half of the stream is used to send the request.
    /// A one-shot channel is registered in the response registry so the
    /// reader thread can route the matching response back to us.
    fn send_request(
        &mut self,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<serde_json::Value, String> {
        self.ensure_connected()?;
        self.send_request_connected(method, params)
    }

    fn ensure_connected(&mut self) -> Result<(), String> {
        if !self.is_connected() {
            if !self.connection_wanted || !self.config.auto_reconnect {
                return Err("Not connected to PHD2".to_string());
            }
            self.connect()?;
        }
        Ok(())
    }

    fn send_request_connected(
        &mut self,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<serde_json::Value, String> {
        // Reads and stopping capture are idempotent. A timed-out dither or
        // guide may already have executed, so never replay those implicitly.
        let can_retry = method.starts_with("get_") || method == "stop_capture";
        let response = self.request_response(method, params.clone());
        let response_line = match response {
            Ok(line) => line,
            Err(first) => {
                tracing::warn!("PHD2 transport failed: {first}; retiring socket");
                self.close_transport();
                if !can_retry || !self.config.auto_reconnect {
                    self.report_disconnect();
                    return Err(first);
                }
                if let Err(error) = self.connect() {
                    self.report_disconnect();
                    return Err(format!("{first}; reconnect failed: {error}"));
                }
                match self.request_response(method, params) {
                    Ok(line) => {
                        tracing::info!("PHD2 RPC recovered on a new connection: {method}");
                        line
                    }
                    Err(error) => {
                        self.close_transport();
                        self.report_disconnect();
                        return Err(format!("{first}; fresh connection also failed: {error}"));
                    }
                }
            }
        };

        // Parse the response
        let resp: JsonRpcResponse = serde_json::from_str(&response_line)
            .map_err(|e| format!("Failed to parse response: {}", e))?;

        if let Some(error) = resp.error {
            return Err(format!("PHD2 error: {}", error.message));
        }

        // Why: per JSON-RPC 2.0, a response with no `error`
        // is REQUIRED to contain `result`, but PHD2 RPC methods that semantically
        // return void (`set_connected`, `loop`, `stop_capture`, etc.) ship
        // `{"jsonrpc":"2.0","result":0,"id":N}` — or, on older builds, just
        // omit `result`. Substituting `Null` here is the documented contract:
        // void-returning callers ignore the value, value-returning callers
        // immediately downcast (`.as_str()`/`.as_array()` etc.) and would
        // already fail on `Null` with a clear "expected …" error rather than
        // bubbling a confusing "missing result" message.
        Ok(resp.result.unwrap_or(serde_json::Value::Null))
    }

    fn report_disconnect(&self) {
        if let Some(callback) = &self.event_callback {
            if let Ok(callback) = callback.lock() {
                callback(Phd2Event::Disconnected);
            }
        }
    }

    /// Send once, returning only transport errors here. JSON-RPC application
    /// errors are handled by the caller and never cause a reconnect/replay.
    fn request_response(
        &mut self,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<String, String> {
        self.request_id = self.request_id.wrapping_add(1);
        let request_id = self.request_id;
        let request = JsonRpcRequest {
            method: method.to_string(),
            params,
            id: request_id,
        };
        let mut json = serde_json::to_string(&request)
            .map_err(|e| format!("Failed to serialize request: {e}"))?;
        json.push_str("\r\n");
        let (tx, rx) = mpsc::channel::<String>();
        self.response_registry
            .lock()
            .map_err(|e| format!("Failed to lock response registry: {e}"))?
            .insert(request_id, tx);
        let lines_before = self.received_lines.load(Ordering::Relaxed);
        let stream = self.write_stream.as_mut().ok_or("Not connected to PHD2")?;
        // Submit the JSON and its delimiter together, with a bounded write.
        stream
            .write_all(json.as_bytes())
            .map_err(|e| format!("Failed to send '{method}' (id={request_id}): {e}"))?;
        tracing::debug!("PHD2 sent {method} (id={request_id}, bytes={})", json.len());
        rx.recv_timeout(Duration::from_secs(10)).map_err(|e| {
            let received = self.received_lines.load(Ordering::Relaxed) - lines_before;
            match e {
                mpsc::RecvTimeoutError::Timeout => format!(
                    "Request '{method}' timed out (id={request_id}, {} bytes written, {received} incoming lines while waiting)",
                    json.len()
                ),
                mpsc::RecvTimeoutError::Disconnected => format!(
                    "PHD2 connection closed waiting for '{method}' (id={request_id})"
                ),
            }
        })
    }

    // PHD2 commands

    /// Get PHD2 application state
    pub fn get_app_state(&mut self) -> Result<Phd2State, String> {
        let result = self.send_request("get_app_state", None)?;
        let state_str = result
            .as_str()
            .ok_or_else(|| format!("get_app_state: expected string, got {}", result))?;
        Ok(parse_phd2_app_state(state_str))
    }

    /// Get connected equipment
    pub fn get_connected(&mut self) -> Result<bool, String> {
        let result = self.send_request("get_connected", None)?;
        // A non-bool here is protocol corruption or schema drift, not "not
        // connected": propagate the type mismatch.
        result
            .as_bool()
            .ok_or_else(|| format!("get_connected: expected bool, got {}", result))
    }

    /// Connect PHD2 to equipment
    pub fn set_connected(&mut self, connected: bool) -> Result<(), String> {
        self.send_request("set_connected", Some(serde_json::json!(connected)))?;
        Ok(())
    }

    /// Start guiding
    pub fn guide(
        &mut self,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
    ) -> Result<(), String> {
        let params = serde_json::json!({
            "settle": {
                "pixels": settle_pixels,
                "time": settle_time,
                "timeout": settle_timeout
            }
        });
        self.send_request("guide", Some(params))?;
        Ok(())
    }

    /// Start guiding and track the asynchronous settle result.
    pub fn guide_arm(
        &mut self,
        pixels: f64,
        time: f64,
        timeout: f64,
    ) -> Result<SettleWaiter, String> {
        self.ensure_connected()?;
        let waiter = self.arm_settle();
        self.send_request_connected(
            "guide",
            Some(serde_json::json!({
                "settle": { "pixels": pixels, "time": time, "timeout": timeout }
            })),
        )?;
        Ok(waiter)
    }

    /// Number of completed looping frames received on this connection.
    /// Unlike PHD2's frame IDs, this does not reset when capture restarts.
    pub fn looping_frame_count(&self) -> u64 {
        self.looping.count.load(Ordering::SeqCst)
    }

    /// The star the latest looping frame measured, if PHD2 reported one.
    pub fn looping_star(&self) -> Option<LoopingStar> {
        match self.looping.star.lock() {
            Ok(star) => *star,
            Err(poison) => *poison.into_inner(),
        }
    }

    /// Whether a `guide` or `dither` this client issued is still waiting for
    /// PHD2's `SettleDone`. PHD2 refuses a new `guide` while one is.
    pub fn settle_pending(&self) -> bool {
        match self.settle_tracker.lock() {
            Ok(tracker) => tracker.awaiting,
            Err(poison) => poison.into_inner().awaiting,
        }
    }

    /// PHD2's application state exactly as it names it. "Stopped" is the only
    /// state with no capture in progress; "Selected" still has one.
    pub fn get_app_state_name(&mut self) -> Result<String, String> {
        let result = self.send_request("get_app_state", None)?;
        result
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| format!("get_app_state: expected string, got {}", result))
    }

    /// Stop guiding
    pub fn stop_capture(&mut self) -> Result<(), String> {
        self.send_request("stop_capture", None)?;
        Ok(())
    }

    /// Pause guiding
    pub fn set_paused(&mut self, paused: bool) -> Result<(), String> {
        self.send_request("set_paused", Some(serde_json::json!([paused, "full"])))?;
        Ok(())
    }

    /// Arm settle tracking and return a [`SettleWaiter`] for the armed settle.
    ///
    /// Must be called *before* the `dither`/`guide` RPC is sent so the reader
    /// thread cannot miss an early `SettleDone` (no race window).
    fn arm_settle(&self) -> SettleWaiter {
        // Why: settle tracking is load-bearing for dither
        // correctness. A poisoned mutex means the reader thread panicked; in
        // that case the connection is already dead and the subsequent settle
        // wait will fail closed (disconnect or timeout), which is correct. We
        // still arm so the waiter has a coherent generation to poll.
        let mut tracker = match self.settle_tracker.lock() {
            Ok(t) => t,
            Err(poison) => poison.into_inner(),
        };
        tracker.generation = tracker.generation.wrapping_add(1);
        tracker.awaiting = true;
        tracker.outcome = None;
        SettleWaiter {
            settle_tracker: Arc::clone(&self.settle_tracker),
            running: Arc::clone(&self.running),
            state: Arc::clone(&self.state),
            generation: tracker.generation,
        }
    }

    /// Recommended bound for a settle wait given the requested PHD2 settle
    /// parameters. Includes a grace margin because PHD2 only starts its own
    /// settle clock after it processes the dither and begins moving.
    pub fn settle_wait_duration(settle_time: f64, settle_timeout: f64) -> Duration {
        let secs = (settle_timeout.max(settle_time + 1.0) + 5.0).max(1.0);
        Duration::from_secs_f64(secs)
    }

    /// Issue the `dither` RPC and return a [`SettleWaiter`] WITHOUT blocking.
    ///
    /// The caller is responsible for invoking [`SettleWaiter::wait`] to block
    /// until PHD2 settles and to fail closed on settle failure/timeout. This
    /// split lets the bridge release its global PHD2 storage lock before the
    /// multi-second settle wait.
    pub fn dither_arm(
        &mut self,
        amount: f64,
        ra_only: bool,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
    ) -> Result<SettleWaiter, String> {
        let params = serde_json::json!({
            "amount": amount,
            "raOnly": ra_only,
            "settle": {
                "pixels": settle_pixels,
                "time": settle_time,
                "timeout": settle_timeout
            }
        });

        // Arm settle tracking BEFORE sending the RPC so the reader thread
        // cannot miss an early SettleDone (no race window).
        self.ensure_connected()?;
        let waiter = self.arm_settle();
        self.send_request_connected("dither", Some(params))?;
        Ok(waiter)
    }

    /// Dither the guide star and BLOCK until PHD2 settles.
    ///
    /// PHD2's `dither` RPC returns immediately; the settle completes
    /// asynchronously and is announced only by the `SettleDone` event. This
    /// method arms settle tracking, issues the RPC, then waits for completion
    /// and fails closed on settle failure or timeout — so callers (the
    /// sequencer dither step) never resume exposing mid-settle.
    pub fn dither(
        &mut self,
        amount: f64,
        ra_only: bool,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
    ) -> Result<(), String> {
        let waiter =
            self.dither_arm(amount, ra_only, settle_pixels, settle_time, settle_timeout)?;
        waiter.wait(Self::settle_wait_duration(settle_time, settle_timeout))?;
        Ok(())
    }

    /// Set lock position (guide star position)
    pub fn set_lock_position(&mut self, x: f64, y: f64, exact: bool) -> Result<(), String> {
        self.send_request("set_lock_position", Some(serde_json::json!([x, y, exact])))?;
        Ok(())
    }

    /// Clear calibration
    pub fn clear_calibration(&mut self, which: &str) -> Result<(), String> {
        // PHD2's positional JSON-RPC contract requires an array here.
        // Sending the bare string makes PHD2 2.6.14 execute the clear but omit
        // the response, leaving the caller blocked until its 10-second timeout.
        self.send_request("clear_calibration", Some(serde_json::json!([which])))?;
        Ok(())
    }

    /// Flip calibration (after meridian flip)
    pub fn flip_calibration(&mut self) -> Result<(), String> {
        self.send_request("flip_calibration", None)?;
        Ok(())
    }

    /// Get current guide star position
    pub fn get_lock_position(&mut self) -> Result<(f64, f64), String> {
        let result = self.send_request("get_lock_position", None)?;
        let arr = result
            .as_array()
            .ok_or_else(|| format!("get_lock_position: expected array, got {}", result))?;

        // PHD2 contract: `[x, y]` floats. A missing element
        // or non-numeric value means schema drift or no star locked; surface
        // it instead of silently reporting "guide star at origin (0, 0)".
        let x = arr
            .first()
            .and_then(|v| v.as_f64())
            .ok_or_else(|| "get_lock_position: missing or non-numeric X".to_string())?;
        let y = arr
            .get(1)
            .and_then(|v| v.as_f64())
            .ok_or_else(|| "get_lock_position: missing or non-numeric Y".to_string())?;

        Ok((x, y))
    }

    /// Get exposure time
    pub fn get_exposure(&mut self) -> Result<u32, String> {
        let result = self.send_request("get_exposure", None)?;
        // PHD2 always returns the exposure as an unsigned
        // integer (milliseconds). A non-integer or negative value is a
        // protocol violation; surface it rather than silently reporting 0ms
        // which the caller would interpret as "no exposure set".
        let exposure = result
            .as_u64()
            .ok_or_else(|| format!("get_exposure: expected unsigned integer, got {}", result))?;
        u32::try_from(exposure)
            .map_err(|_| format!("get_exposure: value {} exceeds u32::MAX", exposure))
    }

    /// Set exposure time (milliseconds)
    pub fn set_exposure(&mut self, exposure_ms: u32) -> Result<(), String> {
        self.send_request("set_exposure", Some(serde_json::json!(exposure_ms)))?;
        Ok(())
    }

    /// Get pixel scale (arcsec/pixel)
    pub fn get_pixel_scale(&mut self) -> Result<f64, String> {
        let result = self.send_request("get_pixel_scale", None)?;
        // pixel scale of 0 is physically meaningless and
        // would silently break every downstream RA/Dec-to-pixel conversion.
        // Propagate the parse failure so the caller knows the value is
        // unavailable (e.g. PHD2 has no profile loaded).
        result
            .as_f64()
            .ok_or_else(|| format!("get_pixel_scale: expected number, got {}", result))
    }

    /// Get current star image (raw bytes only - deprecated, use get_star_image_data instead)
    pub fn get_star_image(&mut self) -> Result<Vec<u8>, String> {
        let data = self.get_star_image_data(32)?;
        Ok(data.pixels)
    }

    /// Get current star image with full metadata
    /// size: requested size of the subframe (minimum 15, default 32)
    pub fn get_star_image_data(&mut self, size: u32) -> Result<StarImageData, String> {
        let params = serde_json::json!({ "size": size });
        let result = self.send_request("get_star_image", Some(params))?;

        // `frame`, `width` and `height` are required by the PHD2
        // `get_star_image` schema, so a missing or non-integer value is a
        // malformed response. Yielding a 0x0 image with frame=0 instead would
        // feed downstream star analysis data it happily reports on.
        let frame = result
            .get("frame")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| "get_star_image: missing or non-integer 'frame'".to_string())?
            as u32;

        let width = result
            .get("width")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| "get_star_image: missing or non-integer 'width'".to_string())?
            as u32;

        let height = result
            .get("height")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| "get_star_image: missing or non-integer 'height'".to_string())?
            as u32;

        // star_pos is [x, y] array. PHD2 documents the field as optional
        // when no star is locked (returned `null` / absent), so treating
        // "no star_pos" as `(0.0, 0.0)` is the documented fallback. A
        // present-but-malformed array, however, is a protocol violation
        // and must surface.
        let star_pos = result.get("star_pos").and_then(|v| v.as_array());
        let (star_x, star_y) = match star_pos {
            Some(arr) => {
                let x = arr.first().and_then(|v| v.as_f64()).ok_or_else(|| {
                    "get_star_image: 'star_pos' present but X missing/non-numeric".to_string()
                })?;
                let y = arr.get(1).and_then(|v| v.as_f64()).ok_or_else(|| {
                    "get_star_image: 'star_pos' present but Y missing/non-numeric".to_string()
                })?;
                (x, y)
            }
            // Why: per PHD2 protocol, absent `star_pos` indicates no star is
            // currently locked. The subframe pixels are still valid; (0, 0)
            // is the canonical "unset" marker that callers already check for.
            None => (0.0, 0.0),
        };

        // Decode base64 pixel data
        let pixels_b64 = result
            .get("pixels")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "No pixel data in response".to_string())?;
        let pixels = base64_decode(pixels_b64)?;

        Ok(StarImageData {
            frame,
            width,
            height,
            star_x,
            star_y,
            pixels,
        })
    }

    /// Loop exposures (without guiding)
    pub fn loop_exposures(&mut self) -> Result<(), String> {
        self.send_request("loop", None)?;
        Ok(())
    }

    /// Find a guide star automatically
    pub fn find_star(&mut self) -> Result<(f64, f64), String> {
        let result = self.send_request("find_star", None)?;
        let arr = result
            .as_array()
            .ok_or_else(|| format!("find_star: expected array, got {}", result))?;

        // PHD2 contract: `[x, y]` floats of the chosen star.
        // (0, 0) was indistinguishable from "no star found"; surface the parse
        // failure so callers can fall back instead of slewing to the origin.
        let x = arr
            .first()
            .and_then(|v| v.as_f64())
            .ok_or_else(|| "find_star: missing or non-numeric X".to_string())?;
        let y = arr
            .get(1)
            .and_then(|v| v.as_f64())
            .ok_or_else(|| "find_star: missing or non-numeric Y".to_string())?;

        Ok((x, y))
    }

    // PHD2 Brain API - algorithm parameters

    /// Get available algorithm parameter names for an axis
    /// axis: "ra" or "dec" (also accepts "x" or "y")
    pub fn get_algo_param_names(&mut self, axis: &str) -> Result<Vec<String>, String> {
        let params = serde_json::json!({ "axis": axis });
        let result = self.send_request("get_algo_param_names", Some(params))?;

        let arr = result
            .as_array()
            .ok_or_else(|| "Invalid response: expected array".to_string())?;

        let names: Vec<String> = arr
            .iter()
            .filter_map(|v| v.as_str().map(|s| s.to_string()))
            // `algorithmName` is PHD2's STRING parameter naming the active guide
            // algorithm (e.g. "hysteresis"), NOT a numeric tunable. Every consumer
            // of this list fetches each name's value as a number
            // (`get_algo_param` -> f64), so leaving it in makes that call fail with
            // "Invalid response for parameter algorithmName: expected number",
            // which aborts the ENTIRE brain-settings load. Exclude it here so only
            // numeric parameters are enumerated (this list also drives the UI
            // sliders, which algorithmName is not). The algorithm name, if needed,
            // must be queried separately as a string.
            .filter(|s| s != "algorithmName")
            .collect();

        Ok(names)
    }

    /// Get the value of an algorithm parameter
    /// axis: "ra" or "dec" (also accepts "x" or "y")
    /// name: parameter name (from get_algo_param_names)
    pub fn get_algo_param(&mut self, axis: &str, name: &str) -> Result<f64, String> {
        let params = serde_json::json!({
            "axis": axis,
            "name": name
        });
        let result = self.send_request("get_algo_param", Some(params))?;

        result
            .as_f64()
            .ok_or_else(|| format!("Invalid response for parameter {}: expected number", name))
    }

    /// Set the value of an algorithm parameter
    /// axis: "ra" or "dec" (also accepts "x" or "y")
    /// name: parameter name (from get_algo_param_names)
    /// value: new parameter value
    pub fn set_algo_param(&mut self, axis: &str, name: &str, value: f64) -> Result<(), String> {
        let params = serde_json::json!({
            "axis": axis,
            "name": name,
            "value": value
        });
        let result = self.send_request("set_algo_param", Some(params))?;

        // Result should be 0 on success
        // Why: `-1` is a deliberate sentinel meaning "couldn't
        // even parse a status code". PHD2 returns `0` on success and a positive
        // error code otherwise, so any non-zero value (including the sentinel)
        // correctly triggers the error branch below. Replacing with `?` would
        // strip the helpful "Failed to set parameter X" prefix.
        let code = result.as_i64().unwrap_or(-1);
        if code != 0 {
            return Err(format!(
                "Failed to set parameter {}: error code {}",
                name, code
            ));
        }

        Ok(())
    }

    /// Get all algorithm parameters for an axis
    pub fn get_all_algo_params(&mut self, axis: &str) -> Result<Vec<AlgoParam>, String> {
        let names = self.get_algo_param_names(axis)?;
        let mut params = Vec::with_capacity(names.len());

        for name in names {
            let value = self.get_algo_param(axis, &name)?;
            params.push(AlgoParam { name, value });
        }

        Ok(params)
    }

    /// Get the current calibration data
    pub fn get_calibration_data(&mut self, which: &str) -> Result<serde_json::Value, String> {
        let params = serde_json::json!({ "which": which });
        self.send_request("get_calibration_data", Some(params))
    }

    /// Deselect the current guide star
    pub fn deselect_star(&mut self) -> Result<(), String> {
        self.send_request("deselect_star", None)?;
        Ok(())
    }

    /// Get current camera frame dimensions
    pub fn get_camera_frame_size(&mut self) -> Result<(u32, u32), String> {
        let result = self.send_request("get_camera_frame_size", None)?;
        let arr = result
            .as_array()
            .ok_or_else(|| format!("get_camera_frame_size: expected array, got {}", result))?;

        // width/height of 0 silently produced division-by-zero
        // downstream in pixel-scale and binning logic. Surface the parse error.
        let width = arr
            .first()
            .and_then(|v| v.as_u64())
            .ok_or_else(|| "get_camera_frame_size: missing or non-integer width".to_string())?
            as u32;
        let height = arr
            .get(1)
            .and_then(|v| v.as_u64())
            .ok_or_else(|| "get_camera_frame_size: missing or non-integer height".to_string())?
            as u32;

        Ok((width, height))
    }

    /// Get guide output enabled status
    pub fn get_guide_output_enabled(&mut self) -> Result<bool, String> {
        let result = self.send_request("get_guide_output_enabled", None)?;
        // see `get_connected`. A non-bool means protocol
        // corruption; "guide output disabled" is the wrong default to assume
        // because callers may rely on this to gate dither/pulse commands.
        result
            .as_bool()
            .ok_or_else(|| format!("get_guide_output_enabled: expected bool, got {}", result))
    }

    /// Set guide output enabled status
    pub fn set_guide_output_enabled(&mut self, enabled: bool) -> Result<(), String> {
        self.send_request("set_guide_output_enabled", Some(serde_json::json!(enabled)))?;
        Ok(())
    }

    /// Get current profile name
    pub fn get_profile(&mut self) -> Result<String, String> {
        let result = self.send_request("get_profile", None)?;
        // Surface the absence rather than displaying "Unknown": the field is
        // `name` today and new PHD2 builds may rename it, which is schema drift
        // worth noticing.
        let profile = result
            .get("name")
            .and_then(|v| v.as_str())
            .ok_or_else(|| format!("get_profile: missing 'name' field in {}", result))?;
        Ok(profile.to_string())
    }
}

impl Drop for Phd2Client {
    fn drop(&mut self) {
        self.disconnect();
    }
}

/// Parse a PHD2 event message.
///
/// Returns `None` only when the event name is unknown OR a *critical* field
/// is missing (e.g. `GuideStep` without `RADistanceRaw`/`DECDistanceRaw`).
/// Critical-field absence is logged at `warn` level so schema drift surfaces
/// in operator logs instead of producing zeroed-out guide frames that would
/// silently degrade tracking accuracy.
fn parse_phd2_event(msg: &Phd2EventMessage) -> Option<Phd2Event> {
    match msg.event.as_str() {
        "GuideStep" => {
            let extra = &msg.extra;

            // Why: RA/Dec distance are the load-bearing values of every guide
            // frame, and a 0.0 default reads as perfect guiding and poisons the
            // rolling RMS. If either is missing or non-numeric, drop the whole
            // frame and log it.
            let ra_distance = match extra.get("RADistanceRaw").and_then(|v| v.as_f64()) {
                Some(v) => v,
                None => {
                    tracing::warn!(
                        "PHD2: GuideStep missing RADistanceRaw — dropping frame ({})",
                        msg.extra
                    );
                    return None;
                }
            };
            let dec_distance = match extra.get("DECDistanceRaw").and_then(|v| v.as_f64()) {
                Some(v) => v,
                None => {
                    tracing::warn!(
                        "PHD2: GuideStep missing DECDistanceRaw — dropping frame ({})",
                        msg.extra
                    );
                    return None;
                }
            };

            // Why: `Frame` (sequence number) and
            // `timestamp` may legitimately be absent in older PHD2 builds
            // that predate Event-monitoring schema v1.7; the rolling-stats
            // window keeps its own counter, so 0 here is a recoverable
            // default rather than a silent error.
            let frame = extra.get("Frame").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
            let timestamp = msg.timestamp.unwrap_or(0.0);

            // Why: pulse durations and directions ARE
            // absent in real PHD2 traffic when no correction was issued
            // for the axis (zero-duration step). Defaulting to 0 ms and
            // "" matches PHD2's own "no pulse" semantics; the UI checks
            // duration > 0 before drawing the direction arrow.
            let ra_duration = extra
                .get("RADuration")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as i32;
            let dec_duration = extra
                .get("DECDuration")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as i32;
            let ra_direction = extra
                .get("RADirection")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let dec_direction = extra
                .get("DECDirection")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            // Why: SNR, StarMass, StarX, StarY, AvgDist
            // are PHD2 "optional" fields per the EventMonitoring wiki:
            // they may be absent during calibration steps, settling, or
            // very early frames before the rolling stats stabilise. 0.0
            // is the documented "not yet measured" sentinel and the
            // dashboard already filters frame_count < 5 before display.
            let snr = extra.get("SNR").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let star_mass = extra
                .get("StarMass")
                .and_then(|v| v.as_f64())
                .unwrap_or(0.0);
            let star_x = extra.get("StarX").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let star_y = extra.get("StarY").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let avg_dist = extra.get("AvgDist").and_then(|v| v.as_f64()).unwrap_or(0.0);

            Some(Phd2Event::GuideStep(GuideFrame {
                frame,
                timestamp,
                ra_distance,
                dec_distance,
                ra_duration,
                dec_duration,
                ra_direction,
                dec_direction,
                snr,
                star_mass,
                star_x,
                star_y,
                avg_dist,
            }))
        }
        "AppState" => {
            // Why: an `AppState` event with no `State`
            // field is malformed; routing it through `parse_phd2_app_state`
            // would yield `Phd2State::Unknown("")` and spam the warn log.
            // Drop the event instead and log once with the offending blob.
            let Some(state_str) = msg.extra.get("State").and_then(|v| v.as_str()) else {
                tracing::warn!(
                    "PHD2: AppState event missing 'State' field — dropping ({})",
                    msg.extra
                );
                return None;
            };
            Some(Phd2Event::StateChanged(parse_phd2_app_state(state_str)))
        }
        "StartCalibration" => Some(Phd2Event::StateChanged(Phd2State::Calibrating)),
        "CalibrationComplete" => Some(Phd2Event::CalibrationComplete),
        "StartGuiding" => Some(Phd2Event::StateChanged(Phd2State::Guiding)),
        "GuidingStopped" => Some(Phd2Event::StateChanged(Phd2State::Connected)),
        "Paused" => Some(Phd2Event::StateChanged(Phd2State::Paused)),
        "LoopingExposures" => Some(Phd2Event::StateChanged(Phd2State::Looping)),
        "LoopingExposuresStopped" => Some(Phd2Event::StateChanged(Phd2State::Connected)),
        "StarLost" => Some(Phd2Event::StarLost),
        "StarSelected" => {
            // Why: `X` and `Y` are REQUIRED by the
            // PHD2 protocol for `StarSelected`. (0,0) was indistinguishable
            // from a valid lock at the origin; drop the malformed event.
            let Some(x) = msg.extra.get("X").and_then(|v| v.as_f64()) else {
                tracing::warn!(
                    "PHD2: StarSelected event missing X — dropping ({})",
                    msg.extra
                );
                return None;
            };
            let Some(y) = msg.extra.get("Y").and_then(|v| v.as_f64()) else {
                tracing::warn!(
                    "PHD2: StarSelected event missing Y — dropping ({})",
                    msg.extra
                );
                return None;
            };
            Some(Phd2Event::StarSelected { x, y })
        }
        "SettleBegin" => Some(Phd2Event::SettleBegin),
        "Settling" => Some(Phd2Event::StateChanged(Phd2State::Settling)),
        "SettleDone" => {
            // Why: the `Status` field is LOAD-BEARING for unattended dithering.
            // PHD2 reports settle completion asynchronously: `Status == 0` means
            // the mount settled within the requested pixel/time window;
            // non-zero means the settle FAILED (e.g. star lost, never settled
            // within timeout). The dither caller MUST wait for this event and
            // fail closed on a non-zero status, otherwise the sequencer resumes
            // exposing mid-settle and trails the sub. Per the PHD2
            // EventMonitoring wiki, `Status` is a required field on SettleDone;
            // if it is somehow absent we treat that as a failure (non-zero) so
            // we never silently report a settle as successful.
            let status = msg
                .extra
                .get("Status")
                .and_then(|v| v.as_i64())
                .map(|v| v as i32)
                .unwrap_or_else(|| {
                    tracing::warn!(
                        "PHD2: SettleDone missing 'Status' — treating as settle FAILURE ({})",
                        msg.extra
                    );
                    -1
                });
            // `Error` is only present when Status != 0; default to a synthesised
            // message so a failed settle always carries an explanation.
            let error = msg
                .extra
                .get("Error")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| {
                    if status == 0 {
                        String::new()
                    } else {
                        format!("PHD2 settle failed (status {})", status)
                    }
                });
            // Why: `TotalFrames`/`DroppedFrames` may
            // legitimately be 0 when settling completes on the first
            // frame; absence (`None`) is also documented as "no frames
            // tracked", so 0 is the protocol-defined fallback rather than
            // a swallowed parse error. Both branches collapse to identical
            // UI semantics ("no drops").
            let total = msg
                .extra
                .get("TotalFrames")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u32;
            let dropped = msg
                .extra
                .get("DroppedFrames")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u32;
            Some(Phd2Event::SettleDone {
                status,
                error,
                total_frames: total,
                dropped_frames: dropped,
            })
        }
        "Alert" => {
            // Why: an Alert with no `Msg`/`Type` is
            // useless to the operator; surface the malformed event in the
            // log and drop it rather than synthesising an empty alert that
            // would mask whatever PHD2 actually wanted to warn us about.
            let Some(message) = msg.extra.get("Msg").and_then(|v| v.as_str()) else {
                tracing::warn!(
                    "PHD2: Alert event missing 'Msg' field — dropping ({})",
                    msg.extra
                );
                return None;
            };
            let Some(alert_type) = msg.extra.get("Type").and_then(|v| v.as_str()) else {
                tracing::warn!(
                    "PHD2: Alert event missing 'Type' field — dropping ({})",
                    msg.extra
                );
                return None;
            };
            Some(Phd2Event::Alert {
                message: message.to_string(),
                alert_type: alert_type.to_string(),
            })
        }
        _ => None,
    }
}

/// Map a PHD2 application-state string to a `Phd2State`.
///
/// PHD2's documented states are `Stopped`, `Selected`, `Calibrating`,
/// `Guiding`, `Looping`, `Paused`, and `LostLock`; the `Settling` state shows
/// up via dedicated events. Newer PHD2 builds occasionally introduce
/// additional state names (e.g. `GuidingPaused`, `StarFound`). When we see an
/// unrecognised value, we **must not** silently coerce it to `Connected` —
/// that masked guiding regressions for the duration of an entire imaging
/// session. Instead, surface it as `Phd2State::Unknown(raw)` and emit a
/// warn-level log so the operator (and our diagnostics) can react.
fn parse_phd2_app_state(state_str: &str) -> Phd2State {
    match state_str {
        "Stopped" => Phd2State::Connected,
        "Selected" => Phd2State::Connected,
        "Calibrating" => Phd2State::Calibrating,
        "Guiding" => Phd2State::Guiding,
        "Looping" => Phd2State::Looping,
        "Paused" => Phd2State::Paused,
        "LostLock" => Phd2State::LostLock,
        other => {
            tracing::warn!(
                "PHD2: unrecognised app-state {:?} — preserving as Phd2State::Unknown",
                other
            );
            Phd2State::Unknown(other.to_string())
        }
    }
}

/// Simple base64 decoder
fn base64_decode(input: &str) -> Result<Vec<u8>, String> {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    let input = input.trim().replace(['\n', '\r'], "");
    let mut output = Vec::with_capacity(input.len() * 3 / 4);

    let mut buf = 0u32;
    let mut bits = 0;

    for c in input.bytes() {
        if c == b'=' {
            break;
        }

        let val = ALPHABET
            .iter()
            .position(|&x| x == c)
            .ok_or_else(|| format!("Invalid base64 character: {}", c as char))?;

        buf = (buf << 6) | (val as u32);
        bits += 6;

        if bits >= 8 {
            bits -= 8;
            output.push((buf >> bits) as u8);
            buf &= (1 << bits) - 1;
        }
    }

    Ok(output)
}

/// Check if PHD2's event server is listening on the default port.
pub fn is_phd2_running() -> bool {
    is_phd2_server_listening("127.0.0.1", 4400)
}

/// Check if PHD2 is installed
pub fn is_phd2_installed() -> bool {
    #[cfg(target_os = "windows")]
    {
        use std::process::Command;
        // Check registry for PHD2 installation
        let output = Command::new("reg")
            .args(["query", "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\PHD 2_is1", "/v", "InstallLocation"])
            .output();

        match output {
            Ok(o) => o.status.success(),
            Err(_) => false,
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        use std::path::Path;
        use std::process::Command;

        #[cfg(target_os = "macos")]
        {
            if Path::new("/Applications/PHD2.app").exists()
                || Path::new("/Applications/PHD2.app/Contents/MacOS/PHD2").exists()
            {
                return true;
            }
        }

        for candidate in [
            "/usr/bin/phd2",
            "/usr/local/bin/phd2",
            "/snap/bin/phd2",
            "/opt/homebrew/bin/phd2",
        ] {
            if Path::new(candidate).exists() {
                return true;
            }
        }

        // PATH-based check for Linux/macOS.
        // Why: `is_phd2_installed` returns `bool` and is a
        // purely best-effort heuristic before the launcher tries fallbacks.
        // If we cannot even spawn `sh` (sandboxed environment, missing
        // /bin/sh on a stripped container, OS errno EPERM), treating that
        // as "not installed via PATH" is the correct answer because we
        // simultaneously couldn't run `phd2` from PATH either. The other
        // (well-known-path) branches above already returned `true` early
        // if PHD2 was found, so reaching this line means PATH is the only
        // remaining option.
        Command::new("sh")
            .args(["-lc", "command -v phd2 >/dev/null 2>&1"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }
}

/// Launch PHD2 application
pub fn launch_phd2() -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        use std::process::Command;

        // Get install location
        let output = Command::new("reg")
            .args(["query", "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\PHD 2_is1", "/v", "InstallLocation"])
            .output()
            .map_err(|e| format!("Failed to query registry: {}", e))?;

        if !output.status.success() {
            return Err("PHD2 not found in registry".to_string());
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        // Parse path from output
        let path_line = stdout
            .lines()
            .find(|l| l.contains("InstallLocation"))
            .ok_or("InstallLocation not found")?;
        let path_part = path_line
            .split("REG_SZ")
            .nth(1)
            .ok_or("Invalid registry output")?
            .trim();

        let exe_path = std::path::Path::new(path_part).join("phd2.exe");

        tracing::info!("Launching PHD2 from: {:?}", exe_path);

        Command::new(exe_path)
            .spawn()
            .map_err(|e| format!("Failed to launch PHD2: {}", e))?;

        Ok(())
    }
    #[cfg(not(target_os = "windows"))]
    {
        use std::path::Path;
        use std::process::Command;

        #[cfg(target_os = "macos")]
        {
            let status = Command::new("open")
                .args(["-a", "PHD2"])
                .status()
                .map_err(|e| format!("Failed to launch PHD2 via open: {}", e))?;
            if status.success() {
                return Ok(());
            }
        }

        for candidate in [
            "/usr/bin/phd2",
            "/usr/local/bin/phd2",
            "/snap/bin/phd2",
            "/opt/homebrew/bin/phd2",
        ] {
            if Path::new(candidate).exists() {
                Command::new(candidate)
                    .spawn()
                    .map_err(|e| format!("Failed to launch PHD2 from {}: {}", candidate, e))?;
                return Ok(());
            }
        }

        Command::new("phd2")
            .spawn()
            .map_err(|e| format!("Failed to launch PHD2: {}", e))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    /// Feed PHD2 event lines through the reader's own line handler and
    /// return the rolling stats it keeps.
    fn feed_lines(lines: &[String]) -> GuideStats {
        let registry = Arc::new(Mutex::new(HashMap::new()));
        let stats = Arc::new(Mutex::new(RollingGuideStats::default()));
        let state = Arc::new(Mutex::new(Phd2State::Connected));
        let settle = Arc::new(Mutex::new(SettleTracker::default()));
        for line in lines {
            Phd2Client::process_line(
                line,
                &registry,
                &stats,
                &state,
                &None,
                &settle,
                &LoopingFrames::default(),
            );
        }
        let result = stats.lock().unwrap().get_stats();
        result
    }

    fn guide_step(frame: u32, ra: f64, dec: f64) -> String {
        format!(
            r#"{{"Event":"GuideStep","Frame":{frame},"RADistanceRaw":{ra},"DECDistanceRaw":{dec},"SNR":20.0}}"#
        )
    }

    /// The RMS the recovery settle gate reads must describe the guiding that
    /// is happening now. Samples from before the guider was stopped and
    /// started again (a lost star chased at 57 px, an autofocus interlude)
    /// kept a re-acquired guider over its 2 px bound for the next hundred
    /// frames, several minutes at usual guide exposures, so a recovery that
    /// worked was judged as failed.
    #[test]
    fn a_new_guiding_session_starts_a_new_rms_window() {
        let mut lines: Vec<String> = (0..100).map(|i| guide_step(i, 57.0, 54.0)).collect();
        lines.push(r#"{"Event":"GuidingStopped"}"#.to_string());
        lines.push(r#"{"Event":"StartGuiding"}"#.to_string());
        lines.extend((0..30).map(|i| guide_step(i, 0.3, 0.3)));

        let stats = feed_lines(&lines);
        assert!(
            stats.rms_total <= 2.0,
            "RMS after a fresh start still carries the old session: {:.2} px",
            stats.rms_total
        );
    }

    #[test]
    fn normalizes_localhost_for_tcp() {
        assert_eq!(normalize_phd2_tcp_host("localhost"), "127.0.0.1");
        assert_eq!(normalize_phd2_tcp_host("LOCALHOST"), "127.0.0.1");
        assert_eq!(normalize_phd2_tcp_host("::1"), "127.0.0.1");
        assert_eq!(normalize_phd2_tcp_host("  "), "127.0.0.1");
        assert_eq!(normalize_phd2_tcp_host("192.168.1.5"), "192.168.1.5");
    }

    /// Documented PHD2 app states map deterministically and
    /// unambiguously. Two of them (`Stopped`, `Selected`) collapse to
    /// `Connected` per PHD2's protocol semantics; the rest are 1:1.
    #[test]
    fn parses_known_phd2_app_states() {
        assert_eq!(parse_phd2_app_state("Stopped"), Phd2State::Connected);
        assert_eq!(parse_phd2_app_state("Selected"), Phd2State::Connected);
        assert_eq!(parse_phd2_app_state("Calibrating"), Phd2State::Calibrating);
        assert_eq!(parse_phd2_app_state("Guiding"), Phd2State::Guiding);
        assert_eq!(parse_phd2_app_state("Looping"), Phd2State::Looping);
        assert_eq!(parse_phd2_app_state("Paused"), Phd2State::Paused);
        assert_eq!(parse_phd2_app_state("LostLock"), Phd2State::LostLock);
    }

    /// Unknown PHD2 state names must surface as `Unknown(raw)` so the raw
    /// string is preserved end-to-end (logs, telemetry, UI).
    #[test]
    fn unknown_phd2_state_preserves_raw_string() {
        for sample in &["GuidingPaused", "StarFound", "", "TotallyMadeUpState"] {
            match parse_phd2_app_state(sample) {
                Phd2State::Unknown(raw) => assert_eq!(raw, *sample, "raw string must round-trip"),
                other => panic!("expected Phd2State::Unknown({:?}), got {:?}", sample, other),
            }
        }
    }

    /// SettleDone with `Status: 0` parses as a successful settle.
    #[test]
    fn settle_done_success_parses_status_zero() {
        let json = r#"{"Event":"SettleDone","Status":0,"TotalFrames":7,"DroppedFrames":1}"#;
        let msg: Phd2EventMessage = serde_json::from_str(json).unwrap();
        match parse_phd2_event(&msg) {
            Some(Phd2Event::SettleDone {
                status,
                error,
                total_frames,
                dropped_frames,
            }) => {
                assert_eq!(status, 0);
                assert!(error.is_empty());
                assert_eq!(total_frames, 7);
                assert_eq!(dropped_frames, 1);
            }
            other => panic!("expected SettleDone, got {:?}", other),
        }
    }

    /// SettleDone with a non-zero `Status` carries the failure + error string.
    #[test]
    fn settle_done_failure_parses_status_and_error() {
        let json = r#"{"Event":"SettleDone","Status":1,"Error":"timed-out","TotalFrames":3,"DroppedFrames":0}"#;
        let msg: Phd2EventMessage = serde_json::from_str(json).unwrap();
        match parse_phd2_event(&msg) {
            Some(Phd2Event::SettleDone { status, error, .. }) => {
                assert_eq!(status, 1);
                assert_eq!(error, "timed-out");
            }
            other => panic!("expected SettleDone, got {:?}", other),
        }
    }

    /// A SettleDone missing `Status` must be treated as a FAILURE (non-zero),
    /// never silently reported as a successful settle.
    #[test]
    fn settle_done_missing_status_is_failure() {
        let json = r#"{"Event":"SettleDone","TotalFrames":1,"DroppedFrames":0}"#;
        let msg: Phd2EventMessage = serde_json::from_str(json).unwrap();
        match parse_phd2_event(&msg) {
            Some(Phd2Event::SettleDone { status, error, .. }) => {
                assert_ne!(status, 0, "missing Status must not be treated as success");
                assert!(!error.is_empty(), "failure must carry an explanation");
            }
            other => panic!("expected SettleDone, got {:?}", other),
        }
    }

    /// The settle waiter fails closed on a non-zero PHD2 status, surfacing the
    /// PHD2 error string.
    #[test]
    fn settle_waiter_fails_closed_on_nonzero_status() {
        let tracker = Arc::new(Mutex::new(SettleTracker {
            generation: 1,
            awaiting: true,
            outcome: Some(SettleOutcome {
                status: 2,
                error: "star lost".to_string(),
                total_frames: 0,
                dropped_frames: 0,
            }),
        }));
        let waiter = SettleWaiter {
            settle_tracker: tracker,
            running: Arc::new(AtomicBool::new(true)),
            state: Arc::new(Mutex::new(Phd2State::Guiding)),
            generation: 1,
        };
        let err = waiter
            .wait(Duration::from_millis(100))
            .expect_err("non-zero status must error");
        assert!(err.contains("star lost"), "error string surfaced: {err}");
    }

    /// The settle waiter returns the outcome on a status-0 settle.
    #[test]
    fn settle_waiter_succeeds_on_status_zero() {
        let tracker = Arc::new(Mutex::new(SettleTracker {
            generation: 5,
            awaiting: true,
            outcome: Some(SettleOutcome {
                status: 0,
                error: String::new(),
                total_frames: 4,
                dropped_frames: 0,
            }),
        }));
        let waiter = SettleWaiter {
            settle_tracker: tracker,
            running: Arc::new(AtomicBool::new(true)),
            state: Arc::new(Mutex::new(Phd2State::Guiding)),
            generation: 5,
        };
        let outcome = waiter
            .wait(Duration::from_millis(100))
            .expect("status 0 settles");
        assert_eq!(outcome.total_frames, 4);
    }

    /// The settle waiter times out (fails closed) when SettleDone never arrives.
    #[test]
    fn settle_waiter_times_out_when_no_settle_done() {
        let tracker = Arc::new(Mutex::new(SettleTracker {
            generation: 1,
            awaiting: true,
            outcome: None,
        }));
        let waiter = SettleWaiter {
            settle_tracker: tracker,
            running: Arc::new(AtomicBool::new(true)),
            state: Arc::new(Mutex::new(Phd2State::Guiding)),
            generation: 1,
        };
        let err = waiter
            .wait(Duration::from_millis(250))
            .expect_err("must time out");
        assert!(err.contains("did not complete"), "got: {err}");
    }

    /// The settle waiter fails closed if the connection drops mid-settle.
    #[test]
    fn settle_waiter_fails_closed_on_disconnect() {
        let tracker = Arc::new(Mutex::new(SettleTracker {
            generation: 1,
            awaiting: true,
            outcome: None,
        }));
        let waiter = SettleWaiter {
            settle_tracker: tracker,
            running: Arc::new(AtomicBool::new(false)),
            state: Arc::new(Mutex::new(Phd2State::Guiding)),
            generation: 1,
        };
        let err = waiter
            .wait(Duration::from_secs(30))
            .expect_err("disconnect must error");
        assert!(err.contains("disconnected"), "got: {err}");
    }

    /// PHD2 returns -32600 when `params` is JSON null; omit the field instead.
    #[test]
    fn json_rpc_request_omits_null_params() {
        let request = JsonRpcRequest {
            method: "get_app_state".to_string(),
            params: None,
            id: 1,
        };
        let json = serde_json::to_string(&request).unwrap();
        assert!(!json.contains("params"));
        assert!(json.contains("\"method\":\"get_app_state\""));
        assert!(json.contains("\"id\":1"));
    }

    /// Replay the overnight failure: TCP stays open, but that connection no
    /// longer services commands. A new connection to the same PHD2 is healthy.
    #[test]
    fn stalled_rpc_connection_is_replaced_for_a_safe_retry() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (stalled, _) = listener.accept().unwrap();
            let mut old_reader = BufReader::new(stalled.try_clone().unwrap());
            let mut request = String::new();
            old_reader.read_line(&mut request).unwrap();
            assert!(request.contains("get_app_state"));
            listener.set_nonblocking(true).unwrap();
            let deadline = Instant::now() + Duration::from_secs(25);
            while Instant::now() < deadline {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream
                            .set_read_timeout(Some(Duration::from_secs(3)))
                            .unwrap();
                        let mut reader = BufReader::new(stream.try_clone().unwrap());
                        let mut line = String::new();
                        reader.read_line(&mut line).unwrap();
                        let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                        assert_eq!(request["method"], "get_app_state");
                        writeln!(
                            stream,
                            "{}",
                            serde_json::json!({
                                "jsonrpc": "2.0", "result": "Guiding", "id": request["id"]
                            })
                        )
                        .unwrap();
                        return;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10))
                    }
                    Err(e) => panic!("accept: {e}"),
                }
            }
            panic!("client never replaced the stalled socket");
        });
        let mut client = Phd2Client::new("127.0.0.1", port);
        client.connect().unwrap();
        let reply = client.get_app_state();
        client.disconnect();
        assert_eq!(reply.unwrap(), Phd2State::Guiding);
        server.join().unwrap();
    }

    #[test]
    fn recovery_is_bounded_and_respects_auto_reconnect_disabled() {
        for auto_reconnect in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            let server = thread::spawn(move || {
                for _ in 0..if auto_reconnect { 2 } else { 1 } {
                    let (stream, _) = listener.accept().unwrap();
                    stream
                        .set_read_timeout(Some(Duration::from_secs(3)))
                        .unwrap();
                    let mut reader = BufReader::new(stream);
                    assert_eq!(read_rpc(&mut reader)["method"], "get_app_state");
                    // Neither connection can service the request.
                }
            });
            let mut client = Phd2Client::with_config(
                "127.0.0.1",
                port,
                Phd2ConnectionConfig {
                    auto_reconnect,
                    ..Default::default()
                },
            );
            client.connect().unwrap();
            let error = client.get_app_state().unwrap_err();
            assert_eq!(
                error.contains("fresh connection also failed"),
                auto_reconnect
            );
            assert!(!client.is_connected());
            client.disconnect();
            server.join().unwrap();
        }
    }

    fn read_rpc(reader: &mut BufReader<TcpStream>) -> serde_json::Value {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
    }

    #[test]
    fn stop_capture_recovers_a_stalled_connection_and_confirms_stopped() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (stalled, _) = listener.accept().unwrap();
            stalled
                .set_read_timeout(Some(Duration::from_secs(15)))
                .unwrap();
            let mut reader = BufReader::new(stalled);
            assert_eq!(read_rpc(&mut reader)["method"], "stop_capture");
            // The client must close the stale socket, not send another stop on it.
            let mut line = String::new();
            assert_eq!(reader.read_line(&mut line).unwrap(), 0);
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            for (method, result) in [
                ("stop_capture", serde_json::json!(0)),
                ("get_app_state", serde_json::json!("Stopped")),
            ] {
                let request = read_rpc(&mut reader);
                assert_eq!(request["method"], method);
                writeln!(
                    stream,
                    "{}",
                    serde_json::json!({
                        "jsonrpc": "2.0", "result": result, "id": request["id"]
                    })
                )
                .unwrap();
            }
        });
        let mut client = Phd2Client::new("127.0.0.1", port);
        client.connect().unwrap();
        client.stop_capture().unwrap();
        assert_eq!(client.get_app_state_name().unwrap(), "Stopped");
        client.disconnect();
        server.join().unwrap();
    }

    #[test]
    fn uncertain_dither_is_not_replayed_and_old_settle_cannot_complete_after_reconnect() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            assert_eq!(read_rpc(&mut reader)["method"], "dither");
            // The dither may have run; lose the reply and the connection.
            drop(reader);
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let request = read_rpc(&mut reader);
            assert_eq!(request["method"], "get_app_state", "must not replay dither");
            writeln!(
                stream,
                "{}",
                serde_json::json!({
                    "jsonrpc": "2.0", "result": "Guiding", "id": request["id"]
                })
            )
            .unwrap();
            let request = read_rpc(&mut reader);
            assert_eq!(request["method"], "guide");
            writeln!(
                stream,
                "{}",
                serde_json::json!({
                    "jsonrpc": "2.0", "result": 0, "id": request["id"]
                })
            )
            .unwrap();
            writeln!(stream, "{{\"Event\":\"SettleDone\",\"Status\":0}}").unwrap();
            // Keep the connection alive until the client finishes checking settle.
            let mut end = String::new();
            assert_eq!(reader.read_line(&mut end).unwrap(), 0);
        });
        let mut client = Phd2Client::new("127.0.0.1", port);
        client.connect().unwrap();
        let old_waiter = client.arm_settle();
        let start = Instant::now();
        assert!(client.dither_arm(2.0, false, 1.0, 1.0, 5.0).is_err());
        assert!(
            start.elapsed() < Duration::from_secs(3),
            "EOF must wake the waiter"
        );
        assert_eq!(client.get_app_state().unwrap(), Phd2State::Guiding);
        let waiter = client.guide_arm(1.0, 1.0, 5.0).unwrap();
        waiter.wait(Duration::from_secs(2)).unwrap();
        assert!(old_waiter.wait(Duration::from_millis(50)).is_err());
        client.disconnect();
        assert!(client
            .get_app_state()
            .unwrap_err()
            .contains("Not connected"));
        server.join().unwrap();
    }

    #[test]
    fn rpc_error_and_fragmented_response_do_not_reconnect() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let request = read_rpc(&mut reader);
            writeln!(stream, "{}", serde_json::json!({
                "jsonrpc": "2.0", "error": {"code": 1, "message": "no star"}, "id": request["id"]
            })).unwrap();
            let request = read_rpc(&mut reader);
            let response = format!(
                "{}\r\n",
                serde_json::json!({
                    "jsonrpc": "2.0", "result": "Guiding", "id": request["id"]
                })
            );
            let split = response.len() / 2;
            stream.write_all(&response.as_bytes()[..split]).unwrap();
            thread::sleep(Duration::from_millis(200));
            stream.write_all(&response.as_bytes()[split..]).unwrap();
        });
        let mut client = Phd2Client::new("127.0.0.1", port);
        client.connect().unwrap();
        assert!(client.find_star().unwrap_err().contains("no star"));
        assert_eq!(client.get_app_state().unwrap(), Phd2State::Guiding);
        client.disconnect();
        server.join().unwrap();
    }

    #[test]
    fn clear_calibration_uses_phd2_positional_parameter_array() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock PHD2");
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept client");
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).expect("read request");
            let request: serde_json::Value =
                serde_json::from_str(line.trim()).expect("valid request JSON");
            assert_eq!(request["method"], "clear_calibration");
            assert_eq!(request["params"], serde_json::json!(["both"]));

            let id = request["id"].as_u64().expect("numeric request id");
            let mut writer = stream;
            writeln!(
                writer,
                "{}",
                serde_json::json!({"jsonrpc": "2.0", "result": 0, "id": id})
            )
            .expect("write response");
            writer.flush().expect("flush response");
        });

        let mut client = Phd2Client::new("127.0.0.1", port);
        client.connect().expect("connect mock PHD2");
        client
            .clear_calibration("both")
            .expect("clear calibration response");
        client.disconnect();
        server.join().expect("mock server completed");
    }

    /// PHD2 measures the selected star in every looping frame. A recovery
    /// compares that against the star the run guided on, so the measurement
    /// must be the one from the newest frame, and a frame with no star
    /// selected must not leave an older star standing in for it.
    #[test]
    fn looping_frames_carry_the_selected_star_and_forget_it_when_gone() {
        let looping = LoopingFrames::default();
        looping.record(&serde_json::json!({"Frame": 7, "SNR": 59.4, "StarMass": 21763.0}));
        let star = *looping.star.lock().unwrap();
        assert_eq!(
            star,
            Some(LoopingStar {
                frame: 1,
                snr: 59.4,
                star_mass: 21763.0
            })
        );
        looping.record(&serde_json::json!({"Frame": 8}));
        assert_eq!(*looping.star.lock().unwrap(), None);
        assert_eq!(looping.count.load(Ordering::SeqCst), 2);
    }

    /// Guide steps carry the star's mass; the rolling statistics report it so
    /// a later star can be compared with the one the run guided on.
    #[test]
    fn rolling_stats_report_the_guide_star_mass() {
        let lines: Vec<String> = (0..4)
            .map(|i| {
                format!(
                    r#"{{"Event":"GuideStep","Frame":{i},"RADistanceRaw":0.2,"DECDistanceRaw":0.1,"SNR":230.0,"StarMass":750000}}"#
                )
            })
            .collect();
        let stats = feed_lines(&lines);
        assert!((stats.star_mass - 750_000.0).abs() < 1e-6, "{stats:?}");
        assert!((stats.snr - 230.0).abs() < 1e-6, "{stats:?}");
    }
}
