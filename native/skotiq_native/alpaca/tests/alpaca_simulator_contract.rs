//! Alpaca simulator contract integration tests.
//!
//! # `unwrap_or` policy
//!
//! Every `unwrap_or` site in this file lives inside the *toy HTTP parser*
//! that the test simulator uses to parse loopback requests. The defaults
//! are intentionally lenient because:
//!
//! * The parser is fed only the requests produced by `skotiq_alpaca`
//!   itself — well-formed HTTP/1.1 lines. A missing token (`""` from
//!   `unwrap_or_default()`) routes to the catch-all "unhandled" branch,
//!   which fails the assertion in the test body and surfaces the bad
//!   request line. So the fallback does NOT hide bugs; it converts them
//!   into a `Failed to handle endpoint …` panic with the parsed pieces.
//! * `content_length.parse().unwrap_or(0)` — a missing or malformed
//!   `Content-Length` defaults to "no body", which is the HTTP/1.1
//!   default for GET; this matches real Alpaca server behavior.
//! * `unwrap_or(false)` on the JSON `Connected` field defaults the
//!   simulator's connected state to `false` if the test client sends a
//!   malformed PUT — again surfacing the bad payload via the test
//!   assertion rather than silently succeeding.
use serde_json::{json, Value};
use skotiq_alpaca::{AlpacaCamera, AlpacaFilterWheel, AlpacaTelescope, CameraState, DriveRate};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

#[derive(Clone)]
struct SimState {
    requests: Arc<Mutex<Vec<String>>>,
    camera_connected: Arc<Mutex<bool>>,
    telescope_tracking: Arc<Mutex<bool>>,
    filter_position: Arc<Mutex<i32>>,
}

impl SimState {
    fn new() -> Self {
        Self {
            requests: Arc::new(Mutex::new(Vec::new())),
            camera_connected: Arc::new(Mutex::new(false)),
            telescope_tracking: Arc::new(Mutex::new(true)),
            filter_position: Arc::new(Mutex::new(0)),
        }
    }

    fn record(&self, method: &str, path: &str, body: &str) {
        self.requests
            .lock()
            .unwrap()
            .push(format!("{method} {path} {body}"));
    }
}

async fn start_simulator() -> (String, SimState) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let state = SimState::new();
    let server_state = state.clone();

    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                break;
            };
            let state = server_state.clone();
            tokio::spawn(async move {
                let _ = handle_connection(stream, state).await;
            });
        }
    });

    (format!("http://{}", addr), state)
}

async fn handle_connection(mut stream: TcpStream, state: SimState) -> std::io::Result<()> {
    let mut buffer = vec![0u8; 8192];
    let mut read = 0usize;

    loop {
        let n = stream.read(&mut buffer[read..]).await?;
        if n == 0 {
            return Ok(());
        }
        read += n;
        if read >= 4 && buffer[..read].windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if read == buffer.len() {
            buffer.resize(buffer.len() * 2, 0);
        }
    }

    let header_end = buffer[..read]
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|p| p + 4)
        .unwrap();
    let header_text = String::from_utf8_lossy(&buffer[..header_end]).to_string();
    let mut lines = header_text.lines();
    let request_line = lines.next().unwrap_or_default().to_string();
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next().unwrap_or_default();
    let raw_path = request_parts.next().unwrap_or_default();

    let mut content_length = 0usize;
    for line in lines {
        if let Some(value) = line.strip_prefix("Content-Length:") {
            content_length = value.trim().parse().unwrap_or(0);
        }
    }

    while read < header_end + content_length {
        let n = stream.read(&mut buffer[read..]).await?;
        if n == 0 {
            break;
        }
        read += n;
    }

    let body = String::from_utf8_lossy(&buffer[header_end..read]).to_string();
    state.record(method, raw_path, &body);

    let path = raw_path.split('?').next().unwrap_or(raw_path);
    let endpoint = path
        .rsplit('/')
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let device = path
        .split('/')
        .nth(3)
        .unwrap_or_default()
        .to_ascii_lowercase();
    let device_number = path.split('/').nth(4).unwrap_or_default();
    let form = parse_form(&body);

    if method == "PUT" && device == "camera" && device_number == "99" && endpoint == "startexposure"
    {
        let body = json!({
            "Value": Value::Null,
            "ClientTransactionId": 1,
            "ServerTransactionId": 1,
            "ErrorNumber": 1031,
            "ErrorMessage": "simulated camera rejected exposure"
        })
        .to_string();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        stream.write_all(response.as_bytes()).await?;
        return stream.shutdown().await;
    }

    let value = match (method, device.as_str(), endpoint.as_str()) {
        ("PUT", _, "connected") => {
            let connected = form
                .get("Connected")
                .map(|v| v.eq_ignore_ascii_case("true"))
                .unwrap_or(false);
            if device == "camera" {
                *state.camera_connected.lock().unwrap() = connected;
            }
            Value::Null
        }
        ("GET", "camera", "connected") => json!(*state.camera_connected.lock().unwrap()),
        ("GET", "camera", "name") => json!("Skotiq Alpaca Camera Simulator"),
        ("GET", "camera", "camerastate") => json!(CameraState::Idle as i32),
        ("GET", "camera", "imageready") => json!(true),
        ("GET", "camera", "numx") => json!(2),
        ("GET", "camera", "numy") => json!(2),
        ("GET", "camera", "binx") => json!(1),
        ("GET", "camera", "biny") => json!(1),
        ("GET", "camera", "ccdtemperature") => json!(-10.5),
        ("GET", "camera", "cooleron") => json!(true),
        ("GET", "camera", "coolerpower") => json!(42.0),
        ("GET", "camera", "imagearrayvariant") => {
            json!({"Type": 8, "Rank": 2, "Value": [[10, 20], [30, 40]]})
        }
        ("PUT", "camera", "startexposure") => Value::Null,
        ("PUT", "camera", "abortexposure") => Value::Null,
        ("GET", "filterwheel", "connected") => json!(true),
        ("GET", "filterwheel", "position") => json!(*state.filter_position.lock().unwrap()),
        ("GET", "filterwheel", "names") => json!(["L", "R", "G", "B", "Ha"]),
        ("GET", "filterwheel", "focusoffsets") => json!([0, 2, 2, 2, 8]),
        ("PUT", "filterwheel", "position") => {
            if let Some(position) = form.get("Position").and_then(|v| v.parse::<i32>().ok()) {
                *state.filter_position.lock().unwrap() = position;
            }
            Value::Null
        }
        ("GET", "telescope", "connected") => json!(true),
        ("GET", "telescope", "rightascension") => json!(5.5),
        ("GET", "telescope", "declination") => json!(-12.25),
        ("GET", "telescope", "altitude") => json!(44.0),
        ("GET", "telescope", "azimuth") => json!(180.0),
        ("GET", "telescope", "slewing") => json!(false),
        ("GET", "telescope", "tracking") => json!(*state.telescope_tracking.lock().unwrap()),
        ("GET", "telescope", "trackingrate") => json!(DriveRate::Sidereal as i32),
        ("GET", "telescope", "athome") => json!(false),
        ("GET", "telescope", "atpark") => json!(false),
        ("GET", "telescope", "sideofpier") => json!(0),
        ("GET", "telescope", "siderealtime") => json!(6.25),
        ("PUT", "telescope", "tracking") => {
            let tracking = form
                .get("Tracking")
                .map(|v| v.eq_ignore_ascii_case("true"))
                .unwrap_or(false);
            *state.telescope_tracking.lock().unwrap() = tracking;
            Value::Null
        }
        ("PUT", "telescope", "slewtocoordinates") => Value::Null,
        ("PUT", "telescope", "abortslew") => Value::Null,
        _ => json!(format!("unhandled {method} {path}")),
    };

    let body = if method == "GET"
        && device == "camera"
        && device_number == "98"
        && endpoint == "imagearrayvariant"
    {
        "{\"Type\":8,\"Rank\":2,\"Value\":[[1,2],[3,4]]".to_string()
    } else if method == "GET" && device == "camera" && endpoint == "imagearrayvariant" {
        value.to_string()
    } else {
        let error_number = if matches!(value, Value::String(ref s) if s.starts_with("unhandled ")) {
            1024
        } else {
            0
        };
        let error_message = if error_number == 0 {
            String::new()
        } else {
            value.as_str().unwrap_or("unhandled").to_string()
        };
        json!({
            "Value": if error_number == 0 { value } else { Value::Null },
            "ClientTransactionId": 1,
            "ServerTransactionId": 1,
            "ErrorNumber": error_number,
            "ErrorMessage": error_message
        })
        .to_string()
    };

    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    stream.write_all(response.as_bytes()).await?;
    stream.shutdown().await
}

fn parse_form(body: &str) -> HashMap<String, String> {
    body.split('&')
        .filter_map(|pair| {
            let (key, value) = pair.split_once('=')?;
            Some((key.to_string(), value.replace('+', " ")))
        })
        .collect()
}

#[tokio::test]
async fn alpaca_simulator_camera_filterwheel_and_telescope_contract() {
    let (base_url, state) = start_simulator().await;

    let camera = AlpacaCamera::from_server(&base_url, 0);
    camera.connect().await.unwrap();
    assert!(camera.is_connected().await.unwrap());
    assert_eq!(
        camera.name().await.unwrap(),
        "Skotiq Alpaca Camera Simulator"
    );
    camera.start_exposure(0.01, true).await.unwrap();
    assert!(camera.image_ready().await.unwrap());
    let (width, height, pixels) = camera.download_image_data().await.unwrap();
    assert_eq!((width, height), (2, 2));
    assert_eq!(pixels, vec![10, 20, 30, 40]);
    camera.abort_exposure().await.unwrap();

    let filter_wheel = AlpacaFilterWheel::from_server(&base_url, 0);
    assert_eq!(filter_wheel.names().await.unwrap()[4], "Ha");
    filter_wheel.set_position(3).await.unwrap();
    assert_eq!(filter_wheel.position().await.unwrap(), 3);

    let telescope = AlpacaTelescope::from_server(&base_url, 0);
    assert!(telescope.tracking().await.unwrap());
    telescope.set_tracking(false).await.unwrap();
    assert!(!telescope.tracking().await.unwrap());
    telescope.slew_to_coordinates(5.5, -12.25).await.unwrap();
    telescope.abort_slew().await.unwrap();
    let status = telescope.get_status().await.unwrap();
    assert_eq!(status.right_ascension, 5.5);
    assert_eq!(status.declination, -12.25);

    let requests = state.requests.lock().unwrap().join("\n");
    for expected in [
        "PUT /api/v1/camera/0/connected",
        "PUT /api/v1/camera/0/startexposure",
        "GET /api/v1/camera/0/imagearrayvariant",
        "PUT /api/v1/camera/0/abortexposure",
        "PUT /api/v1/filterwheel/0/position",
        "PUT /api/v1/telescope/0/tracking",
        "PUT /api/v1/telescope/0/slewtocoordinates",
        "PUT /api/v1/telescope/0/abortslew",
    ] {
        assert!(
            requests.contains(expected),
            "missing expected request {expected}; saw:\n{requests}"
        );
    }
}

#[tokio::test]
async fn alpaca_simulator_fault_contract_surfaces_device_and_payload_errors() {
    let (base_url, _state) = start_simulator().await;

    let rejecting_camera = AlpacaCamera::from_server(&base_url, 99);
    rejecting_camera.connect().await.unwrap();
    let exposure_err = rejecting_camera
        .start_exposure(0.01, true)
        .await
        .expect_err("device-side error should fail the exposure call");
    assert!(
        exposure_err.contains("simulated camera rejected exposure"),
        "unexpected exposure error: {exposure_err}"
    );

    let malformed_camera = AlpacaCamera::from_server(&base_url, 98);
    let image_err = malformed_camera
        .download_image_data()
        .await
        .expect_err("malformed imagearrayvariant JSON should fail image download");
    assert!(
        image_err.contains("JSON") || image_err.contains("parse") || image_err.contains("EOF"),
        "unexpected malformed image error: {image_err}"
    );
}
