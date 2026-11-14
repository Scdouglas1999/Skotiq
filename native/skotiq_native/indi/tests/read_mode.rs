//! The read mode of an INDI camera, through its driver's read-mode switch.
//!
//! A scripted server replays the definitions INDI's CCD simulator (2.2.5)
//! sends once connected (`tests/drivers/ccd_simulator.after.xml`) plus the
//! read-mode switch Moravian's driver defines (`indi-mi/mi_ccd.cpp`: elements
//! `READ_MODE_n` labelled with the camera's mode names; here the last one
//! without a label), and answers a write the way a driver does: with the
//! switch set to the mode asked for.

use skotiq_device::{CameraDriver, DriverError};
use skotiq_indi::{wait_for_definitions, IndiCamera, IndiClient};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::RwLock;

const CAMERA: &str = "CCD Simulator";
const MODES: [(&str, &str); 3] = [
    ("READ_MODE_1", "Normal"),
    ("READ_MODE_2", "Low noise"),
    ("READ_MODE_3", ""),
];

fn read_mode_switch(on: &str, def: bool) -> String {
    let (vector, one) = if def {
        ("defSwitchVector", "defSwitch")
    } else {
        ("setSwitchVector", "oneSwitch")
    };
    let switches: String = MODES
        .iter()
        .map(|(element, label)| {
            let state = if *element == on { "On" } else { "Off" };
            let label = if def && !label.is_empty() {
                format!(" label=\"{label}\"")
            } else {
                String::new()
            };
            format!("<{one} name=\"{element}\"{label}>{state}</{one}>")
        })
        .collect();
    let attributes = if def {
        " label=\"Read Mode\" group=\"Main Control\" perm=\"rw\" rule=\"OneOfMany\""
    } else {
        ""
    };
    format!(
        "<{vector} device=\"{CAMERA}\" name=\"CCD_READ_MODE\" state=\"Ok\"{attributes}>{switches}</{vector}>\n"
    )
}

fn definitions(with_read_modes: bool) -> String {
    let path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/drivers/ccd_simulator.after.xml");
    let mut xml =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    if with_read_modes {
        xml.push_str(&read_mode_switch(MODES[0].0, true));
    }
    xml
}

/// The mode a read-mode write switches On.
fn mode_asked_for(write: &str) -> Option<&'static str> {
    MODES
        .iter()
        .map(|(element, _)| *element)
        .find(|element| write.contains(&format!("<oneSwitch name=\"{element}\">On</oneSwitch>")))
}

/// A connected client and the read-mode writes the server received.
async fn camera(with_read_modes: bool) -> (IndiCamera, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("address").port();
    let writes = Arc::new(Mutex::new(Vec::new()));
    let seen = writes.clone();
    tokio::spawn(async move {
        let (socket, _) = listener.accept().await.expect("accept");
        let (reader, mut writer) = socket.into_split();
        let mut lines = BufReader::new(reader).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if line.contains("<getProperties") {
                let _ = writer
                    .write_all(definitions(with_read_modes).as_bytes())
                    .await;
            } else if line.contains("name=\"CCD_READ_MODE\"") {
                seen.lock().unwrap().push(line.clone());
                if let Some(mode) = mode_asked_for(&line) {
                    let _ = writer
                        .write_all(read_mode_switch(mode, false).as_bytes())
                        .await;
                }
            }
        }
    });
    let mut client = IndiClient::new("127.0.0.1", Some(port));
    client.connect().await.expect("connect");
    let client = Arc::new(RwLock::new(client));
    wait_for_definitions(&client, Duration::from_secs(5)).await;
    (IndiCamera::new(client, CAMERA), writes)
}

/// A camera offers the modes its switch lists, named as its driver labels
/// them (an element without a label by its name), takes any of them, and
/// reports the one that is On.
#[tokio::test]
async fn an_indi_camera_names_and_takes_the_read_modes_its_switch_lists() {
    let (mut camera, writes) = camera(true).await;
    let names: Vec<String> = CameraDriver::get_readout_modes(&camera)
        .await
        .unwrap()
        .into_iter()
        .map(|mode| mode.name)
        .collect();
    assert_eq!(names, ["Normal", "Low noise", "READ_MODE_3"]);
    assert_eq!(camera.describe().await.readout_modes.len(), 3);
    assert_eq!(
        camera
            .get_active_readout_mode()
            .await
            .map(|mode| mode.label),
        Some("Normal".to_string())
    );

    let low_noise = CameraDriver::get_readout_modes(&camera).await.unwrap()[1].clone();
    camera
        .set_readout_mode(&low_noise)
        .await
        .expect("low noise");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while camera
        .get_active_readout_mode()
        .await
        .map(|mode| mode.label)
        != Some("Low noise".to_string())
    {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the camera never reported the low-noise mode"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let sent = writes.lock().unwrap().clone();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(mode_asked_for(&sent[0]), Some("READ_MODE_2"));
}

/// The CCD simulator has no read-mode switch: it offers no modes, reports
/// none, and refuses a mode.
#[tokio::test]
async fn an_indi_camera_without_a_read_mode_switch_has_no_read_modes() {
    let (mut camera, writes) = camera(false).await;
    assert!(CameraDriver::get_readout_modes(&camera)
        .await
        .unwrap()
        .is_empty());
    assert_eq!(camera.get_active_readout_mode().await, None);
    let mode = skotiq_device::ReadoutMode {
        name: "Mode 0".to_string(),
        description: String::new(),
        index: 0,
        gain_min: None,
        gain_max: None,
        offset_min: None,
        offset_max: None,
    };
    assert!(matches!(
        camera.set_readout_mode(&mode).await,
        Err(DriverError::NotSupported)
    ));
    assert!(writes.lock().unwrap().is_empty());
}
