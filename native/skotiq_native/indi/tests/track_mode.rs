//! The tracking rate of an INDI mount, through `TELESCOPE_TRACK_MODE`.
//!
//! A scripted server replays the definitions INDI's telescope simulator
//! (2.2.5) sends once connected (`tests/drivers/telescope_simulator.after.xml`)
//! and answers a track-mode write the way the simulator does: with the
//! switch set to the mode asked for.

use skotiq_device::{DriverError, MountDriver, TrackingRate};
use skotiq_indi::{wait_for_definitions, IndiClient, IndiMount};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::RwLock;

const MOUNT: &str = "Telescope Simulator";
const MODES: [&str; 4] = ["TRACK_SIDEREAL", "TRACK_SOLAR", "TRACK_LUNAR", "TRACK_CUSTOM"];

fn definitions() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/drivers/telescope_simulator.after.xml");
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// The mode a track-mode write switches On.
fn mode_asked_for(write: &str) -> Option<&'static str> {
    MODES
        .into_iter()
        .find(|mode| write.contains(&format!("<oneSwitch name=\"{mode}\">On</oneSwitch>")))
}

fn mode_set_to(mode: &str) -> String {
    let switches: String = MODES
        .iter()
        .map(|each| {
            let state = if *each == mode { "On" } else { "Off" };
            format!("<oneSwitch name=\"{each}\">{state}</oneSwitch>")
        })
        .collect();
    format!(
        "<setSwitchVector device=\"{MOUNT}\" name=\"TELESCOPE_TRACK_MODE\" state=\"Ok\">{switches}</setSwitchVector>\n"
    )
}

/// A connected client and the track-mode writes the server received.
async fn simulator() -> (Arc<RwLock<IndiClient>>, Arc<Mutex<Vec<String>>>) {
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
                let _ = writer.write_all(definitions().as_bytes()).await;
            } else if line.contains("name=\"TELESCOPE_TRACK_MODE\"") {
                seen.lock().unwrap().push(line.clone());
                if let Some(mode) = mode_asked_for(&line) {
                    let _ = writer.write_all(mode_set_to(mode).as_bytes()).await;
                }
            }
        }
    });
    let mut client = IndiClient::new("127.0.0.1", Some(port));
    client.connect().await.expect("connect");
    let client = Arc::new(RwLock::new(client));
    wait_for_definitions(&client, Duration::from_secs(5)).await;
    (client, writes)
}

/// A mount offers the rates its track-mode switch lists, takes any of them,
/// and reads back the one that is On. The custom mode is not offered: its rate
/// is numbers nothing here sets.
#[tokio::test]
async fn an_indi_mount_takes_a_tracking_rate_its_track_mode_lists() {
    let (client, writes) = simulator().await;
    let mut mount = IndiMount::new(client, MOUNT);
    let offered = [TrackingRate::Sidereal, TrackingRate::Solar, TrackingRate::Lunar];
    assert_eq!(mount.tracking_rates().await, offered);
    assert_eq!(mount.describe().await.tracking_rates, offered);
    assert_eq!(mount.get_tracking_rate().await.unwrap(), TrackingRate::Sidereal);

    mount.set_tracking_rate(TrackingRate::Lunar).await.expect("lunar");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while mount.get_tracking_rate().await.unwrap() != TrackingRate::Lunar {
        assert!(tokio::time::Instant::now() < deadline, "the mount never tracked lunar");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let sent = writes.lock().unwrap().clone();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(mode_asked_for(&sent[0]), Some("TRACK_LUNAR"));

    assert!(matches!(
        mount.set_tracking_rate(TrackingRate::King).await,
        Err(DriverError::NotSupported)
    ));
    let status = mount.status().await.expect("status");
    assert!(status.can_set_tracking_rate);
    assert_eq!(status.tracking_rate.unwrap(), TrackingRate::Lunar);
}
