//! Camera, mount, focuser and filter-wheel basics against a real INDI server
//! running the INDI simulators.
//!
//! Ignored by default. Start the server on a loopback-only network, then run:
//!
//! ```sh
//! indiserver -p 7790 indi_simulator_ccd indi_simulator_telescope \
//!     indi_simulator_focus indi_simulator_wheel
//! SKOTIQ_INDI_SIM_PORT=7790 cargo test -p skotiq_indi --test simulator_server \
//!     -- --ignored --nocapture
//! ```

use skotiq_indi::{IndiCamera, IndiClient, IndiFilterWheel, IndiFocuser, IndiMount};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

const CAMERA: &str = "CCD Simulator";
const MOUNT: &str = "Telescope Simulator";
const FOCUSER: &str = "Focuser Simulator";
const WHEEL: &str = "Filter Simulator";

async fn server() -> Arc<RwLock<IndiClient>> {
    let port: u16 = std::env::var("SKOTIQ_INDI_SIM_PORT")
        .expect("SKOTIQ_INDI_SIM_PORT names the simulator server's port")
        .parse()
        .expect("a port number");
    let mut client = IndiClient::new("127.0.0.1", Some(port));
    client
        .connect()
        .await
        .expect("connect to the simulator server");
    let client = Arc::new(RwLock::new(client));
    for device in [CAMERA, MOUNT, FOCUSER, WHEEL] {
        wait_for(&format!("{device} to be defined"), || {
            let client = client.clone();
            async move { client.read().await.has_property(device, "CONNECTION").await }
        })
        .await;
    }
    client
}

async fn wait_for<F, Fut>(what: &str, mut check: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !check().await {
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for {what}"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn connect(client: &Arc<RwLock<IndiClient>>, device: &str) {
    client
        .write()
        .await
        .connect_and_confirm(device)
        .await
        .expect("the driver confirms the connection");
}

async fn disconnect(client: &Arc<RwLock<IndiClient>>, device: &str) {
    client
        .write()
        .await
        .disconnect_and_confirm(device)
        .await
        .expect("the driver confirms the disconnection");
}

#[tokio::test]
#[ignore = "needs an INDI simulator server; see the module header"]
async fn simulator_basics() {
    let client = server().await;

    connect(&client, CAMERA).await;
    let camera = IndiCamera::new(client.clone(), CAMERA);
    camera.enable_blob().await.expect("enable BLOBs");
    wait_for("the camera's exposure property", || {
        let client = client.clone();
        async move {
            client
                .read()
                .await
                .has_property(CAMERA, "CCD_EXPOSURE")
                .await
        }
    })
    .await;
    let frame = camera
        .capture_image_with_timeout(0.2, Some(Duration::from_secs(30)))
        .await
        .expect("a frame");
    assert!(frame.starts_with(b"SIMPLE"), "the frame is a FITS file");
    println!(
        "camera: {} byte frame, sensor {:?}x{:?}",
        frame.len(),
        camera.get_sensor_width().await,
        camera.get_sensor_height().await
    );

    connect(&client, MOUNT).await;
    let mount = IndiMount::new(client.clone(), MOUNT);
    wait_for("the mount's coordinates", || {
        let client = client.clone();
        async move {
            client
                .read()
                .await
                .has_property(MOUNT, "EQUATORIAL_EOD_COORD")
                .await
        }
    })
    .await;
    if mount.try_is_parked().await.unwrap_or(false) {
        mount.unpark().await.expect("unpark");
    }
    let (ra, _) = mount.get_coordinates().await.expect("coordinates");
    let target_ra = (ra + 0.5) % 24.0;
    mount
        .slew_to_coordinates(target_ra, 20.0)
        .await
        .expect("slew");
    wait_for("the slew to end", || {
        let mount = &mount;
        async move { !mount.try_is_slewing().await.expect("slewing state") }
    })
    .await;
    let (ra_after, dec_after) = mount.get_coordinates().await.expect("coordinates");
    assert!(
        (ra_after - target_ra).abs() < 0.05,
        "RA {ra_after} after a slew to {target_ra}"
    );
    assert!(
        (dec_after - 20.0).abs() < 0.5,
        "Dec {dec_after} after a slew to 20"
    );
    println!("mount: slewed to RA {ra_after:.3} h, Dec {dec_after:.2} deg");

    connect(&client, FOCUSER).await;
    let focuser = IndiFocuser::new(client.clone(), FOCUSER);
    wait_for("the focuser's position", || {
        let client = client.clone();
        async move {
            client
                .read()
                .await
                .has_property(FOCUSER, "ABS_FOCUS_POSITION")
                .await
        }
    })
    .await;
    let start = focuser.get_position().await.expect("position");
    let target = if start > 30_000 {
        start - 400
    } else {
        start + 400
    };
    focuser
        .move_to_with_timeout(target, Some(Duration::from_secs(60)))
        .await
        .expect("focuser move");
    assert_eq!(focuser.get_position().await.expect("position"), target);
    println!("focuser: moved {start} -> {target}");

    connect(&client, WHEEL).await;
    let wheel = IndiFilterWheel::new(client.clone(), WHEEL);
    wait_for("the wheel's slot", || {
        let client = client.clone();
        async move { client.read().await.has_property(WHEEL, "FILTER_SLOT").await }
    })
    .await;
    let names = wheel.get_names().await.expect("filter names");
    assert!(!names.is_empty(), "the simulator names its filters");
    let slot = if wheel.get_position().await.expect("slot") == 2 {
        1
    } else {
        2
    };
    wheel.move_to_position(slot).await.expect("wheel move");
    assert_eq!(wheel.get_position().await.expect("slot"), slot);
    println!("wheel: at slot {slot} of {names:?}");

    for device in [WHEEL, FOCUSER, MOUNT, CAMERA] {
        disconnect(&client, device).await;
    }
}

#[tokio::test]
#[ignore = "needs an INDI simulator server; see the module header"]
async fn simulator_devices_are_listed_by_kind() {
    let port: u16 = std::env::var("SKOTIQ_INDI_SIM_PORT")
        .expect("SKOTIQ_INDI_SIM_PORT names the simulator server's port")
        .parse()
        .expect("a port number");
    let start = std::time::Instant::now();
    let server = skotiq_indi::discover_server("127.0.0.1", port)
        .await
        .expect("the simulator server answers");
    println!("discovery took {:?}", start.elapsed());
    let mut listed: Vec<_> = server
        .devices
        .iter()
        .map(|device| format!("{} = {:?}", device.name, device.kind))
        .collect();
    listed.sort();
    println!("{listed:#?}");
    for (name, kind) in [
        (CAMERA, skotiq_device::DeviceKind::Camera),
        (MOUNT, skotiq_device::DeviceKind::Mount),
        (FOCUSER, skotiq_device::DeviceKind::Focuser),
        (WHEEL, skotiq_device::DeviceKind::FilterWheel),
    ] {
        assert!(
            server
                .devices
                .iter()
                .any(|d| d.name == name && d.kind == kind),
            "{name} listed as {kind:?}"
        );
    }
}
