//! The focuser, filter wheel and rotator over Alpaca, against the ASCOM
//! Initiative's own device simulators (OmniSim, ASCOM.Alpaca.Simulators).
//!
//! OmniSim is an independent implementation of the ASCOM interfaces, so these
//! tests check Skotiq's reading of each member against a device that follows
//! the standard, not against Skotiq's own fakes. They need a running OmniSim
//! and are ignored by default:
//!
//! ```text
//! SKOTIQ_OMNISIM_URL=http://127.0.0.1:32341 \
//!   cargo test --release -p skotiq_bridge --lib omnisim -- --ignored --test-threads=1
//! ```
//!
//! Each test sets the simulator up through OmniSim's own settings API
//! (`/simulator/v1/...`) before it connects, so the order they run in does not
//! matter.

use super::*;
use crate::device::DriverType;
use crate::dispatch::error::DeviceOpError;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn omnisim() -> Option<String> {
    std::env::var("SKOTIQ_OMNISIM_URL")
        .ok()
        .map(|url| url.trim_end_matches('/').to_string())
}

/// The tests share one simulator.
fn omnisim_lock() -> &'static tokio::sync::Mutex<()> {
    static LOCK: std::sync::OnceLock<tokio::sync::Mutex<()>> = std::sync::OnceLock::new();
    LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

/// One HTTP/1.1 request to OmniSim, answered as JSON.
async fn http(base: &str, method: &str, path: &str, form: &str) -> serde_json::Value {
    let authority = base.trim_start_matches("http://");
    let mut socket = tokio::net::TcpStream::connect(authority)
        .await
        .expect("OmniSim answers on SKOTIQ_OMNISIM_URL");
    let request = if form.is_empty() {
        format!("{method} {path} HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\n\r\n")
    } else {
        format!(
            "{method} {path} HTTP/1.1\r\nHost: {authority}\r\n\
             Content-Type: application/x-www-form-urlencoded\r\n\
             Content-Length: {}\r\nConnection: close\r\n\r\n{form}",
            form.len()
        )
    };
    socket.write_all(request.as_bytes()).await.expect("send");
    let mut reply = Vec::new();
    socket.read_to_end(&mut reply).await.expect("read");
    let reply = String::from_utf8_lossy(&reply);
    let body = reply.split("\r\n\r\n").nth(1).unwrap_or_default();
    // The JSON object, whether or not the reply is chunked.
    let json = match (body.find('{'), body.rfind('}')) {
        (Some(start), Some(end)) => &body[start..=end],
        _ => body,
    };
    serde_json::from_str(json).unwrap_or_else(|e| panic!("{method} {path}: {e}: {reply}"))
}

/// An OmniSim setting, e.g. `simulate(&base, "focuser", "absolute", "Absolute=false")`.
async fn simulate(base: &str, device: &str, setting: &str, form: &str) {
    let reply = http(base, "PUT", &format!("/simulator/v1/{device}/0/{setting}"), form).await;
    assert_eq!(reply["ErrorNumber"], 0, "{device} {setting}: {reply}");
}

async fn simulated(base: &str, device: &str, setting: &str) -> serde_json::Value {
    http(base, "GET", &format!("/simulator/v1/{device}/0/{setting}"), "").await["Value"].clone()
}

/// What another client sees of `member`, straight from the device.
async fn alpaca_get(base: &str, device: &str, member: &str) -> serde_json::Value {
    let reply = http(
        base,
        "GET",
        &format!("/api/v1/{device}/0/{member}?ClientID=4242&ClientTransactionID=1"),
        "",
    )
    .await;
    assert_eq!(reply["ErrorNumber"], 0, "{device} {member}: {reply}");
    reply["Value"].clone()
}

async fn alpaca_put(base: &str, device: &str, member: &str, form: &str) {
    let reply = http(
        base,
        "PUT",
        &format!("/api/v1/{device}/0/{member}"),
        &format!("ClientID=4242&ClientTransactionID=1&{form}"),
    )
    .await;
    assert_eq!(reply["ErrorNumber"], 0, "{device} {member}: {reply}");
}

/// Registers and connects OmniSim's device 0 of `device_type`.
async fn connect(manager: &DeviceManager, base: &str, device_type: DeviceType) -> String {
    let path = match device_type {
        DeviceType::Focuser => "focuser",
        DeviceType::FilterWheel => "filterwheel",
        DeviceType::Rotator => "rotator",
        other => panic!("not one of the OmniSim devices tested here: {other:?}"),
    };
    let id = format!("alpaca:{base}:{path}:0");
    manager
        .register_device(
            DeviceInfo {
                id: id.clone(),
                name: format!("OmniSim {path}"),
                device_type,
                driver_type: DriverType::Alpaca,
                description: String::new(),
                driver_version: String::new(),
                serial_number: None,
                unique_id: None,
                display_name: format!("OmniSim {path}"),
            },
            false,
        )
        .await;
    manager.connect_device(&id).await.expect("connect");
    id
}

async fn wait_until<F, Fut>(what: &str, limit: Duration, mut done: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let start = Instant::now();
    while !done().await {
        assert!(start.elapsed() < limit, "{what} within {limit:?}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

async fn focuser_at_rest(manager: &DeviceManager, id: &str) {
    wait_until("focuser at rest", Duration::from_secs(60), || async {
        !manager.focuser_is_moving(id).await.expect("IsMoving")
    })
    .await;
}

#[tokio::test]
#[ignore = "needs OmniSim: set SKOTIQ_OMNISIM_URL"]
async fn an_absolute_focuser_moves_to_positions_and_reports_its_properties() {
    let Some(base) = omnisim() else { return };
    let _guard = omnisim_lock().lock().await;
    simulate(&base, "focuser", "absolute", "Absolute=true").await;
    let manager = build_device_manager();
    let id = connect(&manager, &base, DeviceType::Focuser).await;
    focuser_at_rest(&manager, &id).await;

    assert!(manager.focuser_is_absolute(&id).await.expect("Absolute"));
    let (max_step, step_size) = manager.focuser_get_details(&id).await.expect("travel");
    assert_eq!(i64::from(max_step), alpaca_get(&base, "focuser", "maxstep").await);
    assert_eq!(step_size, alpaca_get(&base, "focuser", "stepsize").await);

    let start = manager.focuser_get_position(&id).await.expect("Position");
    let target = if start > max_step / 2 { start - 400 } else { start + 400 };
    manager.focuser_move_abs(&id, target).await.expect("Move");
    focuser_at_rest(&manager, &id).await;
    assert_eq!(manager.focuser_get_position(&id).await.unwrap(), target);
    assert_eq!(alpaca_get(&base, "focuser", "position").await, target);

    manager.focuser_move_rel(&id, -120).await.expect("relative move");
    focuser_at_rest(&manager, &id).await;
    assert_eq!(manager.focuser_get_position(&id).await.unwrap(), target - 120);

    // 4000 steps take OmniSim 10 s; Halt stops it where it is.
    let far = if target > max_step / 2 { target - 4000 } else { target + 4000 };
    manager.focuser_move_abs(&id, far).await.expect("Move");
    tokio::time::sleep(Duration::from_millis(500)).await;
    manager.focuser_halt(&id).await.expect("Halt");
    focuser_at_rest(&manager, &id).await;
    let stopped = manager.focuser_get_position(&id).await.unwrap();
    assert_ne!(stopped, far, "the halt stopped the move short of its target");

    let temperature = manager.focuser_get_temp(&id).await.expect("Temperature");
    assert_eq!(
        temperature,
        alpaca_get(&base, "focuser", "temperature").await.as_f64()
    );

    let caps = manager.focuser(&id).await.unwrap().capabilities(&id).await.unwrap();
    assert!(caps.absolute);
    assert_eq!(i64::from(caps.max_position), alpaca_get(&base, "focuser", "maxstep").await);
    assert_eq!(
        i64::from(caps.max_increment),
        alpaca_get(&base, "focuser", "maxincrement").await
    );
    assert_eq!(caps.step_size, Some(step_size));
    assert_eq!(
        caps.temp_comp_available,
        alpaca_get(&base, "focuser", "tempcompavailable").await
    );
    assert_eq!(caps.position, Some(stopped));

    manager.disconnect_device(&id).await.expect("disconnect");
}

/// A relative focuser (`Absolute` false) has no `Position`; `Move` takes a
/// number of steps. Skotiq counts positions itself from the middle of the
/// travel at connect, as NINA does, so autofocus and the position display
/// work the same as on an absolute focuser.
#[tokio::test]
#[ignore = "needs OmniSim: set SKOTIQ_OMNISIM_URL"]
async fn a_relative_focuser_is_moved_by_steps_and_has_a_counted_position() {
    let Some(base) = omnisim() else { return };
    let _guard = omnisim_lock().lock().await;
    simulate(&base, "focuser", "absolute", "Absolute=false").await;
    let manager = build_device_manager();
    let id = connect(&manager, &base, DeviceType::Focuser).await;
    focuser_at_rest(&manager, &id).await;

    assert!(!manager.focuser_is_absolute(&id).await.expect("Absolute"));
    let start = manager
        .focuser_get_position(&id)
        .await
        .expect("a relative focuser still has a position to show");
    let (max_step, _) = manager.focuser_get_details(&id).await.unwrap();
    assert_eq!(start, max_step / 2);

    manager.focuser_move_abs(&id, start + 300).await.expect("Move");
    // OmniSim's relative focuser holds the commanded step count in its
    // position setting and counts it down to 0 as it moves.
    let commanded = simulated(&base, "focuser", "position").await.as_i64().unwrap();
    assert!(
        (0..=300).contains(&commanded),
        "Move was sent the 300 steps, not the position: {commanded}"
    );
    focuser_at_rest(&manager, &id).await;
    assert_eq!(manager.focuser_get_position(&id).await.unwrap(), start + 300);

    manager.focuser_move_rel(&id, -50).await.expect("relative move");
    let commanded = simulated(&base, "focuser", "position").await.as_i64().unwrap();
    assert!((-50..=0).contains(&commanded), "{commanded}");
    focuser_at_rest(&manager, &id).await;
    assert_eq!(manager.focuser_get_position(&id).await.unwrap(), start + 250);

    let caps = manager.focuser(&id).await.unwrap().capabilities(&id).await.unwrap();
    assert!(!caps.absolute);
    assert_eq!(caps.position, Some(start + 250));

    manager.disconnect_device(&id).await.expect("disconnect");
    simulate(&base, "focuser", "absolute", "Absolute=true").await;
}

/// `Position` set starts the move and returns; `Position` reads -1 until the
/// wheel is there. A filter change ends when the wheel has arrived, so the
/// exposure that follows is taken through the filter it asked for.
#[tokio::test]
#[ignore = "needs OmniSim: set SKOTIQ_OMNISIM_URL"]
async fn a_filter_change_ends_when_the_wheel_is_at_the_slot() {
    let Some(base) = omnisim() else { return };
    let _guard = omnisim_lock().lock().await;
    simulate(&base, "filterwheel", "filterchangetimeinterval", "FilterChangeTimeInterval=400").await;
    let manager = build_device_manager();
    let id = connect(&manager, &base, DeviceType::FilterWheel).await;
    wait_until("wheel at rest", Duration::from_secs(30), || async {
        manager.filter_wheel_get_position(&id).await.unwrap_or(-1) >= 0
    })
    .await;

    let (count, names) = manager.filter_wheel_get_config(&id).await.expect("Names");
    let wire_names = alpaca_get(&base, "filterwheel", "names").await;
    assert_eq!(serde_json::Value::from(names.clone()), wire_names);
    assert_eq!(count as usize, names.len());

    let from = manager.filter_wheel_get_position(&id).await.unwrap();
    let to = (from + 3) % count;
    let started = Instant::now();
    manager
        .filter_wheel_set_position(&id, to)
        .await
        .expect("filter change");
    assert!(
        started.elapsed() >= Duration::from_millis(400),
        "returned after {:?}, before the wheel could have turned",
        started.elapsed()
    );
    assert_eq!(alpaca_get(&base, "filterwheel", "position").await, to);
    assert!(!manager.filter_wheel_is_moving(&id).await.unwrap());

    let error = manager
        .filter_wheel_set_position(&id, count + 2)
        .await
        .expect_err("there is no such slot");
    assert!(
        matches!(error, DeviceOpError::InvalidParameter { .. }),
        "{error:?}"
    );

    let caps = manager.filter_wheel(&id).await.unwrap().capabilities(&id).await.unwrap();
    assert_eq!(caps.position_count, count);
    assert_eq!(caps.current_position, Some(to));
    assert_eq!(
        serde_json::Value::from(caps.focus_offsets),
        alpaca_get(&base, "filterwheel", "focusoffsets").await
    );

    manager.disconnect_device(&id).await.expect("disconnect");
}

/// `Position` is the sky angle (after `Sync`), `MechanicalPosition` the
/// mechanism's own; a move ends when `IsMoving` is false.
#[tokio::test]
#[ignore = "needs OmniSim: set SKOTIQ_OMNISIM_URL"]
async fn a_rotator_move_ends_at_the_angle_and_a_sync_moves_only_the_sky_angle() {
    let Some(base) = omnisim() else { return };
    let _guard = omnisim_lock().lock().await;
    simulate(&base, "rotator", "rotationrate", "RotationRate=60").await;
    simulate(&base, "rotator", "interfaceversion", "InterfaceVersion=4").await;
    let manager = build_device_manager();
    let id = connect(&manager, &base, DeviceType::Rotator).await;
    let rotator = manager.rotator(&id).await.unwrap();
    wait_until("rotator at rest", Duration::from_secs(30), || async {
        !rotator.is_moving().await.unwrap()
    })
    .await;

    let start = rotator.position().await.unwrap();
    let target = (start + 45.0) % 360.0;
    manager.rotator_move_absolute(&id, target).await.expect("MoveAbsolute");
    assert!(
        !rotator.is_moving().await.unwrap(),
        "the move returned while the rotator was still turning"
    );
    assert!((rotator.position().await.unwrap() - target).abs() < 0.5);

    let mechanical = rotator.mechanical_position().await.unwrap();
    manager.rotator_sync(&id, 200.0).await.expect("Sync");
    assert!((rotator.position().await.unwrap() - 200.0).abs() < 0.01);
    assert!(
        (rotator.mechanical_position().await.unwrap() - mechanical).abs() < 0.01,
        "a sync does not move the mechanism"
    );
    assert_eq!(
        Some(rotator.mechanical_position().await.unwrap()),
        alpaca_get(&base, "rotator", "mechanicalposition").await.as_f64()
    );

    let caps = rotator.capabilities(&id).await.unwrap();
    assert_eq!(caps.can_reverse, alpaca_get(&base, "rotator", "canreverse").await);
    assert_eq!(
        caps.step_size,
        alpaca_get(&base, "rotator", "stepsize").await.as_f64()
    );
    assert!(caps.can_sync);
    manager.rotator_set_reverse(&id, true).await.expect("Reverse");
    assert_eq!(alpaca_get(&base, "rotator", "reverse").await, true);
    let caps = rotator.capabilities(&id).await.unwrap();
    assert!(caps.reverse);
    manager.rotator_set_reverse(&id, false).await.expect("Reverse");
    manager.disconnect_device(&id).await.expect("disconnect");

    // Sync arrived with IRotatorV3.
    simulate(&base, "rotator", "interfaceversion", "InterfaceVersion=2").await;
    let id = connect(&manager, &base, DeviceType::Rotator).await;
    let caps = manager.rotator(&id).await.unwrap().capabilities(&id).await.unwrap();
    assert!(!caps.can_sync, "an IRotatorV2 has no Sync");
    manager.disconnect_device(&id).await.expect("disconnect");
    simulate(&base, "rotator", "interfaceversion", "InterfaceVersion=4").await;
}

/// The heartbeat reads `Connected`: a device the server reports as not
/// connected (another client closed it, the driver lost the hardware) is not
/// alive.
#[tokio::test]
#[ignore = "needs OmniSim: set SKOTIQ_OMNISIM_URL"]
async fn a_device_the_server_reports_disconnected_fails_its_heartbeat() {
    let Some(base) = omnisim() else { return };
    let _guard = omnisim_lock().lock().await;
    simulate(&base, "focuser", "absolute", "Absolute=true").await;
    let manager = build_device_manager();
    for (device_type, path) in [
        (DeviceType::Focuser, "focuser"),
        (DeviceType::FilterWheel, "filterwheel"),
        (DeviceType::Rotator, "rotator"),
    ] {
        let id = connect(&manager, &base, device_type).await;
        let handle = manager.handles.get(&id).expect("a handle");
        assert_eq!(handle.heartbeat(&id).await, Ok(true), "{path}");
        alpaca_put(&base, path, "connected", "Connected=false").await;
        assert_eq!(handle.heartbeat(&id).await, Ok(false), "{path}");
        let _ = manager.disconnect_device(&id).await;
    }
}
