//! The dome, switch, cover calibrator, safety monitor and weather station
//! clients driven against the ASCOM Alpaca simulators (OmniSim), through the
//! driver traits the app uses and through the raw members.
//!
//! Ignored by default: it needs a running OmniSim. Point
//! `SKOTIQ_OMNISIM_URL` at it (`http://127.0.0.1:32350`) and run
//! `cargo test -p skotiq_alpaca --test omnisim_observatory -- --ignored --test-threads=1`.
//! The tests change the simulators' settings through OmniSim's own
//! `simulator/v1` API and put them back.

use skotiq_alpaca::{
    AlpacaCoverCalibrator, AlpacaDome, AlpacaObservingConditions, AlpacaSafetyMonitor,
    AlpacaSwitch,
};
use skotiq_device::ascom::cover_calibrator::Settle;
use skotiq_device::ascom::{CalibratorStatus, CoverStatus, ShutterStatus};
use skotiq_device::{
    AccessoryDriver, CoverCalibratorDriver, DomeDriver, DriverError, SafetyMonitorDriver,
    SwitchDriver, WeatherDriver,
};
use std::future::Future;
use std::time::{Duration, Instant};

fn omnisim() -> String {
    std::env::var("SKOTIQ_OMNISIM_URL").expect("SKOTIQ_OMNISIM_URL names the running OmniSim")
}

/// Changes one simulator setting (`simulator/v1/<device>/0/<setting>`).
async fn simulator_setting(device: &str, setting: &str, field: &str, value: &str) {
    let url = format!("{}/simulator/v1/{device}/0/{setting}", omnisim());
    let reply: serde_json::Value = reqwest::Client::new()
        .put(&url)
        .form(&[(field, value)])
        .send()
        .await
        .expect("OmniSim settings API answers")
        .json()
        .await
        .expect("OmniSim settings reply is JSON");
    assert_eq!(reply["ErrorNumber"], 0, "{url} {field}={value}: {reply}");
}

/// Polls `check` every 200 ms until it answers `Some`, or panics after
/// `limit`.
async fn until<T, F, Fut>(what: &str, limit: Duration, mut check: F) -> T
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Option<T>>,
{
    let started = Instant::now();
    loop {
        if let Some(value) = check().await {
            return value;
        }
        assert!(started.elapsed() < limit, "{what} did not happen within {limit:?}");
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

#[tokio::test]
#[ignore = "needs a running OmniSim at SKOTIQ_OMNISIM_URL"]
async fn dome_through_the_driver_trait() {
    let dome = AlpacaDome::from_server(&omnisim(), 0);
    dome.connect().await.expect("connect");
    assert_eq!(dome.interface_version().await.unwrap(), 3);
    AccessoryDriver::heartbeat(&dome).await.expect("heartbeat");

    let state = DomeDriver::status(&dome).await.expect("status");
    assert!(state.can_set_azimuth && state.can_set_shutter && state.can_set_altitude);
    assert!(!state.can_slave && !state.slaved);

    DomeDriver::open_shutter(&dome).await.expect("open shutter");
    until("shutter open", Duration::from_secs(60), || async {
        let status = DomeDriver::shutter_status(&dome).await.unwrap();
        (status == ShutterStatus::Open).then_some(())
    })
    .await;

    // 370 degrees goes out as 10.
    DomeDriver::slew_to_azimuth(&dome, 370.0).await.expect("slew");
    until("slew over", Duration::from_secs(120), || async {
        (!DomeDriver::status(&dome).await.unwrap().slewing).then_some(())
    })
    .await;
    let azimuth = DomeDriver::status(&dome).await.unwrap().azimuth;
    assert!((azimuth - 10.0).abs() < 1.0, "azimuth after slew to 370: {azimuth}");

    DomeDriver::slew_to_azimuth(&dome, 200.0).await.expect("slew");
    DomeDriver::abort_slew(&dome).await.expect("abort");
    until("abort stops the dome", Duration::from_secs(10), || async {
        (!DomeDriver::status(&dome).await.unwrap().slewing).then_some(())
    })
    .await;

    DomeDriver::find_home(&dome).await.expect("find home");
    until("home", Duration::from_secs(120), || async {
        let state = DomeDriver::status(&dome).await.unwrap();
        (!state.slewing && state.at_home).then_some(())
    })
    .await;

    // Slaving a dome that cannot be slaved is refused, in the driver's words.
    let refused = DomeDriver::set_slaved(&dome, true).await.unwrap_err();
    assert!(matches!(refused, DriverError::NotSupported), "{refused}");

    DomeDriver::close_shutter(&dome).await.expect("close shutter");
    DomeDriver::park(&dome).await.expect("park");
    until("parked and closed", Duration::from_secs(120), || async {
        let state = DomeDriver::status(&dome).await.unwrap();
        (!state.slewing && state.at_park && state.shutter == Some(ShutterStatus::Closed))
            .then_some(())
    })
    .await;

    // A roll-off roof: no azimuth, altitude or home. Its status still reads.
    simulator_setting("dome", "cansetazimuth", "CanSetAzimuth", "false").await;
    simulator_setting("dome", "cansetaltitude", "CanSetAltitude", "false").await;
    simulator_setting("dome", "canfindhome", "CanFindHome", "false").await;
    let roof = skotiq_device::ascom::dome::report(&dome).await;
    simulator_setting("dome", "cansetazimuth", "CanSetAzimuth", "true").await;
    simulator_setting("dome", "cansetaltitude", "CanSetAltitude", "true").await;
    simulator_setting("dome", "canfindhome", "CanFindHome", "true").await;
    let roof = roof.expect("a roll-off roof's status reads");
    assert_eq!(roof.azimuth, None);
    assert_eq!(roof.state.altitude, None);
    assert!(!roof.state.can_set_azimuth && !roof.can_find_home && roof.can_park);
    assert_eq!(roof.state.shutter, Some(ShutterStatus::Closed));

    AccessoryDriver::disconnect(&dome).await.expect("disconnect");
    assert!(matches!(
        AccessoryDriver::heartbeat(&dome).await,
        Err(DriverError::NotConnected)
    ));
}

#[tokio::test]
#[ignore = "needs a running OmniSim at SKOTIQ_OMNISIM_URL"]
async fn switch_through_the_driver_trait() {
    let switch = AlpacaSwitch::from_server(&omnisim(), 0);
    switch.connect().await.expect("connect");
    assert_eq!(switch.interface_version().await.unwrap(), 3);
    let count = SwitchDriver::count(&switch).await.unwrap();
    assert!(count >= 8, "OmniSim has {count} switches");

    // Channel 2 ("Light Box") runs 0..100 in steps of 10.
    assert_eq!(SwitchDriver::min_value(&switch, 2).await.unwrap(), 0.0);
    assert_eq!(SwitchDriver::max_value(&switch, 2).await.unwrap(), 100.0);
    assert_eq!(SwitchDriver::step(&switch, 2).await.unwrap(), 10.0);
    assert!(SwitchDriver::can_write(&switch, 2).await.unwrap());
    SwitchDriver::set_value(&switch, 2, 30.0).await.expect("set value");
    assert_eq!(SwitchDriver::value(&switch, 2).await.unwrap(), 30.0);
    // A value off the switch's steps is refused by the switch itself; the
    // app snaps a value to the step before it writes.
    let off_step = SwitchDriver::set_value(&switch, 2, 33.0).await;
    let out_of_range = SwitchDriver::set_value(&switch, 2, 130.0).await.unwrap_err();
    assert!(matches!(out_of_range, DriverError::InvalidParameter(_)), "{out_of_range}");
    SwitchDriver::set_value(&switch, 2, 0.0).await.unwrap();
    eprintln!("OmniSim on an off-step value: {off_step:?}");

    // Channel 0 is a boolean switch.
    SwitchDriver::set_state(&switch, 0, true).await.expect("set state");
    assert!(SwitchDriver::state(&switch, 0).await.unwrap());
    SwitchDriver::set_state(&switch, 0, false).await.unwrap();
    // A read-only channel refuses a write.
    assert!(!SwitchDriver::can_write(&switch, 4).await.unwrap());
    assert!(SwitchDriver::set_state(&switch, 4, true).await.is_err());

    // ISwitchV3 asynchronous members.
    assert!(switch.can_async(0).await.unwrap());
    assert!(!switch.can_async(1).await.unwrap());
    switch.set_async(0, true).await.expect("set async");
    until("asynchronous switch change", Duration::from_secs(30), || async {
        switch.state_change_complete(0).await.unwrap().then_some(())
    })
    .await;
    assert!(switch.get_switch(0).await.unwrap());
    switch.set_async_value(0, 0.0).await.expect("set async value");
    switch.cancel_async(0).await.expect("cancel async");
    // After CancelAsync, StateChangeComplete raises OperationCancelled
    // (ISwitchV3), unless the change had already finished.
    match switch.state_change_complete(0).await {
        Ok(_) => {}
        Err(cancelled) => assert!(
            cancelled.to_string().contains("cancelled"),
            "{cancelled}"
        ),
    }

    AccessoryDriver::disconnect(&switch).await.unwrap();
    assert!(matches!(
        AccessoryDriver::heartbeat(&switch).await,
        Err(DriverError::NotConnected)
    ));
}

#[tokio::test]
#[ignore = "needs a running OmniSim at SKOTIQ_OMNISIM_URL"]
async fn cover_calibrator_through_the_driver_trait() {
    let device = AlpacaCoverCalibrator::from_server(&omnisim(), 0);
    device.connect().await.expect("connect");
    assert_eq!(device.interface_version().await.unwrap(), 2);
    let state = CoverCalibratorDriver::status(&device).await.expect("status");
    assert!(state.max_brightness > 0);

    for (open, target) in [(true, CoverStatus::Open), (false, CoverStatus::Closed)] {
        if open {
            CoverCalibratorDriver::open_cover(&device).await.unwrap();
        } else {
            CoverCalibratorDriver::close_cover(&device).await.unwrap();
        }
        until("cover move", Duration::from_secs(60), || async {
            let reported = CoverCalibratorDriver::cover_status(&device).await.unwrap();
            let moving = device.cover_moving().await.unwrap();
            // CoverMoving and CoverState agree on when the move is over.
            assert_eq!(moving, reported == CoverStatus::Moving, "{reported}");
            match Settle::cover(reported, target) {
                Settle::Done => Some(()),
                Settle::Failed => panic!("cover error"),
                Settle::Waiting => None,
            }
        })
        .await;
    }

    let brightness = state.max_brightness / 2;
    CoverCalibratorDriver::calibrator_on(&device, brightness).await.unwrap();
    until("calibrator ready", Duration::from_secs(60), || async {
        let reported = CoverCalibratorDriver::calibrator_status(&device).await.unwrap();
        let changing = device.calibrator_changing().await.unwrap();
        assert_eq!(changing, reported == CalibratorStatus::NotReady, "{reported}");
        (Settle::calibrator(reported, CalibratorStatus::Ready) == Settle::Done).then_some(())
    })
    .await;
    assert_eq!(CoverCalibratorDriver::brightness(&device).await.unwrap(), brightness);
    let too_bright = CoverCalibratorDriver::calibrator_on(&device, state.max_brightness + 1)
        .await
        .unwrap_err();
    assert!(matches!(too_bright, DriverError::InvalidParameter(_)), "{too_bright}");
    CoverCalibratorDriver::calibrator_off(&device).await.unwrap();
    until("calibrator off", Duration::from_secs(60), || async {
        let reported = CoverCalibratorDriver::calibrator_status(&device).await.unwrap();
        (Settle::calibrator(reported, CalibratorStatus::Off) == Settle::Done).then_some(())
    })
    .await;
    assert_eq!(CoverCalibratorDriver::status(&device).await.unwrap().brightness, 0);

    AccessoryDriver::disconnect(&device).await.unwrap();
    assert!(matches!(
        AccessoryDriver::heartbeat(&device).await,
        Err(DriverError::NotConnected)
    ));
}

#[tokio::test]
#[ignore = "needs a running OmniSim at SKOTIQ_OMNISIM_URL"]
async fn safety_monitor_through_the_driver_trait() {
    let monitor = AlpacaSafetyMonitor::from_server(&omnisim(), 0);
    monitor.connect().await.expect("connect");
    assert_eq!(monitor.interface_version().await.unwrap(), 3);
    assert!(SafetyMonitorDriver::is_safe(&monitor).await.unwrap());
    simulator_setting("safetymonitor", "issafesetting", "IsSafeSetting", "false").await;
    let unsafe_now = SafetyMonitorDriver::is_safe(&monitor).await;
    simulator_setting("safetymonitor", "issafesetting", "IsSafeSetting", "true").await;
    assert!(!unsafe_now.unwrap());

    AccessoryDriver::disconnect(&monitor).await.unwrap();
    // A disconnected monitor fails the heartbeat instead of passing it.
    assert!(matches!(
        AccessoryDriver::heartbeat(&monitor).await,
        Err(DriverError::NotConnected)
    ));
    // ... and IsSafe is an error, not a verdict.
    let not_connected = SafetyMonitorDriver::is_safe(&monitor).await;
    assert!(
        matches!(not_connected, Err(DriverError::NotConnected)),
        "{not_connected:?}"
    );
}

#[tokio::test]
#[ignore = "needs a running OmniSim at SKOTIQ_OMNISIM_URL"]
async fn weather_station_through_the_driver_trait() {
    let station = AlpacaObservingConditions::from_server(&omnisim(), 0);
    station.connect().await.expect("connect");
    assert_eq!(station.interface_version().await.unwrap(), 2);
    let readings = WeatherDriver::readings(&station).await.expect("readings");
    for (name, value) in [
        ("temperature", readings.temperature),
        ("humidity", readings.humidity),
        ("pressure", readings.pressure),
        ("dew_point", readings.dew_point),
        ("cloud_cover", readings.cloud_cover),
        ("sky_quality", readings.sky_quality),
        ("sky_temperature", readings.sky_temperature),
        ("wind_speed", readings.wind_speed),
        ("wind_direction", readings.wind_direction),
        ("rain_rate", readings.rain_rate),
    ] {
        assert!(value.is_some(), "OmniSim reports every sensor; {name} missing");
    }
    assert!(station.average_period().await.unwrap() >= 0.0);
    assert!(!station.sensor_description("Temperature").await.unwrap().is_empty());
    assert!(station.time_since_last_update("Temperature").await.unwrap() >= 0.0);
    assert!(station.time_since_last_update("").await.unwrap() >= 0.0);
    station.refresh().await.ok();

    AccessoryDriver::disconnect(&station).await.unwrap();
    // A disconnected station is not a station without sensors.
    let not_connected = WeatherDriver::readings(&station).await;
    assert!(
        matches!(not_connected, Err(DriverError::NotConnected)),
        "{not_connected:?}"
    );
}
