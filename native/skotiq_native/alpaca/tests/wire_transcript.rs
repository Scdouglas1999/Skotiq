//! Wire transcripts of every public Alpaca device member.
//!
//! A loopback HTTP server records what each wrapper method sends (method,
//! path, query and form parameters) and what the caller gets back, for a
//! normal reply and for a set of failing replies (ASCOM error numbers, HTTP
//! 4xx/5xx, malformed JSON). The transcripts are compared with the golden
//! files in `tests/golden/wire/`, so a change to a member name, a parameter
//! name or its formatting, the request count of a retry loop, or the text of
//! an error shows up as a diff.
//!
//! Regenerate with `SKOTIQ_WIRE_GOLDEN=update cargo test -p skotiq_alpaca
//! --test wire_transcript` and review the diff: these files describe what
//! real devices are sent.

use futures::stream::{self, StreamExt};
use serde_json::{json, Value};
use skotiq_alpaca::{
    AlpacaCamera, AlpacaCoverCalibrator, AlpacaDome, AlpacaFilterWheel, AlpacaFocuser,
    AlpacaObservingConditions, AlpacaRotator, AlpacaSafetyMonitor, AlpacaSwitch, AlpacaTelescope,
    DriveRate, PierSide, TelescopeAxis,
};
use std::collections::HashMap;
use std::fmt::{Debug, Display};
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// How the server answers every request of one step.
#[derive(Clone, Copy, Debug)]
enum Mode {
    Ok,
    /// HTTP 200 carrying an ASCOM error number. `with_value` controls whether
    /// the reply still has a `Value` field, which real servers do not agree on.
    Ascom {
        code: i32,
        message: &'static str,
        with_value: bool,
    },
    Http {
        status: u16,
        body: &'static str,
        retry_after: Option<&'static str>,
    },
    /// HTTP 200 with a body that is not JSON.
    Malformed,
    /// HTTP 200, no error, but `Value` has the wrong JSON type.
    WrongType,
    /// `Connected` reads false this many times before reading true.
    ConnectedReadsFalse(u32),
    /// `imagearrayvariant` answers with an `application/imagebytes` payload.
    ImageBytes,
    /// `imagearrayvariant` answers with an ImageBytes payload carrying an error.
    ImageBytesError,
}

impl Mode {
    fn label(self) -> String {
        match self {
            Mode::Ok => "ok".to_string(),
            Mode::Ascom {
                code, with_value, ..
            } => format!(
                "ascom 0x{code:X}{}",
                if with_value { "" } else { " without Value" }
            ),
            Mode::Http {
                status,
                retry_after,
                ..
            } => match retry_after {
                Some(after) => format!("http {status} retry-after {after}"),
                None => format!("http {status}"),
            },
            Mode::Malformed => "malformed json".to_string(),
            Mode::WrongType => "wrong value type".to_string(),
            Mode::ConnectedReadsFalse(n) => format!("connected reads false x{n}"),
            Mode::ImageBytes => "imagebytes".to_string(),
            Mode::ImageBytesError => "imagebytes error".to_string(),
        }
    }
}

const BASE_MODES: &[Mode] = &[
    Mode::Ok,
    Mode::Ascom {
        code: 0x400,
        message: "Property or method is not implemented",
        with_value: true,
    },
    Mode::Ascom {
        code: 0x4FF,
        message: "Unspecified driver fault",
        with_value: false,
    },
    Mode::Http {
        status: 400,
        body: "Method not implemented",
        retry_after: None,
    },
    Mode::Http {
        status: 500,
        body: "Internal server error",
        retry_after: None,
    },
    Mode::Malformed,
];

const EXTRA_MODES: &[Mode] = &[
    Mode::Ascom {
        code: 0x401,
        message: "Invalid value",
        with_value: true,
    },
    Mode::Ascom {
        code: 0x402,
        message: "Value not set",
        with_value: true,
    },
    Mode::Ascom {
        code: 0x407,
        message: "Not connected",
        with_value: true,
    },
    Mode::Ascom {
        code: 0x408,
        message: "Invalid while parked",
        with_value: true,
    },
    Mode::Ascom {
        code: 0x409,
        message: "Invalid while slaved",
        with_value: true,
    },
    Mode::Ascom {
        code: 0x40B,
        message: "Invalid operation",
        with_value: true,
    },
    Mode::Ascom {
        code: 0x40C,
        message: "Action not implemented",
        with_value: false,
    },
    Mode::Ascom {
        code: 0x500,
        message: "Driver specific error",
        with_value: true,
    },
    Mode::Http {
        status: 404,
        body: "Not Found",
        retry_after: None,
    },
    Mode::Http {
        status: 429,
        body: "Slow down",
        retry_after: Some("0"),
    },
    Mode::Http {
        status: 503,
        body: "Service Unavailable",
        retry_after: None,
    },
    Mode::WrongType,
];

const CONNECT_MODES: &[Mode] = &[Mode::ConnectedReadsFalse(1), Mode::ConnectedReadsFalse(99)];
const IMAGE_MODES: &[Mode] = &[Mode::ImageBytes, Mode::ImageBytesError];

struct Slot {
    mode: Mode,
    log: Vec<String>,
    connected_reads: u32,
}

type Slots = Arc<Mutex<HashMap<u32, Slot>>>;

async fn start_server() -> (String, Slots) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let slots: Slots = Arc::new(Mutex::new(HashMap::new()));
    let server_slots = Arc::clone(&slots);

    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                break;
            };
            let slots = Arc::clone(&server_slots);
            tokio::spawn(async move {
                let _ = handle_connection(stream, slots).await;
            });
        }
    });

    (format!("http://{addr}"), slots)
}

/// Replace the digits after every `key=` with a placeholder.
fn mask_number(text: &str, key: &str, placeholder: &str) -> String {
    let needle = format!("{key}=");
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find(&needle) {
        let after = at + needle.len();
        out.push_str(&rest[..after]);
        let digits = rest[after..]
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .count();
        if digits == 0 {
            rest = &rest[after..];
            continue;
        }
        out.push_str(placeholder);
        rest = &rest[after + digits..];
    }
    out.push_str(rest);
    out
}

fn sorted_pairs(raw: &str) -> String {
    let mut pairs: Vec<&str> = raw.split('&').filter(|p| !p.is_empty()).collect();
    pairs.sort_unstable();
    pairs.join("&")
}

async fn handle_connection(mut stream: TcpStream, slots: Slots) -> std::io::Result<()> {
    let mut buffer = vec![0u8; 8192];
    let mut read = 0usize;
    let header_end = loop {
        let n = stream.read(&mut buffer[read..]).await?;
        if n == 0 {
            return Ok(());
        }
        read += n;
        if let Some(at) = buffer[..read].windows(4).position(|w| w == b"\r\n\r\n") {
            break at + 4;
        }
        if read == buffer.len() {
            buffer.resize(buffer.len() * 2, 0);
        }
    };

    let header_text = String::from_utf8_lossy(&buffer[..header_end]).to_string();
    let mut lines = header_text.lines();
    let request_line = lines.next().unwrap_or_default().to_string();
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next().unwrap_or_default().to_string();
    let raw_path = request_parts.next().unwrap_or_default().to_string();

    let mut content_length = 0usize;
    let mut accept = String::new();
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        match name.to_ascii_lowercase().as_str() {
            "content-length" => content_length = value.trim().parse().unwrap_or(0),
            "accept" => accept = value.trim().to_string(),
            _ => {}
        }
    }
    while read < header_end + content_length {
        if read == buffer.len() {
            buffer.resize(buffer.len() * 2, 0);
        }
        let n = stream.read(&mut buffer[read..]).await?;
        if n == 0 {
            break;
        }
        read += n;
    }
    let body = String::from_utf8_lossy(&buffer[header_end..read]).to_string();

    let (path, query) = raw_path.split_once('?').unwrap_or((raw_path.as_str(), ""));
    let segments: Vec<&str> = path.split('/').collect();
    // "", "api", "v1", device type, device number, endpoint
    let device_type = segments.get(3).copied().unwrap_or_default().to_string();
    let device_number: u32 = segments
        .get(4)
        .and_then(|s| s.parse().ok())
        .unwrap_or(u32::MAX);
    let endpoint = segments.get(5).copied().unwrap_or_default().to_string();

    let mut line = format!(
        "{method} /{}/#/{endpoint}",
        segments.get(1..4).unwrap_or_default().join("/")
    );
    let query = mask_number(query, "ClientID", "<id>");
    line.push_str(&format!(" query[{}]", sorted_pairs(&query)));
    if method != "GET" || !body.is_empty() {
        let form = mask_number(&body, "ClientID", "<id>");
        line.push_str(&format!(" form[{}]", sorted_pairs(&form)));
    }
    if !accept.is_empty() && accept != "*/*" {
        line.push_str(&format!(" accept[{accept}]"));
    }

    let (mode, connected_reads) = {
        let mut slots = slots.lock().unwrap();
        let slot = slots
            .get_mut(&device_number)
            .unwrap_or_else(|| panic!("request for an unregistered step: {request_line}"));
        slot.log.push(line);
        if method == "GET" && endpoint == "connected" {
            slot.connected_reads += 1;
        }
        (slot.mode, slot.connected_reads)
    };

    let reply = build_reply(mode, &method, &device_type, &endpoint, connected_reads);
    stream.write_all(&reply).await?;
    stream.shutdown().await
}

fn http_reply(status: &str, content_type: &str, extra: &str, body: &[u8]) -> Vec<u8> {
    let mut out = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )
    .into_bytes();
    out.extend_from_slice(body);
    out
}

fn envelope(value: Option<Value>, error_number: i32, error_message: &str) -> Vec<u8> {
    let mut body = json!({
        "ClientTransactionID": 0,
        "ServerTransactionID": 1,
        "ErrorNumber": error_number,
        "ErrorMessage": error_message,
    });
    if let Some(value) = value {
        body["Value"] = value;
    }
    http_reply(
        "200 OK",
        "application/json",
        "",
        body.to_string().as_bytes(),
    )
}

fn image_bytes_payload(error_number: i32, message: &[u8]) -> Vec<u8> {
    let data_start = 44 + message.len() as i32;
    let mut buf = Vec::new();
    for field in [
        1,            // MetadataVersion
        error_number, // ErrorNumber
        0,            // ClientTransactionID
        1,            // ServerTransactionID
        data_start,   // DataStart
        2,            // ImageElementType: Int32
        8,            // TransmissionElementType: UInt16
        2,            // Rank
        2,            // Dimension1
        2,            // Dimension2
        0,            // Dimension3
    ] {
        buf.extend_from_slice(&i32::to_le_bytes(field));
    }
    buf.extend_from_slice(message);
    if error_number == 0 {
        for pixel in [10u16, 30, 20, 40] {
            buf.extend_from_slice(&pixel.to_le_bytes());
        }
    }
    buf
}

fn build_reply(
    mode: Mode,
    method: &str,
    device_type: &str,
    endpoint: &str,
    connected_reads: u32,
) -> Vec<u8> {
    let ok_value = if method == "GET" {
        Some(ok_get_value(device_type, endpoint))
    } else {
        ok_put_value(endpoint)
    };

    if endpoint == "imagearrayvariant" {
        match mode {
            Mode::ImageBytes => {
                return http_reply(
                    "200 OK",
                    "application/imagebytes",
                    "",
                    &image_bytes_payload(0, b""),
                )
            }
            Mode::ImageBytesError => {
                return http_reply(
                    "200 OK",
                    "application/imagebytes",
                    "",
                    &image_bytes_payload(0x40B, b"No image is ready"),
                )
            }
            Mode::Ok => {
                let body = json!({
                    "Type": 2,
                    "Rank": 2,
                    "Value": [[10, 20], [30, 40]],
                    "ClientTransactionID": 0,
                    "ServerTransactionID": 1,
                    "ErrorNumber": 0,
                    "ErrorMessage": "",
                });
                return http_reply(
                    "200 OK",
                    "application/json",
                    "",
                    body.to_string().as_bytes(),
                );
            }
            _ => {}
        }
    }

    match mode {
        Mode::Ok | Mode::ImageBytes | Mode::ImageBytesError => envelope(ok_value, 0, ""),
        Mode::ConnectedReadsFalse(n) => {
            if method == "GET" && endpoint == "connected" && connected_reads <= n {
                envelope(Some(json!(false)), 0, "")
            } else {
                envelope(ok_value, 0, "")
            }
        }
        Mode::Ascom {
            code,
            message,
            with_value,
        } => envelope(if with_value { ok_value } else { None }, code, message),
        Mode::Http {
            status,
            body,
            retry_after,
        } => {
            let reason = match status {
                400 => "400 Bad Request",
                404 => "404 Not Found",
                429 => "429 Too Many Requests",
                500 => "500 Internal Server Error",
                503 => "503 Service Unavailable",
                other => panic!("no reason phrase for {other}"),
            };
            let extra = retry_after
                .map(|after| format!("Retry-After: {after}\r\n"))
                .unwrap_or_default();
            http_reply(reason, "text/plain", &extra, body.as_bytes())
        }
        Mode::Malformed => http_reply("200 OK", "application/json", "", b"{\"Value\": tru"),
        Mode::WrongType => envelope(Some(json!({"unexpected": "shape"})), 0, ""),
    }
}

fn ok_put_value(endpoint: &str) -> Option<Value> {
    match endpoint {
        "action" | "commandstring" => Some(json!("reply text")),
        "commandbool" => Some(json!(true)),
        _ => None,
    }
}

fn ok_get_value(device_type: &str, endpoint: &str) -> Value {
    match (device_type, endpoint) {
        ("rotator", "position") => json!(123.5),
        ("filterwheel", "position") => json!(2),
        ("focuser", "position") => json!(12345),
        ("focuser", "stepsize") => json!(4.5),
        ("rotator", "stepsize") => json!(0.5),
        ("dome", "altitude") => json!(45.5),
        ("dome", "atpark") => json!(true),
        ("camera", "ispulseguiding") => json!(false),
        (_, "connected") => json!(true),
        (_, "name") => json!("Sim Name"),
        (_, "description") => json!("Sim Description"),
        (_, "driverversion") => json!("1.2.3"),
        (_, "driverinfo") => json!("Sim Driver Info"),
        (_, "interfaceversion") => json!(3),
        (_, "supportedactions") => json!(["ActionA", "ActionB"]),
        (_, "issafe") => json!(true),
        (_, "maxswitch") => json!(2),
        (_, "getswitch") => json!(true),
        (_, "getswitchname") => json!("Switch A"),
        (_, "getswitchdescription") => json!("Switch A description"),
        (_, "getswitchvalue") => json!(0.5),
        (_, "minswitchvalue") => json!(0.0),
        (_, "maxswitchvalue") => json!(1.0),
        (_, "cloudcover") => json!(10.5),
        (_, "dewpoint") => json!(3.25),
        (_, "humidity") => json!(55.5),
        (_, "pressure") => json!(1013.25),
        (_, "rainrate") => json!(0.0),
        (_, "skybrightness") => json!(0.01),
        (_, "skyquality") => json!(21.5),
        (_, "skytemperature") => json!(-25.5),
        (_, "temperature") => json!(12.5),
        (_, "winddirection") => json!(270.0),
        (_, "windgust") => json!(5.5),
        (_, "windspeed") => json!(3.5),
        (_, "averageperiod") => json!(0.25),
        (_, "timesincelastupdate") => json!(1.5),
        (_, "coverstate") => json!(3),
        (_, "calibratorstate") => json!(3),
        (_, "brightness") => json!(100),
        (_, "maxbrightness") => json!(255),
        (_, "mechanicalposition") => json!(124.5),
        (_, "targetposition") => json!(125.5),
        (_, "ismoving") => json!(false),
        (_, "reverse") => json!(false),
        (_, "names") => json!(["L", "R", "G", "B"]),
        (_, "focusoffsets") => json!([0, 10, 20, 30]),
        (_, "maxstep") => json!(50000),
        (_, "maxincrement") => json!(5000),
        (_, "absolute") => json!(true),
        (_, "tempcompavailable") => json!(true),
        (_, "tempcomp") => json!(false),
        (_, "azimuth") => json!(180.5),
        (_, "athome") => json!(false),
        (_, "atpark") => json!(false),
        (_, "shutterstatus") => json!(1),
        (_, "slewing") => json!(false),
        (_, "slaved") => json!(false),
        (_, "alignmentmode") => json!(2),
        (_, "aperturearea") => json!(0.05),
        (_, "aperturediameter") => json!(0.25),
        (_, "focallength") => json!(1.25),
        (_, "equatorialsystem") => json!(2),
        (_, "rightascension") => json!(5.5),
        (_, "declination") => json!(-12.25),
        (_, "altitude") => json!(44.5),
        (_, "siderealtime") => json!(6.25),
        (_, "utcdate") => json!("2026-11-10T01:02:03.456Z"),
        (_, "targetrightascension") => json!(5.75),
        (_, "targetdeclination") => json!(-12.5),
        (_, "tracking") => json!(true),
        (_, "trackingrate") => json!(1),
        (_, "sideofpier") => json!(1),
        (_, "sitelatitude") => json!(40.5),
        (_, "sitelongitude") => json!(-105.25),
        (_, "siteelevation") => json!(1600.5),
        (_, "trackingrates") => json!([0, 1, 2]),
        (_, "axisrates") => json!([{"Minimum": 0.1, "Maximum": 2.5}]),
        (_, "guideraterightascension") => json!(0.0025),
        (_, "guideratedeclination") => json!(0.00125),
        (_, "ispulseguiding") => json!(true),
        (_, "destinationsideofpier") => json!(0),
        (_, "cameraxsize") => json!(4656),
        (_, "cameraysize") => json!(3520),
        (_, "pixelsizex") => json!(3.8),
        (_, "pixelsizey") => json!(3.75),
        (_, "maxadu") => json!(65535),
        (_, "sensortype") => json!(2),
        (_, "sensorname") => json!("MN34230"),
        (_, "maxbinx") => json!(4),
        (_, "maxbiny") => json!(3),
        (_, "binx") => json!(2),
        (_, "biny") => json!(1),
        (_, "ccdtemperature") => json!(-10.5),
        (_, "cooleron") => json!(true),
        (_, "coolerpower") => json!(42.5),
        (_, "heatsinktemperature") => json!(20.5),
        (_, "gain") => json!(139),
        (_, "gainmin") => json!(0),
        (_, "gainmax") => json!(300),
        (_, "offset") => json!(21),
        (_, "offsetmin") => json!(1),
        (_, "offsetmax") => json!(100),
        (_, "bayeroffsetx") => json!(0),
        (_, "bayeroffsety") => json!(1),
        (_, "camerastate") => json!(2),
        (_, "imageready") => json!(true),
        (_, "percentcompleted") => json!(50),
        (_, "readoutmode") => json!(1),
        (_, "readoutmodes") => json!(["Normal", "Fast"]),
        (_, "startx") => json!(8),
        (_, "starty") => json!(16),
        (_, "numx") => json!(2),
        (_, "numy") => json!(2),
        (_, "lastexposurestarttime") => json!("2026-11-10T01:02:03"),
        (_, "lastexposureduration") => json!(1.5),
        (_, "hasshutter") => json!(false),
        (_, "imagearray") => json!([[10, 20], [30, 40]]),
        (_, "imagearrayvariant") => json!([[10, 20], [30, 40]]),
        (_, "canwrite") => json!(true),
        (_, other) if other.starts_with("can") => json!(true),
        (_, other) => panic!("no scripted value for {device_type}/{other}"),
    }
}

fn render<T: Debug, E: Display>(result: Result<T, E>) -> String {
    match result {
        Ok(value) => format!("Ok({value:?})"),
        Err(error) => format!("Err({error})"),
    }
}

type Run<D> = Box<dyn Fn(Arc<D>) -> Pin<Box<dyn Future<Output = String> + Send>> + Send + Sync>;

struct Member<D> {
    label: &'static str,
    /// The member sends several requests at once, so their arrival order (and
    /// which request draws which transaction id) is not fixed.
    parallel: bool,
    /// Also run under `EXTRA_MODES`.
    representative: bool,
    run: Run<D>,
}

macro_rules! members {
    ($dev:ty; $( $label:literal $([$flag:ident])? => |$d:ident| $call:expr ),* $(,)?) => {
        vec![
            $(
                Member::<$dev> {
                    label: $label,
                    parallel: members!(@is par $($flag)?),
                    representative: members!(@is rep $($flag)?),
                    run: Box::new(|$d: Arc<$dev>| Box::pin(async move { render($call.await) })),
                }
            ),*
        ]
    };
    (@is par par) => { true };
    (@is rep rep) => { true };
    (@is $want:ident $($flag:ident)?) => { false };
}

struct Outcome {
    order: (usize, usize),
    text: String,
}

async fn transcript<D, F>(kind: &str, make: F, members: Vec<Member<D>>) -> String
where
    D: Send + Sync + 'static,
    F: Fn(&str, u32) -> D,
{
    let (base_url, slots) = start_server().await;

    let mut steps = Vec::new();
    for (member_index, member) in members.iter().enumerate() {
        let mut modes: Vec<Mode> = BASE_MODES.to_vec();
        if member.representative {
            modes.extend_from_slice(EXTRA_MODES);
        }
        if member.label.starts_with("connect") {
            modes.extend_from_slice(CONNECT_MODES);
        }
        if member.label.starts_with("download_image") {
            modes.extend_from_slice(IMAGE_MODES);
        }
        for (mode_index, mode) in modes.into_iter().enumerate() {
            steps.push((member_index, mode_index, mode));
        }
    }

    let members = &members;
    let base_url = &base_url;
    let slots = &slots;
    let make = &make;
    let mut outcomes: Vec<Outcome> = stream::iter(steps.into_iter().enumerate())
        .map(|(step, (member_index, mode_index, mode))| async move {
            let device_number = u32::try_from(step).unwrap();
            slots.lock().unwrap().insert(
                device_number,
                Slot {
                    mode,
                    log: Vec::new(),
                    connected_reads: 0,
                },
            );
            let member = &members[member_index];
            let device = Arc::new(make(base_url, device_number));
            let result = (member.run)(device).await;
            let mut log = slots.lock().unwrap().remove(&device_number).unwrap().log;
            if member.parallel {
                log = log
                    .iter()
                    .map(|line| mask_number(line, "ClientTransactionID", "<txn>"))
                    .collect();
                log.sort_unstable();
            }

            let mut text = format!("## {kind}.{} [{}]\n", member.label, mode.label());
            for line in log {
                text.push_str("> ");
                text.push_str(&line);
                text.push('\n');
            }
            text.push_str("= ");
            text.push_str(&result.replace(base_url.as_str(), "<base>"));
            text.push('\n');
            Outcome {
                order: (member_index, mode_index),
                text,
            }
        })
        .buffer_unordered(32)
        .collect()
        .await;

    outcomes.sort_by_key(|outcome| outcome.order);
    outcomes
        .into_iter()
        .map(|outcome| outcome.text)
        .collect::<Vec<_>>()
        .join("\n")
}

fn check_golden(kind: &str, actual: &str) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden/wire")
        .join(format!("{kind}.txt"));
    if std::env::var("SKOTIQ_WIRE_GOLDEN").as_deref() == Ok("update") {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, actual).unwrap();
        return;
    }
    let expected = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    if expected == actual {
        return;
    }
    let actual_path = std::env::temp_dir().join(format!("skotiq-alpaca-wire-{kind}.actual.txt"));
    std::fs::write(&actual_path, actual).unwrap();
    let first_difference = expected
        .lines()
        .zip(actual.lines())
        .position(|(e, a)| e != a)
        .unwrap_or_else(|| expected.lines().count().min(actual.lines().count()));
    panic!(
        "wire transcript for {kind} differs from {} at line {}:\n  golden: {}\n  actual: {}\nfull actual transcript: {}",
        path.display(),
        first_difference + 1,
        expected.lines().nth(first_difference).unwrap_or("<end>"),
        actual.lines().nth(first_difference).unwrap_or("<end>"),
        actual_path.display(),
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn safety_monitor_wire_transcript() {
    let members = members![AlpacaSafetyMonitor;
        "connect" [rep] => |d| d.connect(),
        "disconnect" [rep] => |d| d.disconnect(),
        "is_connected" [rep] => |d| d.is_connected(),
        "validate_connection" [rep] => |d| d.validate_connection(),
        "heartbeat" [rep] => |d| async move { d.heartbeat().await.map(|_| "<ms>") },
        "name" => |d| d.name(),
        "description" => |d| d.description(),
        "driver_version" => |d| d.driver_version(),
        "driver_info" => |d| d.driver_info(),
        "interface_version" => |d| d.interface_version(),
        "supported_actions" => |d| d.supported_actions(),
        "action" [rep] => |d| d.action("ActionA", "p1,p2"),
        "command_string" => |d| d.command_string(":GR#", true),
        "command_blind" => |d| d.command_blind(":Q#", false),
        "command_bool" => |d| d.command_bool(":X#", true),
        "is_safe" [rep] => |d| d.is_safe(),
        "get_status" [par] => |d| d.get_status(),
        "get_info" [par] => |d| d.get_info(),
    ];
    let actual = transcript("safetymonitor", AlpacaSafetyMonitor::from_server, members).await;
    check_golden("safetymonitor", &actual);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn switch_wire_transcript() {
    let members = members![AlpacaSwitch;
        "connect" => |d| d.connect(),
        "disconnect" => |d| d.disconnect(),
        "is_connected" => |d| d.is_connected(),
        "name" => |d| d.name(),
        "description" => |d| d.description(),
        "driver_version" => |d| d.driver_version(),
        "driver_info" => |d| d.driver_info(),
        "interface_version" => |d| d.interface_version(),
        "supported_actions" => |d| d.supported_actions(),
        "max_switch" [rep] => |d| d.max_switch(),
        "get_switch" [rep] => |d| d.get_switch(3),
        "set_switch(true)" [rep] => |d| d.set_switch(3, true),
        "set_switch(false)" => |d| d.set_switch(0, false),
        "get_switch_name" => |d| d.get_switch_name(3),
        "set_switch_name" => |d| d.set_switch_name(3, "Dew heater A&B"),
        "get_switch_description" => |d| d.get_switch_description(3),
        "get_switch_value" => |d| d.get_switch_value(3),
        "set_switch_value" => |d| d.set_switch_value(3, 0.75),
        "set_switch_value(whole)" => |d| d.set_switch_value(1, 12.0),
        "min_switch_value" => |d| d.min_switch_value(3),
        "max_switch_value" => |d| d.max_switch_value(3),
        "can_write" => |d| d.can_write(3),
    ];
    let actual = transcript("switch", AlpacaSwitch::from_server, members).await;
    check_golden("switch", &actual);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn observing_conditions_wire_transcript() {
    let members = members![AlpacaObservingConditions;
        "connect" => |d| d.connect(),
        "disconnect" => |d| d.disconnect(),
        "is_connected" => |d| d.is_connected(),
        "name" => |d| d.name(),
        "description" => |d| d.description(),
        "driver_version" => |d| d.driver_version(),
        "driver_info" => |d| d.driver_info(),
        "interface_version" => |d| d.interface_version(),
        "supported_actions" => |d| d.supported_actions(),
        "cloud_cover" [rep] => |d| d.cloud_cover(),
        "dew_point" => |d| d.dew_point(),
        "humidity" => |d| d.humidity(),
        "pressure" => |d| d.pressure(),
        "rain_rate" => |d| d.rain_rate(),
        "sky_brightness" => |d| d.sky_brightness(),
        "sky_quality" => |d| d.sky_quality(),
        "sky_temperature" => |d| d.sky_temperature(),
        "temperature" => |d| d.temperature(),
        "wind_direction" => |d| d.wind_direction(),
        "wind_gust" => |d| d.wind_gust(),
        "wind_speed" => |d| d.wind_speed(),
        "average_period" => |d| d.average_period(),
        "set_average_period" [rep] => |d| d.set_average_period(0.5),
        "time_since_last_update" [rep] => |d| d.time_since_last_update("Temperature"),
        "refresh" [rep] => |d| d.refresh(),
    ];
    let actual = transcript(
        "observingconditions",
        AlpacaObservingConditions::from_server,
        members,
    )
    .await;
    check_golden("observingconditions", &actual);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cover_calibrator_wire_transcript() {
    let members = members![AlpacaCoverCalibrator;
        "connect" => |d| d.connect(),
        "disconnect" => |d| d.disconnect(),
        "is_connected" => |d| d.is_connected(),
        "name" => |d| d.name(),
        "description" => |d| d.description(),
        "driver_version" => |d| d.driver_version(),
        "driver_info" => |d| d.driver_info(),
        "interface_version" => |d| d.interface_version(),
        "supported_actions" => |d| d.supported_actions(),
        "cover_state" [rep] => |d| d.cover_state(),
        "calibrator_state" => |d| d.calibrator_state(),
        "brightness" => |d| d.brightness(),
        "max_brightness" => |d| d.max_brightness(),
        "open_cover" [rep] => |d| d.open_cover(),
        "close_cover" => |d| d.close_cover(),
        "halt_cover" => |d| d.halt_cover(),
        "calibrator_on" [rep] => |d| d.calibrator_on(128),
        "calibrator_off" => |d| d.calibrator_off(),
        "get_status" [par] => |d| d.get_status(),
    ];
    let actual = transcript(
        "covercalibrator",
        AlpacaCoverCalibrator::from_server,
        members,
    )
    .await;
    check_golden("covercalibrator", &actual);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rotator_wire_transcript() {
    let members = members![AlpacaRotator;
        "connect" => |d| d.connect(),
        "disconnect" => |d| d.disconnect(),
        "is_connected" => |d| d.is_connected(),
        "validate_connection" => |d| d.validate_connection(),
        "heartbeat" => |d| async move { d.heartbeat().await.map(|_| "<ms>") },
        "name" => |d| d.name(),
        "description" => |d| d.description(),
        "driver_version" => |d| d.driver_version(),
        "driver_info" => |d| d.driver_info(),
        "interface_version" => |d| d.interface_version(),
        "supported_actions" => |d| d.supported_actions(),
        "position" [rep] => |d| d.position(),
        "mechanical_position" => |d| d.mechanical_position(),
        "target_position" => |d| d.target_position(),
        "step_size" => |d| d.step_size(),
        "is_moving" => |d| d.is_moving(),
        "can_reverse" => |d| d.can_reverse(),
        "reverse" => |d| d.reverse(),
        "set_reverse" => |d| d.set_reverse(true),
        "move_absolute" [rep] => |d| d.move_absolute(359.75),
        "move_relative" => |d| d.move_relative(-12.5),
        "move_mechanical" => |d| d.move_mechanical(90.0),
        "halt" => |d| d.halt(),
        "sync" => |d| d.sync(180.25),
    ];
    let actual = transcript("rotator", AlpacaRotator::from_server, members).await;
    check_golden("rotator", &actual);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn filter_wheel_wire_transcript() {
    let members = members![AlpacaFilterWheel;
        "connect" => |d| d.connect(),
        "disconnect" => |d| d.disconnect(),
        "is_connected" => |d| d.is_connected(),
        "validate_connection" => |d| d.validate_connection(),
        "heartbeat" => |d| async move { d.heartbeat().await.map(|_| "<ms>") },
        "name" => |d| d.name(),
        "description" => |d| d.description(),
        "driver_version" => |d| d.driver_version(),
        "driver_info" => |d| d.driver_info(),
        "interface_version" => |d| d.interface_version(),
        "supported_actions" => |d| d.supported_actions(),
        "position" [rep] => |d| d.position(),
        "set_position" [rep] => |d| d.set_position(3),
        "names" => |d| d.names(),
        "focus_offsets" => |d| d.focus_offsets(),
    ];
    let actual = transcript("filterwheel", AlpacaFilterWheel::from_server, members).await;
    check_golden("filterwheel", &actual);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn focuser_wire_transcript() {
    let members = members![AlpacaFocuser;
        "connect" => |d| d.connect(),
        "disconnect" => |d| d.disconnect(),
        "is_connected" => |d| d.is_connected(),
        "validate_connection" => |d| d.validate_connection(),
        "heartbeat" => |d| async move { d.heartbeat().await.map(|_| "<ms>") },
        "name" => |d| d.name(),
        "description" => |d| d.description(),
        "driver_version" => |d| d.driver_version(),
        "driver_info" => |d| d.driver_info(),
        "interface_version" => |d| d.interface_version(),
        "supported_actions" => |d| d.supported_actions(),
        "position" [rep] => |d| d.position(),
        "max_step" => |d| d.max_step(),
        "max_increment" => |d| d.max_increment(),
        "step_size" => |d| d.step_size(),
        "is_moving" => |d| d.is_moving(),
        "absolute" => |d| d.absolute(),
        "temp_comp_available" => |d| d.temp_comp_available(),
        "temp_comp" => |d| d.temp_comp(),
        "set_temp_comp" => |d| d.set_temp_comp(true),
        "temperature" => |d| d.temperature(),
        "move_to" [rep] => |d| d.move_to(6620),
        "halt" => |d| d.halt(),
    ];
    let actual = transcript("focuser", AlpacaFocuser::from_server, members).await;
    check_golden("focuser", &actual);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dome_wire_transcript() {
    let members = members![AlpacaDome;
        "connect" => |d| d.connect(),
        "disconnect" => |d| d.disconnect(),
        "is_connected" => |d| d.is_connected(),
        "name" => |d| d.name(),
        "description" => |d| d.description(),
        "driver_version" => |d| d.driver_version(),
        "driver_info" => |d| d.driver_info(),
        "interface_version" => |d| d.interface_version(),
        "supported_actions" => |d| d.supported_actions(),
        "altitude" => |d| d.altitude(),
        "azimuth" [rep] => |d| d.azimuth(),
        "at_home" => |d| d.at_home(),
        "at_park" => |d| d.at_park(),
        "shutter_status" [rep] => |d| d.shutter_status(),
        "slewing" => |d| d.slewing(),
        "slaved" => |d| d.slaved(),
        "set_slaved" => |d| d.set_slaved(true),
        "can_find_home" => |d| d.can_find_home(),
        "can_park" => |d| d.can_park(),
        "can_set_altitude" => |d| d.can_set_altitude(),
        "can_set_azimuth" => |d| d.can_set_azimuth(),
        "can_set_shutter" => |d| d.can_set_shutter(),
        "can_slave" => |d| d.can_slave(),
        "can_sync_azimuth" => |d| d.can_sync_azimuth(),
        "abort_slew" => |d| d.abort_slew(),
        "close_shutter" [rep] => |d| d.close_shutter(),
        "find_home" [rep] => |d| d.find_home(),
        "open_shutter" => |d| d.open_shutter(),
        "park" => |d| d.park(),
        "set_park" => |d| d.set_park(),
        "slew_to_altitude" => |d| d.slew_to_altitude(45.5),
        "slew_to_azimuth" => |d| d.slew_to_azimuth(270.0),
        "sync_to_azimuth" => |d| d.sync_to_azimuth(123.456),
        "get_status" [par] => |d| d.get_status(),
    ];
    let actual = transcript("dome", AlpacaDome::from_server, members).await;
    check_golden("dome", &actual);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn telescope_wire_transcript() {
    let members = members![AlpacaTelescope;
        "connect" => |d| d.connect(),
        "disconnect" => |d| d.disconnect(),
        "is_connected" => |d| d.is_connected(),
        "validate_connection" => |d| d.validate_connection(),
        "heartbeat" => |d| async move { d.heartbeat().await.map(|_| "<ms>") },
        "name" => |d| d.name(),
        "description" => |d| d.description(),
        "driver_version" => |d| d.driver_version(),
        "driver_info" => |d| d.driver_info(),
        "interface_version" => |d| d.interface_version(),
        "supported_actions" => |d| d.supported_actions(),
        "alignment_mode" => |d| d.alignment_mode(),
        "aperture_area" => |d| d.aperture_area(),
        "aperture_diameter" => |d| d.aperture_diameter(),
        "focal_length" => |d| d.focal_length(),
        "equatorial_system" => |d| d.equatorial_system(),
        "right_ascension" [rep] => |d| d.right_ascension(),
        "declination" => |d| d.declination(),
        "altitude" => |d| d.altitude(),
        "azimuth" => |d| d.azimuth(),
        "sidereal_time" => |d| d.sidereal_time(),
        "utc_date" => |d| d.utc_date(),
        "target_right_ascension" => |d| d.target_right_ascension(),
        "set_target_right_ascension" => |d| d.set_target_right_ascension(5.123456789),
        "target_declination" => |d| d.target_declination(),
        "set_target_declination" => |d| d.set_target_declination(-12.5),
        "slewing" => |d| d.slewing(),
        "tracking" => |d| d.tracking(),
        "set_tracking(true)" [rep] => |d| d.set_tracking(true),
        "set_tracking(false)" => |d| d.set_tracking(false),
        "tracking_rate" => |d| d.tracking_rate(),
        "set_tracking_rate" => |d| d.set_tracking_rate(DriveRate::Lunar),
        "at_home" => |d| d.at_home(),
        "at_park" => |d| d.at_park(),
        "side_of_pier" [rep] => |d| d.side_of_pier(),
        "set_side_of_pier(west)" => |d| d.set_side_of_pier(PierSide::West),
        "set_side_of_pier(unknown)" => |d| d.set_side_of_pier(PierSide::Unknown),
        "site_latitude" => |d| d.site_latitude(),
        "set_site_latitude" => |d| d.set_site_latitude(40.5),
        "site_longitude" => |d| d.site_longitude(),
        "set_site_longitude" => |d| d.set_site_longitude(-105.25),
        "site_elevation" => |d| d.site_elevation(),
        "set_site_elevation" => |d| d.set_site_elevation(1600.0),
        "can_find_home" => |d| d.can_find_home(),
        "can_park" => |d| d.can_park(),
        "can_unpark" => |d| d.can_unpark(),
        "can_set_park" => |d| d.can_set_park(),
        "can_slew" => |d| d.can_slew(),
        "can_slew_async" => |d| d.can_slew_async(),
        "can_slew_alt_az" => |d| d.can_slew_alt_az(),
        "can_slew_alt_az_async" => |d| d.can_slew_alt_az_async(),
        "can_sync" => |d| d.can_sync(),
        "can_sync_alt_az" => |d| d.can_sync_alt_az(),
        "can_set_tracking" => |d| d.can_set_tracking(),
        "can_pulse_guide" => |d| d.can_pulse_guide(),
        "can_set_guide_rates" => |d| d.can_set_guide_rates(),
        "can_set_right_ascension_rate" => |d| d.can_set_right_ascension_rate(),
        "tracking_rates" => |d| d.tracking_rates(),
        "axis_rates" => |d| d.axis_rates(TelescopeAxis::Secondary),
        "axis_rates_for_axis" => |d| d.axis_rates_for_axis(0),
        "can_set_declination_rate" => |d| d.can_set_declination_rate(),
        "can_move_axis" [rep] => |d| d.can_move_axis(1),
        "guide_rate_right_ascension" => |d| d.guide_rate_right_ascension(),
        "set_guide_rate_right_ascension" => |d| d.set_guide_rate_right_ascension(0.0025),
        "guide_rate_declination" => |d| d.guide_rate_declination(),
        "set_guide_rate_declination" => |d| d.set_guide_rate_declination(0.00125),
        "is_pulse_guiding" => |d| d.is_pulse_guiding(),
        "abort_slew" [rep] => |d| d.abort_slew(),
        "find_home" => |d| d.find_home(),
        "park" [rep] => |d| d.park(),
        "unpark" [rep] => |d| d.unpark(),
        "set_park" => |d| d.set_park(),
        "slew_to_coordinates" => |d| d.slew_to_coordinates(5.5, -12.25),
        "slew_to_coordinates_async" [rep] => |d| d.slew_to_coordinates_async(23.999, 89.5),
        "slew_to_target" => |d| d.slew_to_target(),
        "slew_to_target_async" => |d| d.slew_to_target_async(),
        "slew_to_alt_az" => |d| d.slew_to_alt_az(45.5, 180.25),
        "slew_to_alt_az_async" => |d| d.slew_to_alt_az_async(45.5, 180.25),
        "sync_to_coordinates" [rep] => |d| d.sync_to_coordinates(5.5, -12.25),
        "sync_to_target" => |d| d.sync_to_target(),
        "sync_to_alt_az" => |d| d.sync_to_alt_az(45.5, 180.25),
        "pulse_guide" [rep] => |d| d.pulse_guide(2, 750),
        "move_axis" [rep] => |d| d.move_axis(0, 1.0),
        "move_axis(stop)" => |d| d.move_axis(1, 0.0),
        "move_axis(negative)" => |d| d.move_axis(1, -0.5),
        "destination_side_of_pier" => |d| d.destination_side_of_pier(5.5, -12.25),
        "get_status" [par] => |d| d.get_status(),
        "get_capabilities" [par] => |d| d.get_capabilities(),
        "get_site_info" [par] => |d| d.get_site_info(),
        "get_optics_info" [par] => |d| d.get_optics_info(),
        "get_full_status" [par] => |d| d.get_full_status(),
    ];
    let actual = transcript("telescope", AlpacaTelescope::from_server, members).await;
    check_golden("telescope", &actual);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn camera_wire_transcript() {
    let members = members![AlpacaCamera;
        "connect" => |d| d.connect(),
        "disconnect" => |d| d.disconnect(),
        "is_connected" => |d| d.is_connected(),
        "validate_connection" => |d| d.validate_connection(),
        "heartbeat" => |d| async move { d.heartbeat().await.map(|_| "<ms>") },
        "name" => |d| d.name(),
        "description" => |d| d.description(),
        "driver_version" => |d| d.driver_version(),
        "driver_info" => |d| d.driver_info(),
        "interface_version" => |d| d.interface_version(),
        "supported_actions" => |d| d.supported_actions(),
        "camera_x_size" => |d| d.camera_x_size(),
        "camera_y_size" => |d| d.camera_y_size(),
        "pixel_size_x" => |d| d.pixel_size_x(),
        "pixel_size_y" => |d| d.pixel_size_y(),
        "max_adu" => |d| d.max_adu(),
        "sensor_type" => |d| d.sensor_type(),
        "sensor_name" => |d| d.sensor_name(),
        "max_bin_x" => |d| d.max_bin_x(),
        "max_bin_y" => |d| d.max_bin_y(),
        "bin_x" => |d| d.bin_x(),
        "bin_y" => |d| d.bin_y(),
        "set_bin_x" => |d| d.set_bin_x(2),
        "set_bin_y" => |d| d.set_bin_y(2),
        "can_set_ccd_temperature" => |d| d.can_set_ccd_temperature(),
        "ccd_temperature" [rep] => |d| d.ccd_temperature(),
        "set_ccd_temperature" [rep] => |d| d.set_ccd_temperature(-10.0),
        "set_ccd_temperature(fraction)" => |d| d.set_ccd_temperature(-12.5),
        "cooler_on" => |d| d.cooler_on(),
        "set_cooler_on" => |d| d.set_cooler_on(true),
        "cooler_power" => |d| d.cooler_power(),
        "heat_sink_temperature" => |d| d.heat_sink_temperature(),
        "can_get_cooler_power" => |d| d.can_get_cooler_power(),
        "gain" [rep] => |d| d.gain(),
        "set_gain" [rep] => |d| d.set_gain(139),
        "gain_min" => |d| d.gain_min(),
        "gain_max" => |d| d.gain_max(),
        "offset" => |d| d.offset(),
        "set_offset" => |d| d.set_offset(21),
        "offset_min" => |d| d.offset_min(),
        "offset_max" => |d| d.offset_max(),
        "bayer_offset_x" => |d| d.bayer_offset_x(),
        "bayer_offset_y" => |d| d.bayer_offset_y(),
        "camera_state" [rep] => |d| d.camera_state(),
        "image_ready" => |d| d.image_ready(),
        "is_pulse_guiding" => |d| d.is_pulse_guiding(),
        "percent_completed" => |d| d.percent_completed(),
        "start_exposure(light)" [rep] => |d| d.start_exposure(120.0, true),
        "start_exposure(dark)" => |d| d.start_exposure(0.001, false),
        "abort_exposure" => |d| d.abort_exposure(),
        "stop_exposure" => |d| d.stop_exposure(),
        "readout_mode" => |d| d.readout_mode(),
        "set_readout_mode" => |d| d.set_readout_mode(1),
        "readout_modes" => |d| d.readout_modes(),
        "start_x" => |d| d.start_x(),
        "start_y" => |d| d.start_y(),
        "num_x" => |d| d.num_x(),
        "num_y" => |d| d.num_y(),
        "set_start_x" => |d| d.set_start_x(8),
        "set_start_y" => |d| d.set_start_y(16),
        "set_num_x" => |d| d.set_num_x(4656),
        "set_num_y" => |d| d.set_num_y(3520),
        "last_exposure_start_time" => |d| d.last_exposure_start_time(),
        "last_exposure_duration" => |d| d.last_exposure_duration(),
        "can_abort_exposure" => |d| d.can_abort_exposure(),
        "can_stop_exposure" => |d| d.can_stop_exposure(),
        "can_asymmetric_bin" => |d| d.can_asymmetric_bin(),
        "can_pulse_guide" => |d| d.can_pulse_guide(),
        "can_fast_readout" => |d| d.can_fast_readout(),
        "has_shutter" => |d| d.has_shutter(),
        "image_array" => |d| d.image_array(),
        "pulse_guide" => |d| d.pulse_guide(3, 500),
        "download_image_data" [rep] => |d| d.download_image_data(),
        "download_image_array_full" => |d| async move {
            d.download_image_array_full().await.map(|image| {
                (image.width, image.height, image.planes, image.pixels, image.element_type)
            })
        },
        "get_status" [par] => |d| d.get_status(),
        "get_capabilities" [par] => |d| d.get_capabilities(),
        "get_sensor_info" [par] => |d| d.get_sensor_info(),
        "get_subframe" [par] => |d| d.get_subframe(),
        "get_full_status" [par] => |d| d.get_full_status(),
    ];
    let actual = transcript("camera", AlpacaCamera::from_server, members).await;
    check_golden("camera", &actual);
}
