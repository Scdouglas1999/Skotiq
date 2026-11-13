//! The CCD simulator's frame read the way a capture reads it.
//!
//! Ignored by default. Start the server on a loopback-only network, then run:
//!
//! ```sh
//! indiserver -p 7790 indi_simulator_ccd
//! SKOTIQ_INDI_SIM_PORT=7790 cargo test -p skotiq_indi --test simulator_frame \
//!     -- --ignored --nocapture
//! ```

use skotiq_indi::{decode_frame, IndiCamera, IndiClient};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

const CAMERA: &str = "CCD Simulator";

/// With no telescope connected the simulator draws no stars: a frame is its
/// read noise, `SIM_NOISE` ADU around zero.
#[tokio::test]
#[ignore = "needs an INDI simulator server; see the module header"]
async fn a_simulator_frame_holds_the_levels_the_simulator_draws() {
    let port: u16 = std::env::var("SKOTIQ_INDI_SIM_PORT")
        .expect("SKOTIQ_INDI_SIM_PORT names the simulator server's port")
        .parse()
        .expect("a port number");
    let mut client = IndiClient::new("127.0.0.1", Some(port));
    client.connect().await.expect("connect to the simulator server");
    let client = Arc::new(RwLock::new(client));
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !client.read().await.has_property(CAMERA, "CONNECTION").await {
        assert!(tokio::time::Instant::now() < deadline, "the camera is defined");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    client
        .write()
        .await
        .connect_and_confirm(CAMERA)
        .await
        .expect("the driver confirms the connection");
    let camera = IndiCamera::new(client.clone(), CAMERA);
    camera.enable_blob().await.expect("enable BLOBs");
    while !client.read().await.has_property(CAMERA, "SIMULATOR_SETTINGS").await {
        assert!(tokio::time::Instant::now() < deadline, "the simulator settings");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let noise = client
        .read()
        .await
        .get_number(CAMERA, "SIMULATOR_SETTINGS", "SIM_NOISE")
        .await
        .expect("the simulator states its noise");

    let set = |property: &'static str, element: &'static str| {
        let client = client.clone();
        async move {
            client
                .write()
                .await
                .set_switch(CAMERA, property, element, true)
                .await
                .expect("the simulator takes the setting");
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
    };
    for format in ["FORMAT_FITS", "FORMAT_XISF"] {
        set("CCD_TRANSFER_FORMAT", format).await;
        let blob = camera
            .capture_image_with_timeout(1.0, Some(Duration::from_secs(30)))
            .await
            .expect("a frame");
        let frame = decode_frame(&blob, (1280, 1024)).expect("the frame decodes");
        let mut levels = frame.pixels.clone();
        levels.sort_unstable();
        let (median, max) = (levels[levels.len() / 2], levels[levels.len() - 1]);
        println!(
            "{format}: {} bytes, {}x{} frame, median {median}, max {max} (SIM_NOISE {noise})",
            blob.len(),
            frame.width,
            frame.height
        );
        assert_eq!((frame.width, frame.height), (1280, 1024));
        assert!(f64::from(median) <= noise, "median {median} above the noise {noise}");
        assert!(f64::from(max) <= 3.0 * noise, "max {max} above the noise {noise}");
    }

    // Compression on: fpack tiles a FITS frame, which is refused by name.
    set("CCD_TRANSFER_FORMAT", "FORMAT_FITS").await;
    set("CCD_COMPRESSION", "INDI_ENABLED").await;
    let blob = camera
        .capture_image_with_timeout(1.0, Some(Duration::from_secs(30)))
        .await
        .expect("a frame");
    let refused = decode_frame(&blob, (1280, 1024)).expect_err("fpack is not read");
    println!("compressed: {} bytes, {refused}", blob.len());
    assert!(refused.to_string().contains("compression"), "{refused}");
    set("CCD_COMPRESSION", "INDI_DISABLED").await;

    client
        .write()
        .await
        .disconnect_and_confirm(CAMERA)
        .await
        .expect("the driver confirms the disconnection");
}
