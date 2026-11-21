use super::*;
use crate::device_manager::policy::policy;

#[test]
fn operation_guard_marks_and_clears_active_operations() {
    let manager = build_device_manager();

    // No operation in flight initially.
    assert!(!manager.is_operation_active("ascom:focuser"));

    {
        let _op = manager.begin_operation("ascom:focuser");
        // The guarded device is marked active...
        assert!(manager.is_operation_active("ascom:focuser"));
        // ...but an unrelated device is not, so a focuser move never
        // suppresses (for example) the mount's heartbeat.
        assert!(!manager.is_operation_active("ascom:mount"));
    }

    // Dropping the guard clears the marker so the heartbeat resumes.
    assert!(!manager.is_operation_active("ascom:focuser"));
}

#[test]
fn operation_guards_are_independent_per_device() {
    let manager = build_device_manager();
    let op_a = manager.begin_operation("focuser:a");
    {
        let _op_b = manager.begin_operation("focuser:b");
        assert!(manager.is_operation_active("focuser:a"));
        assert!(manager.is_operation_active("focuser:b"));
    }
    // Dropping b leaves a's marker intact.
    assert!(manager.is_operation_active("focuser:a"));
    assert!(!manager.is_operation_active("focuser:b"));
    drop(op_a);
    assert!(!manager.is_operation_active("focuser:a"));
}

#[test]
fn usb_contention_guard_marks_and_clears_contention() {
    let manager = build_device_manager();

    // No exposure in flight initially.
    assert!(!manager.is_usb_contended());

    {
        let _contention = manager.begin_usb_contention();
        assert!(
            manager.is_usb_contended(),
            "a live exposure window must mark the rig USB-contended"
        );
    }

    // Dropping the guard clears contention so aux heartbeats resume.
    assert!(!manager.is_usb_contended());
}

#[test]
fn usb_contention_nests_for_overlapping_exposures() {
    let manager = build_device_manager();

    let outer = manager.begin_usb_contention();
    {
        let _inner = manager.begin_usb_contention();
        assert!(manager.is_usb_contended());
    }
    // Inner exposure finished but the outer one is still running: the rig
    // remains contended until the LAST window closes. This is the dual-
    // camera / overlapping-frame case.
    assert!(
        manager.is_usb_contended(),
        "contention must persist while any exposure window is still open"
    );
    drop(outer);
    assert!(
        !manager.is_usb_contended(),
        "contention clears only after the last exposure window closes"
    );
}

#[test]
fn usb_contention_suppresses_only_aux_device_types() {
    // The focuser/filter-wheel/rotator share the camera's USB path and are
    // suppressed during a download window. The camera (which is driving the
    // contention) and the mount (own link, tracking-critical) are not.
    assert!(policy(DeviceType::Focuser).yields_to_camera_usb);
    assert!(policy(DeviceType::FilterWheel).yields_to_camera_usb);
    assert!(policy(DeviceType::Rotator).yields_to_camera_usb);

    for not_suppressed in [
        DeviceType::Camera,
        DeviceType::Mount,
        DeviceType::Dome,
        DeviceType::Weather,
        DeviceType::SafetyMonitor,
        DeviceType::Guider,
        DeviceType::Switch,
        DeviceType::CoverCalibrator,
    ] {
        assert!(
            !policy(not_suppressed).yields_to_camera_usb,
            "{:?} must NOT be suppressed by USB contention",
            not_suppressed
        );
    }
}

#[test]
fn escalate_to_disconnect_is_a_per_device_type_property() {
    // Every operational device escalates a sustained heartbeat loss so
    // stale registry state cannot remain advertised as connected.
    for escalating in [
        DeviceType::Camera,
        DeviceType::Mount,
        DeviceType::Focuser,
        DeviceType::FilterWheel,
        DeviceType::Rotator,
        DeviceType::Dome,
        DeviceType::Weather,
        DeviceType::Guider,
        DeviceType::Switch,
        DeviceType::CoverCalibrator,
    ] {
        assert!(
            policy(escalating).heartbeat.escalate_to_disconnect,
            "{:?} must escalate a heartbeat loss to disconnect",
            escalating
        );
    }

    // SafetyMonitor heartbeat is only a liveness hint; the independent
    // IsSafe signal owns enclosure safety decisions.
    assert!(
        !policy(DeviceType::SafetyMonitor)
            .heartbeat
            .escalate_to_disconnect
    );
}

/// A camera whose first liveness probe waits until the test says so, then fails.
struct GatedProbe {
    aborts: crate::device_manager::rig::camera::ExposureAborts,
    entered: std::sync::Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
    release: std::sync::Mutex<Option<tokio::sync::oneshot::Receiver<()>>>,
    probes: std::sync::atomic::AtomicU32,
}

#[async_trait::async_trait]
impl crate::device_manager::rig::RigDriver for GatedProbe {
    async fn disconnect(&self) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        let n = self
            .probes
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        if n == 0 {
            if let Some(entered) = self.entered.lock().expect("entered").take() {
                let _ = entered.send(());
            }
            let release = self.release.lock().expect("release").take();
            if let Some(release) = release {
                let _ = release.await;
            }
        }
        Err("probe failed".to_string())
    }
}

#[async_trait::async_trait]
impl crate::device_manager::rig::camera::Camera for GatedProbe {
    fn aborts(&self) -> &crate::device_manager::rig::camera::ExposureAborts {
        &self.aborts
    }

    async fn start_exposure(
        &self,
        _duration: f64,
        _gain: Option<i32>,
        _offset: Option<i32>,
        _bin_x: i32,
        _bin_y: i32,
        _subframe: Option<skotiq_device::SubFrame>,
        _frame_type: skotiq_device::FrameType,
    ) -> Result<(), crate::dispatch::error::DeviceOpError> {
        Err(crate::dispatch::error::DeviceOpError::unsupported("unused"))
    }

    async fn is_exposure_complete(&self) -> Result<bool, crate::dispatch::error::DeviceOpError> {
        Ok(true)
    }

    async fn stop_exposure(&self) -> Result<(), crate::dispatch::error::DeviceOpError> {
        Ok(())
    }

    async fn read_frame(&self) -> Result<skotiq_device::ImageData, crate::dispatch::error::DeviceOpError> {
        Err(crate::dispatch::error::DeviceOpError::unsupported("unused"))
    }

    async fn capture_preview(&self) -> Result<Vec<u8>, crate::dispatch::error::DeviceOpError> {
        Err(crate::dispatch::error::DeviceOpError::unsupported("unused"))
    }

    async fn status(
        &self,
    ) -> Result<crate::device::CameraStatus, crate::dispatch::error::DeviceOpError> {
        Err(crate::dispatch::error::DeviceOpError::unsupported("unused"))
    }

    async fn recommended_settings(
        &self,
    ) -> Result<skotiq_device::CameraRecommendedSettings, crate::dispatch::error::DeviceOpError> {
        Err(crate::dispatch::error::DeviceOpError::unsupported("unused"))
    }

    async fn set_gain(&self, _gain: i32) -> Result<(), crate::dispatch::error::DeviceOpError> {
        Ok(())
    }

    async fn set_offset(&self, _offset: i32) -> Result<(), crate::dispatch::error::DeviceOpError> {
        Ok(())
    }

    async fn use_readout_mode(
        &self,
        _name: &str,
    ) -> Result<crate::device_manager::rig::camera::ReadModeUse, crate::dispatch::error::DeviceOpError>
    {
        Ok(crate::device_manager::rig::camera::ReadModeUse::NoModes)
    }

    async fn set_cooler(
        &self,
        _enabled: bool,
        _target_temp: Option<f64>,
    ) -> Result<(), crate::dispatch::error::DeviceOpError> {
        Ok(())
    }

    async fn describe(
        &self,
        _device_id: &str,
    ) -> Result<skotiq_device::CameraDescription, crate::error::SkotiqError> {
        Err(crate::error::SkotiqError::NotConnected("unused".to_string()))
    }
}

fn disconnect_failure_counts(
    rx: &mut tokio::sync::broadcast::Receiver<crate::event::bus::SkotiqEvent>,
    id: &str,
) -> Vec<u32> {
    use crate::event::bus::EventPayload;
    use crate::event::equipment::{EquipmentEvent, HeartbeatStatus};
    let mut counts = Vec::new();
    loop {
        match rx.try_recv() {
            Ok(event) => {
                if let EventPayload::Equipment(EquipmentEvent::HeartbeatStatusChanged {
                    device_id,
                    status: HeartbeatStatus::Disconnected,
                    consecutive_failures,
                    ..
                }) = &event.payload
                {
                    if device_id == id {
                        counts.push(*consecutive_failures);
                    }
                }
            }
            Err(_) => break,
        }
    }
    counts
}

async fn insert_camera(
    manager: &DeviceManager,
    id: &str,
    camera: Arc<dyn crate::device_manager::rig::camera::Camera>,
) {
    let info = DeviceInfo {
        id: id.to_string(),
        name: "Probe camera".to_string(),
        device_type: DeviceType::Camera,
        driver_type: crate::device::DriverType::Alpaca,
        description: "probe".to_string(),
        driver_version: "0".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "Probe camera".to_string(),
    };
    manager.handles.insert(
        id,
        crate::device_manager::handle::DeviceHandle::Camera(camera),
    );
    manager.devices.write().await.insert(
        id.to_string(),
        ManagedDevice {
            info,
            connection_state: ConnectionState::Connected,
            last_error: None,
            reconnect_attempts: 0,
            auto_reconnect: false,
            last_successful_comm: None,
            heartbeat_deferred_at: None,
            heartbeat_active: false,
            desired_cooler: None,
            held_camera_state: None,
            desired_tracking: None,
            declared_mount_frame: None,
        },
    );
}

/// A probe already inside the health check when a download takes the guard
/// must not count. The next probe, after the download, counts as one failure.
#[tokio::test]
async fn overlapped_health_check_does_not_count_until_the_download_ends() {
    let (entered_tx, entered_rx) = tokio::sync::oneshot::channel();
    let (release_tx, release_rx) = tokio::sync::oneshot::channel();
    let camera = Arc::new(GatedProbe {
        aborts: crate::device_manager::rig::camera::ExposureAborts::new(),
        entered: std::sync::Mutex::new(Some(entered_tx)),
        release: std::sync::Mutex::new(Some(release_rx)),
        probes: std::sync::atomic::AtomicU32::new(0),
    });
    let manager = Arc::new(build_device_manager());
    let id = "alpaca:probe:camera:0";
    insert_camera(&manager, id, camera).await;
    let mut rx = manager.app_state.event_bus.subscribe();
    let loop_manager = manager.clone();
    let loop_id = id.to_string();
    let task = tokio::spawn(async move {
        DeviceManager::run_heartbeat_loop(
            loop_id,
            DeviceType::Camera,
            "Camera".to_string(),
            crate::device::DriverType::Alpaca,
            HeartbeatConfig {
                base_interval_secs: 1,
                max_interval_secs: 1,
                failure_threshold: 1,
                backoff_multiplier: 1.0,
                auto_reconnect: false,
                escalate_to_disconnect: true,
            },
            loop_manager.app_state.clone(),
            loop_manager,
        )
        .await;
    });

    tokio::time::timeout(std::time::Duration::from_secs(5), entered_rx)
        .await
        .expect("probe started")
        .expect("probe channel");
    let guard = manager.begin_operation(id);
    release_tx.send(()).expect("release probe");
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert!(
        disconnect_failure_counts(&mut rx, id).is_empty(),
        "a probe that overlapped the download must not disconnect"
    );
    drop(guard);
    let counts = tokio::time::timeout(std::time::Duration::from_secs(4), async {
        loop {
            let counts = disconnect_failure_counts(&mut rx, id);
            if !counts.is_empty() {
                return counts;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("later probe");
    assert_eq!(counts, vec![1]);
    task.abort();
}

/// An Alpaca imagearray that does not complete holds the operation guard,
/// including after the transfer fails or the download is cancelled.
#[tokio::test]
async fn alpaca_imagearray_holds_the_operation_guard() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base_url = format!("http://{}", listener.local_addr().unwrap());
    let (started_tx, started_rx) = tokio::sync::oneshot::channel();
    let (release_tx, release_rx) = tokio::sync::oneshot::channel();
    let seen = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    let seen_server = seen.clone();
    tokio::spawn(async move {
        let mut started_tx = Some(started_tx);
        let mut release_rx = Some(release_rx);
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                break;
            };
            let mut request = vec![0; 8192];
            let Ok(n) = socket.read(&mut request).await else {
                break;
            };
            let request = String::from_utf8_lossy(&request[..n]);
            let first = request.lines().next().unwrap_or("").to_string();
            seen_server.lock().expect("seen").push(first);
            let image = request.contains("imagearray");
            if image {
                if let Some(started) = started_tx.take() {
                    let _ = started.send(());
                }
                if let Some(release) = release_rx.take() {
                    let _ = release.await;
                }
            }
            // NumX and NumY are read before the pixels. An integer Value
            // answers them; imagearray then hangs until the test releases it.
            let body = if image {
                "download failed"
            } else {
                r#"{"Value":8,"ClientTransactionID":1,"ServerTransactionID":1,"ErrorNumber":0,"ErrorMessage":""}"#
            };
            let status = if image { "500 Internal Server Error" } else { "200 OK" };
            let response = format!(
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = socket.write_all(response.as_bytes()).await;
        }
    });

    let manager = Arc::new(build_device_manager());
    let id = format!("alpaca:{base_url}:camera:0");
    let driver = skotiq_alpaca::AlpacaCameraDriver::new(skotiq_alpaca::AlpacaCamera::from_server(
        &base_url, 0,
    ));
    let camera = Arc::new(crate::device_manager::rig::camera::driver::DriverCamera::alpaca(
        &id, driver,
    ));
    insert_camera(&manager, &id, camera).await;

    let download_manager = manager.clone();
    let download_id = id.clone();
    let download =
        tokio::spawn(async move { download_manager.camera_download_image(&download_id).await });
    let started = tokio::time::timeout(std::time::Duration::from_secs(5), started_rx).await;
    assert!(
        started.is_ok(),
        "imagearray was not requested; saw {:?}",
        seen.lock().expect("seen")
    );
    started.expect("imagearray started").expect("started channel");
    assert!(manager.is_operation_active(&id));
    release_tx.send(()).expect("finish imagearray");
    let result = tokio::time::timeout(std::time::Duration::from_secs(5), download)
        .await
        .expect("download finished")
        .expect("join");
    assert!(result.is_err());
    assert!(!manager.is_operation_active(&id));
}
