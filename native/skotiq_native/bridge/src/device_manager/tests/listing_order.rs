use super::*;

fn info(id: &str, device_type: DeviceType) -> DeviceInfo {
    DeviceInfo {
        id: id.to_string(),
        name: id.to_string(),
        device_type,
        driver_type: DriverType::Simulator,
        description: String::new(),
        driver_version: "1.0".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: id.to_string(),
    }
}

/// Registers the same devices in every rotation of the given order and
/// returns what each registry lists. A hash map does not iterate in insertion
/// order, but two maps built in different orders are the cheapest way to get
/// two different iteration orders inside one process.
async fn listings_for_each_rotation(devices: &[(&str, DeviceType)]) -> Vec<Vec<String>> {
    let mut listings = Vec::new();
    for shift in 0..devices.len() {
        let manager = build_device_manager();
        for i in 0..devices.len() {
            let (id, device_type) = devices[(i + shift) % devices.len()];
            manager
                .register_connected_device(info(id, device_type))
                .await;
        }
        listings.push(
            manager
                .get_connected_device_infos()
                .await
                .into_iter()
                .map(|d| d.id)
                .collect(),
        );
    }
    listings
}

#[tokio::test]
async fn connected_devices_list_by_kind_then_id() {
    let devices = [
        ("phd2_guider", DeviceType::Guider),
        ("native:zwo_eaf:0", DeviceType::Focuser),
        ("native:zwo:1", DeviceType::Camera),
        ("ascom:Mount.Telescope", DeviceType::Mount),
        ("native:zwo_efw:0", DeviceType::FilterWheel),
        ("native:zwo:0", DeviceType::Camera),
    ];
    let expected: Vec<String> = [
        "native:zwo:0",
        "native:zwo:1",
        "ascom:Mount.Telescope",
        "native:zwo_eaf:0",
        "native:zwo_efw:0",
        "phd2_guider",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();

    for listing in listings_for_each_rotation(&devices).await {
        assert_eq!(listing, expected);
    }
}

#[tokio::test]
async fn the_first_connected_device_of_a_kind_does_not_depend_on_the_hasher() {
    for shift in 0..3 {
        let manager = build_device_manager();
        let cameras = ["sim_camera_2", "sim_camera_1", "sim_camera_3"];
        for i in 0..cameras.len() {
            manager
                .register_connected_device(info(
                    cameras[(i + shift) % cameras.len()],
                    DeviceType::Camera,
                ))
                .await;
        }
        assert_eq!(
            manager
                .first_connected_device_id(DeviceType::Camera)
                .await
                .as_deref(),
            Some("sim_camera_1")
        );
        let listed: Vec<String> = manager
            .get_devices_by_type(DeviceType::Camera)
            .await
            .into_iter()
            .map(|d| d.info.id)
            .collect();
        assert_eq!(listed, ["sim_camera_1", "sim_camera_2", "sim_camera_3"]);
    }
}

/// The unattended safety checks take the first connected monitor; one that is
/// only registered (or was disconnected) must not answer for it.
#[tokio::test]
async fn the_first_connected_device_skips_registered_but_disconnected_ones() {
    let manager = build_device_manager();
    manager
        .register_device(info("a-unsafe-old", DeviceType::SafetyMonitor), false)
        .await;
    manager
        .register_connected_device(info("b-safe-live", DeviceType::SafetyMonitor))
        .await;

    assert_eq!(
        manager
            .first_connected_device_id(DeviceType::SafetyMonitor)
            .await
            .as_deref(),
        Some("b-safe-live")
    );
}
