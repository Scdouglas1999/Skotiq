//! The kind Skotiq lists each INDI device as, for what real drivers publish.
//!
//! `tests/drivers/<device>.before.xml` holds the definitions a driver sent a
//! new client before the device was connected, which is what Skotiq sees when
//! it discovers a server; `<device>.after.xml` holds them once the device was
//! connected (simulators only). They were recorded from INDI 2.2.5's
//! `indiserver` on a loopback-only network: the simulators, and drivers for
//! real hardware that were started but never sent CONNECT. A scripted server
//! replays them, so the client's own parser reads them.

use skotiq_device::DeviceKind;
use skotiq_indi::{list_devices, wait_for_definitions, IndiClient};
use std::path::PathBuf;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::RwLock;

fn fixture(name: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/drivers")
        .join(name);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// The definitions without DRIVER_INFO, as from a driver that does not
/// publish its interfaces.
fn without_driver_info(xml: &str) -> String {
    let name = xml
        .find("name=\"DRIVER_INFO\"")
        .expect("the capture has DRIVER_INFO");
    let start = xml[..name].rfind("<defTextVector").expect("vector start");
    let end = start
        + xml[start..].find("</defTextVector>").expect("vector end")
        + "</defTextVector>".len();
    format!("{}{}", &xml[..start], &xml[end..])
}

/// A client connected to a server that answers getProperties with
/// `definitions`, once they have all arrived.
async fn client_for(definitions: String) -> RwLock<IndiClient> {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("address").port();
    tokio::spawn(async move {
        let (socket, _) = listener.accept().await.expect("accept");
        let (reader, mut writer) = socket.into_split();
        let mut lines = BufReader::new(reader).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if line.contains("<getProperties") {
                let _ = writer.write_all(definitions.as_bytes()).await;
            }
        }
    });
    let mut client = IndiClient::new("127.0.0.1", Some(port));
    client.connect().await.expect("connect");
    let client = RwLock::new(client);
    wait_for_definitions(&client, Duration::from_secs(5)).await;
    client
}

async fn kind_of(definitions: String, device: &str) -> Option<DeviceKind> {
    let client = client_for(definitions).await;
    let client = client.read().await;
    assert!(
        client.has_property(device, "CONNECTION").await,
        "{device} was defined"
    );
    client.describe_device(device).await.kind()
}

/// Every captured device, by file stem and device name, with the kind it is
/// listed as from its published interfaces.
const BY_INTERFACE: [(&str, &str, Option<DeviceKind>); 23] = [
    // CCD | GUIDER | FILTER: a camera with a built-in filter wheel.
    ("ccd_simulator", "CCD Simulator", Some(DeviceKind::Camera)),
    // CCD | GUIDER.
    (
        "guide_simulator",
        "Guide Simulator",
        Some(DeviceKind::Camera),
    ),
    // TELESCOPE | GUIDER.
    (
        "telescope_simulator",
        "Telescope Simulator",
        Some(DeviceKind::Mount),
    ),
    // TELESCOPE | GUIDER | FOCUSER | WEATHER: a mount with a focuser port.
    ("lx200_onstep", "LX200 OnStep", Some(DeviceKind::Mount)),
    (
        "pegasus_nyx_101",
        "Pegasus NYX-101",
        Some(DeviceKind::Mount),
    ),
    ("zwo_am5", "ZWO AM5", Some(DeviceKind::Mount)),
    ("ioptronv3", "iOptronV3", Some(DeviceKind::Mount)),
    (
        "focuser_simulator",
        "Focuser Simulator",
        Some(DeviceKind::Focuser),
    ),
    ("moonlite", "MoonLite", Some(DeviceKind::Focuser)),
    ("myfocuserpro2", "MyFocuserPro2", Some(DeviceKind::Focuser)),
    (
        "filter_simulator",
        "Filter Simulator",
        Some(DeviceKind::FilterWheel),
    ),
    (
        "rotator_simulator",
        "Rotator Simulator",
        Some(DeviceKind::Rotator),
    ),
    ("dome_simulator", "Dome Simulator", Some(DeviceKind::Dome)),
    // DUSTCAP | AUX.
    (
        "dust_cover_simulator",
        "Dust Cover Simulator",
        Some(DeviceKind::CoverCalibrator),
    ),
    // LIGHTBOX | AUX.
    (
        "light_panel_simulator",
        "Light Panel Simulator",
        Some(DeviceKind::CoverCalibrator),
    ),
    ("flip_flat", "Flip Flat", Some(DeviceKind::CoverCalibrator)),
    // DUSTCAP | LIGHTBOX | AUX.
    (
        "deep_sky_dad_fp",
        "Deep Sky Dad FP",
        Some(DeviceKind::CoverCalibrator),
    ),
    (
        "weather_simulator",
        "Weather Simulator",
        Some(DeviceKind::Weather),
    ),
    // FOCUSER | WEATHER | AUX | POWER: a power box with a focuser port.
    ("pegasus_upb", "Pegasus UPB", Some(DeviceKind::Switch)),
    // WEATHER | AUX | POWER.
    ("pegasus_ppba", "Pegasus PPBA", Some(DeviceKind::Switch)),
    // AUX | OUTPUT | INPUT.
    ("simulator_io", "Simulator IO", Some(DeviceKind::Switch)),
    ("gps_simulator", "GPS Simulator", None),
    // GENERAL (0) tells nothing; only the switch fallback is left.
    ("sqm_simulator", "SQM Simulator", Some(DeviceKind::Switch)),
];

#[tokio::test]
async fn real_drivers_are_listed_by_their_interfaces_before_they_connect() {
    for (stem, device, expected) in BY_INTERFACE {
        let kind = kind_of(fixture(&format!("{stem}.before.xml")), device).await;
        assert_eq!(kind, expected, "{device} before CONNECT");
    }
}

#[tokio::test]
async fn connecting_does_not_change_the_kind() {
    for (stem, device, expected) in BY_INTERFACE {
        let name = format!("{stem}.after.xml");
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/drivers")
            .join(&name);
        if !path.exists() {
            continue;
        }
        assert_eq!(
            kind_of(fixture(&name), device).await,
            expected,
            "{device} connected"
        );
    }
}

#[tokio::test]
async fn without_published_interfaces_the_properties_decide() {
    let cases: [(&str, &str, Option<DeviceKind>); 11] = [
        // The built-in wheel's FILTER_SLOT does not outrank the camera.
        ("ccd_simulator", "CCD Simulator", Some(DeviceKind::Camera)),
        (
            "guide_simulator",
            "Guide Simulator",
            Some(DeviceKind::Camera),
        ),
        // The mount's TELESCOPE_TIMED_GUIDE_* does not make it a guider.
        (
            "telescope_simulator",
            "Telescope Simulator",
            Some(DeviceKind::Mount),
        ),
        (
            "focuser_simulator",
            "Focuser Simulator",
            Some(DeviceKind::Focuser),
        ),
        (
            "filter_simulator",
            "Filter Simulator",
            Some(DeviceKind::FilterWheel),
        ),
        (
            "rotator_simulator",
            "Rotator Simulator",
            Some(DeviceKind::Rotator),
        ),
        ("dome_simulator", "Dome Simulator", Some(DeviceKind::Dome)),
        (
            "dust_cover_simulator",
            "Dust Cover Simulator",
            Some(DeviceKind::CoverCalibrator),
        ),
        (
            "light_panel_simulator",
            "Light Panel Simulator",
            Some(DeviceKind::CoverCalibrator),
        ),
        // An INDI 2 weather station publishes SAFETY_STATUS.
        (
            "weather_simulator",
            "Weather Simulator",
            Some(DeviceKind::SafetyMonitor),
        ),
        ("sqm_simulator", "SQM Simulator", Some(DeviceKind::Switch)),
    ];
    for (stem, device, expected) in cases {
        let xml = without_driver_info(&fixture(&format!("{stem}.after.xml")));
        assert_eq!(
            kind_of(xml, device).await,
            expected,
            "{device} without DRIVER_INFO"
        );
    }
}

#[tokio::test]
async fn without_published_interfaces_an_unconnected_device_is_known_by_its_name() {
    let cases: [(&str, &str, Option<DeviceKind>); 4] = [
        (
            "telescope_simulator",
            "Telescope Simulator",
            Some(DeviceKind::Mount),
        ),
        (
            "filter_simulator",
            "Filter Simulator",
            Some(DeviceKind::FilterWheel),
        ),
        (
            "weather_simulator",
            "Weather Simulator",
            Some(DeviceKind::Weather),
        ),
        ("moonlite", "MoonLite", Some(DeviceKind::Switch)),
    ];
    for (stem, device, expected) in cases {
        let xml = without_driver_info(&fixture(&format!("{stem}.before.xml")));
        assert_eq!(
            kind_of(xml, device).await,
            expected,
            "{device} without DRIVER_INFO"
        );
    }
}

#[tokio::test]
async fn a_whole_server_lists_every_device_skotiq_drives() {
    let all: String = BY_INTERFACE
        .iter()
        .map(|(stem, _, _)| fixture(&format!("{stem}.before.xml")))
        .collect();
    let client = client_for(all).await;
    let mut listed: Vec<(String, DeviceKind)> = list_devices(&*client.read().await)
        .await
        .into_iter()
        .map(|device| (device.name, device.kind))
        .collect();
    listed.sort_by(|a, b| a.0.cmp(&b.0));
    let mut expected: Vec<(String, DeviceKind)> = BY_INTERFACE
        .iter()
        .filter_map(|(_, name, kind)| kind.map(|kind| (name.to_string(), kind)))
        .collect();
    expected.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(listed, expected);
}
