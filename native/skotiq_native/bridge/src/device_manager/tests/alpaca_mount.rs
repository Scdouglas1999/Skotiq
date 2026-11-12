//! What an Alpaca telescope declares decides what Skotiq sends it: the frame
//! it takes coordinates in (`EquatorialSystem`) and when a guide pulse is over
//! (`IsPulseGuiding`).

use super::*;
use crate::device_manager::epoch::MountFrame;
use crate::dispatch::DeviceOpError;
use std::sync::Mutex as StdMutex;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// A loopback Alpaca telescope. GETs answer from `values` (an absent member
/// answers ASCOM NotImplemented); every PUT succeeds and is recorded as
/// `member body`. `pulse_reads` is how many `IsPulseGuiding` reads answer true
/// before it reads false; `None` makes it NotImplemented.
struct FakeTelescope {
    base_url: String,
    puts: Arc<StdMutex<Vec<String>>>,
}

async fn fake_telescope(
    values: Vec<(&'static str, serde_json::Value)>,
    pulse_reads: Option<u32>,
) -> FakeTelescope {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind fake Alpaca telescope");
    let address = listener.local_addr().expect("listener address");
    let puts = Arc::new(StdMutex::new(Vec::new()));
    let recorded = Arc::clone(&puts);
    let values: Arc<HashMap<&'static str, serde_json::Value>> =
        Arc::new(values.into_iter().collect());
    let pulse_reads = Arc::new(StdMutex::new(pulse_reads));
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            let (values, recorded, pulse_reads) =
                (Arc::clone(&values), Arc::clone(&recorded), Arc::clone(&pulse_reads));
            tokio::spawn(async move {
                let request = read_request(&mut socket).await;
                let mut words = request.split_whitespace();
                let method = words.next().unwrap_or_default().to_string();
                let target = words.next().unwrap_or_default();
                let member = target
                    .split('?')
                    .next()
                    .unwrap_or_default()
                    .rsplit('/')
                    .next()
                    .unwrap_or_default()
                    .to_string();
                let mut reply = serde_json::json!({
                    "ClientTransactionID": 0, "ServerTransactionID": 1,
                    "ErrorNumber": 0, "ErrorMessage": "",
                });
                if method == "PUT" {
                    let body = request.split("\r\n\r\n").nth(1).unwrap_or_default();
                    recorded
                        .lock()
                        .expect("lock puts")
                        .push(format!("{member} {body}"));
                } else if member == "ispulseguiding" {
                    let mut left = pulse_reads.lock().expect("lock pulse reads");
                    match left.as_mut() {
                        Some(0) => reply["Value"] = serde_json::json!(false),
                        Some(n) => {
                            *n -= 1;
                            reply["Value"] = serde_json::json!(true);
                        }
                        None => {
                            reply["ErrorNumber"] = serde_json::json!(0x400);
                            reply["ErrorMessage"] = serde_json::json!("IsPulseGuiding");
                        }
                    }
                } else if let Some(value) = values.get(member.as_str()) {
                    reply["Value"] = value.clone();
                } else {
                    reply["ErrorNumber"] = serde_json::json!(0x400);
                    reply["ErrorMessage"] = serde_json::json!(format!("{member} not implemented"));
                }
                let body = reply.to_string();
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\
                     Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = socket.write_all(response.as_bytes()).await;
            });
        }
    });
    FakeTelescope {
        base_url: format!("http://{address}"),
        puts,
    }
}

/// One HTTP request: the headers, then as much body as `Content-Length` says.
async fn read_request(socket: &mut tokio::net::TcpStream) -> String {
    let mut bytes = Vec::new();
    let mut chunk = [0_u8; 4096];
    loop {
        let Ok(read) = socket.read(&mut chunk).await else {
            break;
        };
        if read == 0 {
            break;
        }
        bytes.extend_from_slice(&chunk[..read]);
        let text = String::from_utf8_lossy(&bytes);
        if let Some((head, body)) = text.split_once("\r\n\r\n") {
            let length = head
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
                .unwrap_or(0);
            if body.len() >= length {
                break;
            }
        }
    }
    String::from_utf8_lossy(&bytes).to_string()
}

fn mount_values(equatorial_system: Option<i32>) -> Vec<(&'static str, serde_json::Value)> {
    let mut values = vec![
        ("connected", serde_json::json!(true)),
        ("tracking", serde_json::json!(true)),
        ("atpark", serde_json::json!(false)),
        ("slewing", serde_json::json!(false)),
        ("rightascension", serde_json::json!(5.5)),
        ("declination", serde_json::json!(22.0)),
        ("athome", serde_json::json!(false)),
        ("sideofpier", serde_json::json!(0)),
    ];
    if let Some(system) = equatorial_system {
        values.push(("equatorialsystem", serde_json::json!(system)));
    }
    values
}

/// Registers and connects the fake as `device_id` the way a profile does.
async fn connect_fake(manager: &DeviceManager, fake: &FakeTelescope) -> String {
    let device_id = format!("alpaca:{}:telescope:0", fake.base_url);
    let info = build_mount_info(&device_id, DriverType::Alpaca);
    manager.register_device(info.clone(), false).await;
    manager.connect_alpaca(&info).await.expect("connect");
    device_id
}

fn sent_coordinates(fake: &FakeTelescope, member: &str) -> (f64, f64) {
    let puts = fake.puts.lock().expect("lock puts");
    let body = puts
        .iter()
        .rev()
        .find_map(|put| put.strip_prefix(&format!("{member} ")))
        .unwrap_or_else(|| panic!("no {member} in {puts:?}"))
        .to_string();
    let field = |name: &str| -> f64 {
        body.split('&')
            .find_map(|pair| pair.strip_prefix(&format!("{name}=")))
            .unwrap_or_else(|| panic!("no {name} in {body}"))
            .parse()
            .expect("number")
    };
    (field("RightAscension"), field("Declination"))
}

/// A mount that declares `equJ2000` is sent catalog coordinates unchanged; the
/// precession Skotiq applies for mounts of date would put it ~22′ off.
#[tokio::test]
async fn a_j2000_mount_is_sent_j2000_coordinates() {
    let fake = fake_telescope(mount_values(Some(2)), Some(0)).await;
    let manager = build_device_manager();
    let device_id = connect_fake(&manager, &fake).await;
    assert_eq!(manager.mount_frame(&device_id).await, Some(MountFrame::J2000));

    manager
        .mount_slew(&device_id, 5.5, 22.0)
        .await
        .expect("slew");
    assert_eq!(sent_coordinates(&fake, "slewtocoordinatesasync"), (5.5, 22.0));
    manager
        .mount_sync(&device_id, 5.5, 22.0)
        .await
        .expect("sync");
    assert_eq!(sent_coordinates(&fake, "synctocoordinates"), (5.5, 22.0));
}

/// A topocentric mount, and one that does not say, get coordinates of date.
#[tokio::test]
async fn a_mount_of_date_is_sent_precessed_coordinates() {
    for declared in [Some(1), None, Some(0)] {
        let fake = fake_telescope(mount_values(declared), Some(0)).await;
        let manager = build_device_manager();
        let device_id = connect_fake(&manager, &fake).await;
        assert_eq!(
            manager.mount_frame(&device_id).await,
            Some(MountFrame::OfDate),
            "EquatorialSystem {declared:?}"
        );
        manager
            .mount_slew(&device_id, 5.5, 22.0)
            .await
            .expect("slew");
        let (ra, dec) = sent_coordinates(&fake, "slewtocoordinatesasync");
        let (want_ra, want_dec) = crate::device_manager::epoch::j2000_to_jnow(5.5, 22.0);
        assert!((ra - want_ra).abs() < 1e-6 && (dec - want_dec).abs() < 1e-5);
        assert!((ra - 5.5).abs() * 15.0 * 60.0 > 10.0, "precessed by minutes of arc");
    }
}

/// An asynchronous `PulseGuide` returns at once; the call returns when
/// `IsPulseGuiding` reads false, not before the pulse's length has passed.
#[tokio::test]
async fn a_pulse_guide_returns_when_the_pulse_is_over() {
    let fake = fake_telescope(mount_values(Some(1)), Some(4)).await;
    let manager = build_device_manager();
    let device_id = connect_fake(&manager, &fake).await;

    let started = Instant::now();
    manager
        .mount_pulse_guide(&device_id, "north".to_string(), 300)
        .await
        .expect("pulse");
    let took = started.elapsed();
    assert!(took >= Duration::from_millis(300), "returned after {took:?}");
    assert!(
        took >= Duration::from_millis(300 + 3 * 50),
        "waited out the reads that still reported the pulse: {took:?}"
    );
    assert!(fake
        .puts
        .lock()
        .expect("lock puts")
        .iter()
        .any(|put| put.starts_with("pulseguide ") && put.contains("Direction=0") && put.contains("Duration=300")));
}

/// A driver that cannot report `IsPulseGuiding` is done when the pulse's
/// length has passed.
#[tokio::test]
async fn a_pulse_on_a_driver_without_is_pulse_guiding_lasts_its_length() {
    let fake = fake_telescope(mount_values(Some(1)), None).await;
    let manager = build_device_manager();
    let device_id = connect_fake(&manager, &fake).await;

    let started = Instant::now();
    manager
        .mount_pulse_guide(&device_id, "west".to_string(), 250)
        .await
        .expect("pulse");
    let took = started.elapsed();
    assert!(
        took >= Duration::from_millis(250) && took < Duration::from_millis(1500),
        "{took:?}"
    );
}

/// A mount that never stops reporting the pulse is a fault the guider hears
/// about, after the pulse's length and a grace period.
#[tokio::test]
async fn a_pulse_that_never_ends_is_a_timeout() {
    let fake = fake_telescope(mount_values(Some(1)), Some(u32::MAX)).await;
    let manager = build_device_manager();
    let device_id = connect_fake(&manager, &fake).await;

    let error = manager
        .mount_pulse_guide(&device_id, "east".to_string(), 100)
        .await
        .expect_err("the pulse never ends");
    assert!(matches!(error, DeviceOpError::Timeout { .. }), "{error:?}");
}
