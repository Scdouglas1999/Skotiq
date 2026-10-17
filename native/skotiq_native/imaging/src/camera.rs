//! Camera control abstraction
//!
//! Provides a unified interface for camera control including:
//! - Exposure control (duration, gain, offset, binning)
//! - Cooling control (set temp, warmup routine)
//! - Frame type selection
//! - Single frame and looping capture modes

use crate::{
    naming::{FrameCounter, FrameType, NamingContext, NamingPattern},
    ImageData,
};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, Mutex};

/// Camera connection state
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CameraState {
    #[default]
    Disconnected,
    Connecting,
    Connected,
    Exposing,
    Downloading,
    Error,
}

/// Exposure settings
#[derive(Debug, Clone)]
pub struct ExposureSettings {
    /// Exposure duration in seconds
    pub duration: f64,
    /// Camera gain (0-100 typically)
    pub gain: i32,
    /// Camera offset/brightness
    pub offset: i32,
    /// X binning (1, 2, 4)
    pub binning_x: u32,
    /// Y binning (1, 2, 4)
    pub binning_y: u32,
    /// Frame type
    pub frame_type: FrameType,
    /// Subframe X position (pixels)
    pub sub_x: u32,
    /// Subframe Y position (pixels)
    pub sub_y: u32,
    /// Subframe width (0 = full frame)
    pub sub_width: u32,
    /// Subframe height (0 = full frame)
    pub sub_height: u32,
    /// Fast readout mode
    pub fast_readout: bool,
}

impl Default for ExposureSettings {
    fn default() -> Self {
        Self {
            duration: 1.0,
            gain: 100,
            offset: 10,
            binning_x: 1,
            binning_y: 1,
            frame_type: FrameType::Light,
            sub_x: 0,
            sub_y: 0,
            sub_width: 0,
            sub_height: 0,
            fast_readout: false,
        }
    }
}

/// Cooling settings
#[derive(Debug, Clone)]
pub struct CoolingSettings {
    /// Target temperature in Celsius
    pub target_temp: f64,
    /// Cooling enabled
    pub enabled: bool,
    /// Warmup rate in degrees per minute
    pub warmup_rate: f64,
    /// Cooldown rate in degrees per minute
    pub cooldown_rate: f64,
}

impl Default for CoolingSettings {
    fn default() -> Self {
        Self {
            target_temp: -10.0,
            enabled: false,
            warmup_rate: 2.0,   // 2°C per minute
            cooldown_rate: 5.0, // 5°C per minute
        }
    }
}

/// Cooling status
#[derive(Debug, Clone)]
pub struct CoolingStatus {
    pub current_temp: f64,
    pub target_temp: f64,
    pub cooler_power: f64, // 0-100%
    pub is_at_target: bool,
    pub is_cooling: bool,
}

/// Camera capabilities
#[derive(Debug, Clone, Default)]
pub struct CameraCapabilities {
    /// Sensor width in pixels
    pub sensor_width: u32,
    /// Sensor height in pixels
    pub sensor_height: u32,
    /// Pixel size in microns
    pub pixel_size: f64,
    /// Maximum binning supported
    pub max_binning: u32,
    /// Supported binning modes
    pub binning_modes: Vec<(u32, u32)>,
    /// Has cooler
    pub has_cooler: bool,
    /// Minimum cooling temperature
    pub min_cool_temp: f64,
    /// Maximum cooling temperature
    pub max_cool_temp: f64,
    /// Is color camera
    pub is_color: bool,
    /// Bayer pattern (if color)
    pub bayer_pattern: Option<String>,
    /// Has shutter
    pub has_shutter: bool,
    /// Maximum gain
    pub max_gain: i32,
    /// Maximum offset
    pub max_offset: i32,
    /// Minimum exposure in seconds
    pub min_exposure: f64,
    /// Maximum exposure in seconds
    pub max_exposure: f64,
    /// Bit depth
    pub bit_depth: u32,
    /// Camera name
    pub name: String,
    /// Driver info
    pub driver_info: String,
}

/// Capture mode
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CaptureMode {
    /// Single frame capture
    #[default]
    Single,
    /// Loop until stopped
    Loop,
    /// Capture specific number of frames
    Count(u32),
}

/// Capture progress event
#[derive(Debug, Clone)]
#[allow(clippy::large_enum_variant)]
pub enum CaptureEvent {
    /// Exposure started
    ExposureStarted {
        frame_number: u32,
        total_frames: Option<u32>,
        duration: f64,
    },
    /// Exposure progress update
    ExposureProgress {
        frame_number: u32,
        elapsed: f64,
        remaining: f64,
        percent: f64,
    },
    /// Exposure completed, downloading
    ExposureCompleted { frame_number: u32 },
    /// Download progress
    DownloadProgress { frame_number: u32, percent: f64 },
    /// Image captured successfully
    ImageCaptured {
        frame_number: u32,
        image: Arc<ImageData>,
        context: NamingContext,
    },
    /// Capture error
    Error { frame_number: u32, message: String },
    /// All frames completed
    CaptureCompleted { total_frames: u32 },
    /// Capture cancelled
    CaptureCancelled { frame_number: u32 },
}

/// Camera control interface
#[async_trait::async_trait]
pub trait CameraController: Send + Sync {
    /// Get camera capabilities
    fn capabilities(&self) -> &CameraCapabilities;

    /// Get current connection state
    fn state(&self) -> CameraState;

    /// Connect to camera
    async fn connect(&mut self) -> Result<(), CameraError>;

    /// Disconnect from camera
    async fn disconnect(&mut self) -> Result<(), CameraError>;

    /// Start an exposure
    async fn start_exposure(&mut self, settings: &ExposureSettings) -> Result<(), CameraError>;

    /// Check if exposure is in progress
    fn is_exposing(&self) -> bool;

    /// Get exposure progress (0.0 - 1.0)
    fn exposure_progress(&self) -> f64;

    /// Cancel current exposure
    async fn cancel_exposure(&mut self) -> Result<(), CameraError>;

    /// Download the image after exposure
    async fn download_image(&mut self) -> Result<ImageData, CameraError>;

    /// Set cooler temperature
    async fn set_cooler_temp(&mut self, temp: f64) -> Result<(), CameraError>;

    /// Enable/disable cooler
    async fn set_cooler_enabled(&mut self, enabled: bool) -> Result<(), CameraError>;

    /// Get cooling status
    fn cooling_status(&self) -> CoolingStatus;

    /// Get current sensor temperature
    fn sensor_temp(&self) -> f64;
}

/// Camera errors
#[derive(Debug, Clone)]
pub enum CameraError {
    NotConnected,
    AlreadyConnected,
    ExposureInProgress,
    NoExposure,
    ConnectionFailed(String),
    ExposureFailed(String),
    DownloadFailed(String),
    CoolerFailed(String),
    Cancelled,
    Timeout,
    InvalidSettings(String),
}

impl std::fmt::Display for CameraError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CameraError::NotConnected => write!(f, "Camera not connected"),
            CameraError::AlreadyConnected => write!(f, "Camera already connected"),
            CameraError::ExposureInProgress => write!(f, "Exposure already in progress"),
            CameraError::NoExposure => write!(f, "No exposure to download"),
            CameraError::ConnectionFailed(s) => write!(f, "Connection failed: {}", s),
            CameraError::ExposureFailed(s) => write!(f, "Exposure failed: {}", s),
            CameraError::DownloadFailed(s) => write!(f, "Download failed: {}", s),
            CameraError::CoolerFailed(s) => write!(f, "Cooler failed: {}", s),
            CameraError::Cancelled => write!(f, "Operation cancelled"),
            CameraError::Timeout => write!(f, "Operation timed out"),
            CameraError::InvalidSettings(s) => write!(f, "Invalid settings: {}", s),
        }
    }
}

impl std::error::Error for CameraError {}

/// Capture session manager
#[allow(dead_code)]
pub struct CaptureSession {
    /// Camera controller
    camera: Arc<Mutex<Box<dyn CameraController>>>,
    /// Exposure settings
    settings: ExposureSettings,
    /// Capture mode
    mode: CaptureMode,
    /// Naming pattern
    pattern: NamingPattern,
    /// Frame counter
    counter: Arc<Mutex<FrameCounter>>,
    /// Base naming context
    base_context: NamingContext,
    /// Cancel flag
    cancel_flag: Arc<AtomicBool>,
    /// Event sender
    event_tx: mpsc::UnboundedSender<CaptureEvent>,
    /// Dither callback (called between frames)
    dither_callback: Option<Box<dyn Fn(u32) -> bool + Send + Sync>>,
    /// Delay between frames
    frame_delay: Duration,
}

impl CaptureSession {
    /// Create a new capture session
    pub fn new(
        camera: Arc<Mutex<Box<dyn CameraController>>>,
        settings: ExposureSettings,
        mode: CaptureMode,
        pattern: NamingPattern,
        base_context: NamingContext,
    ) -> (Self, mpsc::UnboundedReceiver<CaptureEvent>) {
        let (event_tx, event_rx) = mpsc::unbounded_channel();

        let session = Self {
            camera,
            settings,
            mode,
            pattern,
            counter: Arc::new(Mutex::new(FrameCounter::new())),
            base_context,
            cancel_flag: Arc::new(AtomicBool::new(false)),
            event_tx,
            dither_callback: None,
            frame_delay: Duration::from_millis(100),
        };

        (session, event_rx)
    }

    /// Set dither callback
    pub fn with_dither_callback<F>(mut self, callback: F) -> Self
    where
        F: Fn(u32) -> bool + Send + Sync + 'static,
    {
        self.dither_callback = Some(Box::new(callback));
        self
    }

    /// Set delay between frames
    pub fn with_frame_delay(mut self, delay: Duration) -> Self {
        self.frame_delay = delay;
        self
    }

    /// Get cancel flag for external cancellation
    pub fn cancel_flag(&self) -> Arc<AtomicBool> {
        self.cancel_flag.clone()
    }

    /// Run the capture session
    pub async fn run(&self) -> Result<u32, CameraError> {
        let total_frames = match self.mode {
            CaptureMode::Single => Some(1),
            CaptureMode::Count(n) => Some(n),
            CaptureMode::Loop => None,
        };

        let mut frame_number = 0u32;

        loop {
            // Check for cancellation
            if self.cancel_flag.load(Ordering::Relaxed) {
                let _ = self
                    .event_tx
                    .send(CaptureEvent::CaptureCancelled { frame_number });
                return Err(CameraError::Cancelled);
            }

            frame_number += 1;

            // Check if we've reached the target frame count
            if let Some(total) = total_frames {
                if frame_number > total {
                    break;
                }
            }

            // Update context with frame number
            let counter_key = FrameCounter::key_from_context(&self.base_context);
            let seq_frame_num = {
                let mut counter = self.counter.lock().await;
                counter.next(&counter_key)
            };

            let mut context = self.base_context.clone();
            context.frame_number = Some(seq_frame_num);
            context.exposure_time = Some(self.settings.duration);
            context.gain = Some(self.settings.gain);
            context.offset = Some(self.settings.offset);
            context.binning_x = Some(self.settings.binning_x);
            context.binning_y = Some(self.settings.binning_y);
            context.frame_type = self.settings.frame_type;
            context = context.with_current_time();

            // Capture single frame
            match self
                .capture_frame(frame_number, total_frames, &context)
                .await
            {
                Ok(image) => {
                    let _ = self.event_tx.send(CaptureEvent::ImageCaptured {
                        frame_number,
                        image: Arc::new(image),
                        context: context.clone(),
                    });
                }
                Err(CameraError::Cancelled) => {
                    let _ = self
                        .event_tx
                        .send(CaptureEvent::CaptureCancelled { frame_number });
                    return Err(CameraError::Cancelled);
                }
                Err(e) => {
                    let _ = self.event_tx.send(CaptureEvent::Error {
                        frame_number,
                        message: e.to_string(),
                    });
                    // Continue on error in loop mode, fail otherwise
                    if matches!(self.mode, CaptureMode::Single) {
                        return Err(e);
                    }
                }
            }

            // Call dither callback if set
            if let Some(ref dither) = self.dither_callback {
                if !dither(frame_number) {
                    // Dither failed, continue anyway
                }
            }

            // Delay between frames (except for single frame)
            if !matches!(self.mode, CaptureMode::Single) {
                tokio::time::sleep(self.frame_delay).await;
            }
        }

        let _ = self.event_tx.send(CaptureEvent::CaptureCompleted {
            total_frames: frame_number,
        });

        Ok(frame_number)
    }

    /// Capture a single frame
    async fn capture_frame(
        &self,
        frame_number: u32,
        total_frames: Option<u32>,
        _context: &NamingContext,
    ) -> Result<ImageData, CameraError> {
        let mut camera = self.camera.lock().await;

        // Send exposure started event
        let _ = self.event_tx.send(CaptureEvent::ExposureStarted {
            frame_number,
            total_frames,
            duration: self.settings.duration,
        });

        // Start exposure
        camera.start_exposure(&self.settings).await?;

        // Monitor exposure progress
        let start = Instant::now();
        let duration = self.settings.duration;

        while camera.is_exposing() {
            // Check for cancellation
            if self.cancel_flag.load(Ordering::Relaxed) {
                camera.cancel_exposure().await?;
                return Err(CameraError::Cancelled);
            }

            let elapsed = start.elapsed().as_secs_f64();
            let remaining = (duration - elapsed).max(0.0);
            let percent = (elapsed / duration * 100.0).min(100.0);

            let _ = self.event_tx.send(CaptureEvent::ExposureProgress {
                frame_number,
                elapsed,
                remaining,
                percent,
            });

            tokio::time::sleep(Duration::from_millis(100)).await;
        }

        // Send exposure completed event
        let _ = self
            .event_tx
            .send(CaptureEvent::ExposureCompleted { frame_number });

        // Download image
        let image = camera.download_image().await?;

        Ok(image)
    }
}

/// Cooldown/warmup manager
pub struct CoolingManager {
    camera: Arc<Mutex<Box<dyn CameraController>>>,
    settings: CoolingSettings,
    cancel_flag: Arc<AtomicBool>,
}

impl CoolingManager {
    pub fn new(camera: Arc<Mutex<Box<dyn CameraController>>>, settings: CoolingSettings) -> Self {
        Self {
            camera,
            settings,
            cancel_flag: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Start cooling to target temperature
    pub async fn cooldown(&self) -> Result<(), CameraError> {
        let mut camera = self.camera.lock().await;
        camera.set_cooler_enabled(true).await?;
        camera.set_cooler_temp(self.settings.target_temp).await?;
        drop(camera);

        // Wait for temperature to stabilize
        self.wait_for_temp(self.settings.target_temp, 0.5).await
    }

    /// Warm up camera gradually
    pub async fn warmup(&self) -> Result<(), CameraError> {
        let camera_lock = self.camera.lock().await;
        let current_temp = camera_lock.sensor_temp();
        let warm_target = camera_lock.capabilities().max_cool_temp;
        drop(camera_lock);

        // Calculate warmup steps
        let temp_diff = warm_target - current_temp;
        let steps = (temp_diff.abs() / 5.0).ceil() as i32; // 5°C steps

        for i in 1..=steps {
            if self.cancel_flag.load(Ordering::Relaxed) {
                return Err(CameraError::Cancelled);
            }

            let target = current_temp + (temp_diff * i as f64 / steps as f64);
            let mut camera = self.camera.lock().await;
            camera.set_cooler_temp(target).await?;
            drop(camera);

            // Wait between steps
            let wait_time = (5.0 / self.settings.warmup_rate * 60.0) as u64;
            tokio::time::sleep(Duration::from_secs(wait_time)).await;
        }

        // Disable cooler
        let mut camera = self.camera.lock().await;
        camera.set_cooler_enabled(false).await?;

        Ok(())
    }

    /// Wait for temperature to reach target
    async fn wait_for_temp(&self, target: f64, tolerance: f64) -> Result<(), CameraError> {
        let timeout = Duration::from_secs(300); // 5 minute timeout
        let start = Instant::now();

        loop {
            if self.cancel_flag.load(Ordering::Relaxed) {
                return Err(CameraError::Cancelled);
            }

            if start.elapsed() > timeout {
                return Err(CameraError::Timeout);
            }

            let camera = self.camera.lock().await;
            let current = camera.sensor_temp();
            drop(camera);

            if (current - target).abs() <= tolerance {
                return Ok(());
            }

            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }

    pub fn cancel(&self) {
        self.cancel_flag.store(true, Ordering::Relaxed);
    }
}
