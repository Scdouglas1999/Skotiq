//! What each camera driver says about its cooler, against the fake vendor SDKs
//! (`*_FAKE_SDK` in `native_driver_tests.rs`). A camera is set cooling, the
//! driver let go of it, and a new driver connects, as when Skotiq restarts
//! mid-night: a driver whose SDK reads the cooler back reports what the camera
//! holds; one whose SDK cannot reports it unknown, never off.
//!
//! Run one vendor per process with only that vendor's fake on the loader path:
//! `tests/fake_sdk_linux/build_fakes.py <dir>`, then
//! `LD_LIBRARY_PATH=<dir>/<vendor> cargo test --release -p skotiq_native --test cooler_state_fake_sdk -- --ignored <vendor>`.
//! (FLI is covered in `fli_fake_sdk.rs`.)

#![cfg(unix)]

use skotiq_device::{CameraDriver, CameraStatus, DeviceDriver, DriverError};
use skotiq_native::vendor::{atik, moravian, player_one, qhy, svbony, touptek, zwo};

/// What a driver's SDK can say about the cooler.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Readback {
    /// The switch and the set-point.
    Both,
    /// The switch; a set-point read is not compared.
    Switch,
    /// Neither: unknown until this connection sets it.
    None,
}

fn cooler(status: &CameraStatus) -> (Option<bool>, Option<f64>) {
    (status.cooler_on, status.target_temp)
}

async fn status_of<C: CameraDriver>(camera: &C) -> CameraStatus {
    camera.get_status().await.expect("status")
}

/// The first camera `make` gives that has a cooler, connected.
async fn cooled_camera<C: CameraDriver + DeviceDriver>(
    candidates: impl IntoIterator<Item = C>,
) -> C {
    for mut camera in candidates {
        camera.connect().await.expect("connect");
        if camera.capabilities().can_cool {
            return camera;
        }
        camera.disconnect().await.expect("disconnect");
    }
    panic!("the fake offers no cooled camera");
}

/// `make` builds a fresh driver for the same cooled camera.
async fn reconnect_while_cooling<C, F>(make: F, readback: Readback, after_disconnect: Option<bool>)
where
    C: CameraDriver + DeviceDriver,
    F: Fn() -> Vec<C>,
{
    let mut first = cooled_camera(make()).await;
    first.set_cooler(true, Some(-12.0)).await.expect("cool");
    first.disconnect().await.expect("disconnect");

    let mut camera = cooled_camera(make()).await;
    let reconnected = status_of(&camera).await;
    match readback {
        Readback::Both => assert_eq!(cooler(&reconnected), (after_disconnect, Some(-12.0))),
        Readback::Switch => assert_eq!(reconnected.cooler_on, after_disconnect),
        Readback::None => {
            assert_eq!(cooler(&reconnected), (None, None), "{reconnected:?}");
            assert!(
                reconnected.cooler_power.is_some(),
                "the power is the camera's: {reconnected:?}"
            );
        }
    }

    camera.set_cooler(true, Some(-15.0)).await.expect("cool");
    let cooling = status_of(&camera).await;
    assert_eq!(cooling.cooler_on, Some(true));
    if readback != Readback::Switch {
        assert_eq!(cooling.target_temp, Some(-15.0));
    }
    camera.set_cooler(false, None).await.expect("off");
    assert_eq!(status_of(&camera).await.cooler_on, Some(false));
    camera.disconnect().await.expect("disconnect");
}

#[tokio::test]
#[ignore = "needs the ZWO fake on LD_LIBRARY_PATH (see the file header)"]
async fn zwo_reports_the_cooler_the_camera_holds() {
    let ids: Vec<i32> = zwo::discover_devices()
        .await
        .expect("discover")
        .iter()
        .map(|c| c.camera_id)
        .collect();
    reconnect_while_cooling(
        || ids.iter().map(|&id| zwo::ZwoCamera::new(id)).collect(),
        Readback::Both,
        Some(true),
    )
    .await;
}

#[tokio::test]
#[ignore = "needs the Player One fake on LD_LIBRARY_PATH (see the file header)"]
async fn player_one_reports_the_cooler_the_camera_holds() {
    let ids: Vec<i32> = player_one::discover_devices()
        .await
        .expect("discover")
        .iter()
        .map(|c| c.camera_id)
        .collect();
    reconnect_while_cooling(
        || {
            ids.iter()
                .map(|&id| player_one::PlayerOneCamera::new(id))
                .collect()
        },
        Readback::Both,
        Some(true),
    )
    .await;
}

/// A Touptek camera opens cooling at its model's own set-point (the fake's
/// 0 C), whatever the last session set, and the driver reports that.
#[tokio::test]
#[ignore = "needs the Touptek fake on LD_LIBRARY_PATH (see the file header)"]
async fn touptek_reports_the_cooler_the_camera_holds() {
    let count = touptek::discover_devices_for_brand("OGMA")
        .await
        .expect("discover")
        .len();
    reconnect_while_cooling(
        || {
            (0..count)
                .map(|i| touptek::TouptekCamera::new(i, "OGMA"))
                .collect()
        },
        Readback::Switch,
        Some(true),
    )
    .await;
}

#[tokio::test]
#[ignore = "needs the SVBony fake on LD_LIBRARY_PATH (see the file header)"]
async fn svbony_reports_the_cooler_the_camera_holds() {
    let ids: Vec<i32> = svbony::discover_devices()
        .await
        .expect("discover")
        .iter()
        .map(|c| c.camera_id)
        .collect();
    reconnect_while_cooling(
        || {
            ids.iter()
                .map(|&id| svbony::SvbonyCamera::new(id))
                .collect()
        },
        Readback::Both,
        Some(true),
    )
    .await;
}

/// Atik warms the camera up when it lets go of it, and the camera's flags then
/// say so.
#[tokio::test]
#[ignore = "needs the Atik fake on LD_LIBRARY_PATH (see the file header)"]
async fn atik_reports_the_cooler_the_camera_holds() {
    let ids: Vec<i32> = atik::discover_devices()
        .await
        .expect("discover")
        .iter()
        .map(|c| c.device_index)
        .collect();
    reconnect_while_cooling(
        || ids.iter().map(|&id| atik::AtikCamera::new(id)).collect(),
        Readback::Switch,
        Some(false),
    )
    .await;
}

#[tokio::test]
#[ignore = "needs the QHY fake on LD_LIBRARY_PATH (see the file header)"]
async fn qhy_reports_a_cooler_it_cannot_read_as_unknown() {
    let ids: Vec<String> = qhy::discover_devices()
        .await
        .expect("discover")
        .iter()
        .map(|c| c.camera_id.clone())
        .collect();
    reconnect_while_cooling(
        || {
            ids.iter()
                .map(|id| qhy::QhyCamera::new(id.clone()))
                .collect()
        },
        Readback::None,
        None,
    )
    .await;
}

#[tokio::test]
#[ignore = "needs the Moravian fake on LD_LIBRARY_PATH (see the file header)"]
async fn moravian_reports_a_cooler_it_cannot_read_as_unknown() {
    let addresses: Vec<String> = moravian::discover_devices()
        .await
        .expect("discover")
        .iter()
        .map(|c| c.address())
        .collect();
    let cameras = || -> Vec<moravian::MoravianCamera> {
        addresses
            .iter()
            .map(|a| moravian::MoravianCamera::from_address(a).expect("an address"))
            .collect()
    };
    reconnect_while_cooling(cameras, Readback::None, None).await;
    // Cooling needs a set-point the camera cannot report: one is never invented.
    let mut camera = cooled_camera(cameras()).await;
    assert!(matches!(
        camera.set_cooler(true, None).await,
        Err(DriverError::InvalidParameter(_))
    ));
    camera.disconnect().await.expect("disconnect");
}
