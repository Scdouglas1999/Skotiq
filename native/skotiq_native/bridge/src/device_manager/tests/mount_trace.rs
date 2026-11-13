//! What each mount operation sends to the device, per protocol, against a
//! recorded trace.
//!
//! One script of every mount operation runs against a fake Alpaca telescope,
//! a fake vendor driver and (on Windows) a fake ASCOM worker. The trace is the
//! commands the device saw, in order, under the operation that sent them, with
//! the operation's answer. Coordinates are printed to one decimal: a J2000
//! target becomes a different of-date position every day.
//! `SKOTIQ_MOUNT_TRACE=update` rewrites the files in
//! `golden/`; record them only on a commit whose mount behavior is the
//! reference.

use super::*;
use crate::device::{DriverType, MountSite, MountStatus, MountTimeInfo};
use crate::device_manager::tests::mount_home::register_mount;
use std::sync::Mutex as StdMutex;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

type Trace = Arc<StdMutex<Vec<String>>>;

fn push(trace: &Trace, line: impl Into<String>) {
    trace.lock().expect("lock trace").push(line.into());
}

fn answer<T: std::fmt::Debug, E: std::fmt::Display>(result: Result<T, E>) -> String {
    match result {
        Ok(value) => format!("< ok {value:?}"),
        Err(error) => format!("< err {error}"),
    }
}

fn status_line(status: MountStatus) -> String {
    format!(
        "tracking={} slewing={} parked={} at_home={:?} pier={:?} ra={:.1} dec={:.1} alt={:?} az={:?} \
         lst={:?} rate={:?} can_park={} can_slew={} can_sync={} can_pulse={} can_rate={}",
        status.tracking,
        status.slewing,
        status.parked,
        status.at_home,
        status.side_of_pier,
        status.right_ascension,
        status.declination,
        status.altitude,
        status.azimuth,
        status.sidereal_time,
        status.tracking_rate,
        status.can_park,
        status.can_slew,
        status.can_sync,
        status.can_pulse_guide,
        status.can_set_tracking_rate,
    )
}

/// Every mount operation once, in an order a night uses them. The mount starts
/// parked, of date, at RA 5.5 h / Dec 22 degrees.
async fn drive(manager: &DeviceManager, id: &str, driver_type: DriverType, trace: &Trace) {
    macro_rules! op {
        ($name:expr, $call:expr) => {{
            push(trace, format!("> {}", $name));
            let result = $call.await;
            push(trace, answer(result));
        }};
    }
    macro_rules! status {
        () => {{
            push(trace, "> status");
            let result = manager.mount_get_status(id).await.map(status_line);
            push(trace, answer(result));
        }};
    }

    op!(
        "heartbeat",
        manager.perform_health_check_once(id, &DeviceType::Mount, &driver_type)
    );
    op!("site_capabilities", manager.mount_site_capabilities(id));
    op!("get_site", manager.mount_get_site(id));
    op!("get_time", manager.mount_get_time(id));
    status!();
    op!("coordinates", manager.mount_get_coordinates(id));
    op!("can_park", manager.mount_can_park(id));
    op!("can_set_park", manager.mount_can_set_park(id));
    op!("can_find_home", manager.mount_can_find_home(id));
    op!("unpark", manager.mount_unpark(id));
    op!("set_tracking off", manager.mount_set_tracking(id, false));
    op!("tracking_rate", manager.mount_get_tracking_rate(id));
    op!(
        "set_tracking_rate lunar",
        manager.mount_set_tracking_rate(id, 1)
    );
    op!("slew 6.25h +35", manager.mount_slew(id, 6.25, 35.0));
    status!();
    op!("abort", manager.mount_abort(id));
    op!("sync 6.26h +35.05", manager.mount_sync(id, 6.26, 35.05));
    op!(
        "pulse north 60 ms",
        manager.mount_pulse_guide(id, "north".to_string(), 60)
    );
    op!(
        "pulse west 60 ms",
        manager.mount_pulse_guide(id, "west".to_string(), 60)
    );
    op!("move_axis 0 at 1", manager.mount_move_axis(id, 0, 1.0));
    op!("move_axis 0 at 0", manager.mount_move_axis(id, 0, 0.0));
    op!("move_axis 1 at -1", manager.mount_move_axis(id, 1, -1.0));
    op!("stop", manager.mount_stop(id));
    op!(
        "slew_alt_az 50 120",
        manager.mount_slew_alt_az(id, 50.0, 120.0)
    );
    op!("find_home", manager.mount_find_home(id));
    op!(
        "set_site",
        manager.mount_set_site(
            id,
            MountSite {
                latitude_deg: 41.5,
                longitude_deg: -74.25,
                elevation_m: Some(120.0),
            },
        )
    );
    op!(
        "set_time",
        manager.mount_set_time(
            id,
            MountTimeInfo {
                utc_unix_seconds: 1_794_000_000,
                utc_offset_hours: -5.0,
            },
        )
    );
    op!("set_park", manager.mount_set_park(id));
    op!("park", manager.mount_park(id));
    status!();
    op!("disconnect", manager.disconnect_device(id));
    status!();
}

/// Sorts each run of consecutive device reads (lines starting `  GET`): reads
/// an operation issues together reach the device in no fixed order.
fn settle(lines: Vec<String>) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut reads: Vec<String> = Vec::new();
    for line in lines {
        if line.starts_with("  GET") {
            reads.push(line);
            continue;
        }
        reads.sort();
        out.append(&mut reads);
        out.push(line);
    }
    reads.sort();
    out.append(&mut reads);
    out.join("\n") + "\n"
}

fn check(name: &str, golden: &str, trace: &Trace) {
    let recorded = settle(trace.lock().expect("lock trace").clone());
    if std::env::var("SKOTIQ_MOUNT_TRACE").as_deref() == Ok("update") {
        let path = format!(
            "{}/src/device_manager/tests/golden/{name}",
            env!("CARGO_MANIFEST_DIR")
        );
        std::fs::write(&path, &recorded).expect("write the mount trace");
        println!("wrote {path}");
        return;
    }
    let golden = golden.replace("\r\n", "\n");
    if recorded != golden {
        for (number, (now, then)) in recorded.lines().zip(golden.lines()).enumerate() {
            if now != then {
                panic!(
                    "{name}: line {} differs\n  recorded: {now}\n  golden:   {then}\nfull trace:\n{recorded}",
                    number + 1
                );
            }
        }
        panic!("{name}: the traces differ in length\nfull trace:\n{recorded}");
    }
}

/// A loopback Alpaca telescope that keeps the state the script changes and
/// records every request as `GET member [query]` or `PUT member body`.
async fn fake_alpaca_telescope(trace: Trace) -> String {
    use serde_json::json;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind fake Alpaca telescope");
    let address = listener.local_addr().expect("listener address");
    let mut values: HashMap<&'static str, serde_json::Value> = HashMap::new();
    for member in [
        "connected",
        "atpark",
        "canpark",
        "canunpark",
        "cansetpark",
        "canfindhome",
        "cansettracking",
        "canslew",
        "canslewasync",
        "canslewaltaz",
        "canslewaltazasync",
        "cansync",
        "cansyncaltaz",
        "canpulseguide",
        "cansetguiderates",
        "cansetrightascensionrate",
        "cansetdeclinationrate",
        "cansetpierside",
        "canmoveaxis",
    ] {
        values.insert(member, json!(true));
    }
    for member in ["tracking", "slewing", "athome", "ispulseguiding"] {
        values.insert(member, json!(false));
    }
    values.insert("rightascension", json!(5.5));
    values.insert("declination", json!(22.0));
    values.insert("altitude", json!(45.0));
    values.insert("azimuth", json!(180.0));
    values.insert("siderealtime", json!(5.0));
    values.insert("sideofpier", json!(0));
    values.insert("trackingrate", json!(0));
    values.insert("trackingrates", json!([0, 1, 2]));
    values.insert("sitelatitude", json!(40.0));
    values.insert("sitelongitude", json!(-75.0));
    values.insert("siteelevation", json!(100.0));
    values.insert("utcdate", json!("2026-11-12T03:00:00.0000000Z"));
    values.insert("equatorialsystem", json!(1));
    values.insert("alignmentmode", json!(2));
    values.insert("interfaceversion", json!(4));
    values.insert("axisrates", json!([{ "Minimum": 0.0, "Maximum": 4.0 }]));
    let values = Arc::new(StdMutex::new(values));
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            let (values, trace) = (Arc::clone(&values), Arc::clone(&trace));
            tokio::spawn(async move {
                let request = read_request(&mut socket).await;
                let mut words = request.split_whitespace();
                let method = words.next().unwrap_or_default().to_string();
                let target = words.next().unwrap_or_default().to_string();
                let (path, query) = target.split_once('?').unwrap_or((&target, ""));
                let member = path.rsplit('/').next().unwrap_or_default().to_string();
                let own = |pairs: &str| {
                    pairs
                        .split('&')
                        .filter(|pair| {
                            !pair.is_empty()
                                && !pair.to_ascii_lowercase().starts_with("clientid=")
                                && !pair
                                    .to_ascii_lowercase()
                                    .starts_with("clienttransactionid=")
                        })
                        .collect::<Vec<_>>()
                        .join("&")
                };
                let mut reply = json!({
                    "ClientTransactionID": 0, "ServerTransactionID": 1,
                    "ErrorNumber": 0, "ErrorMessage": "",
                });
                if method == "PUT" {
                    let body = own(request.split("\r\n\r\n").nth(1).unwrap_or_default());
                    push(
                        &trace,
                        format!("  PUT {member} {body}").trim_end().to_string(),
                    );
                    let field = |name: &str| {
                        body.split('&').find_map(|pair| {
                            let (key, value) = pair.split_once('=')?;
                            key.eq_ignore_ascii_case(name).then(|| value.to_string())
                        })
                    };
                    let number = |name: &str| field(name).and_then(|v| v.parse::<f64>().ok());
                    let mut values = values.lock().expect("lock values");
                    match member.as_str() {
                        "tracking" => {
                            let on =
                                field("Tracking").is_some_and(|v| v.eq_ignore_ascii_case("true"));
                            values.insert("tracking", json!(on));
                        }
                        "park" => {
                            values.insert("atpark", json!(true));
                            values.insert("tracking", json!(false));
                        }
                        "unpark" => {
                            values.insert("atpark", json!(false));
                        }
                        "slewtocoordinatesasync" | "slewtocoordinates" | "synctocoordinates" => {
                            if let (Some(ra), Some(dec)) =
                                (number("RightAscension"), number("Declination"))
                            {
                                let last = trace.lock().expect("lock trace").pop();
                                debug_assert!(last.is_some());
                                push(&trace, format!("  PUT {member} RightAscension={ra:.1}&Declination={dec:.1}"));
                                values.insert("rightascension", json!(ra));
                                values.insert("declination", json!(dec));
                            }
                        }
                        "trackingrate" => {
                            if let Some(rate) = number("TrackingRate") {
                                values.insert("trackingrate", json!(rate as i64));
                            }
                        }
                        "connected" => {
                            let on =
                                field("Connected").is_some_and(|v| v.eq_ignore_ascii_case("true"));
                            values.insert("connected", json!(on));
                        }
                        _ => {}
                    }
                } else {
                    push(
                        &trace,
                        format!("  GET {member} {}", own(query))
                            .trim_end()
                            .to_string(),
                    );
                    match values.lock().expect("lock values").get(member.as_str()) {
                        Some(value) => reply["Value"] = value.clone(),
                        None => {
                            reply["ErrorNumber"] = json!(0x400);
                            reply["ErrorMessage"] = json!(format!("{member} not implemented"));
                        }
                    }
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
    format!("http://{address}")
}

async fn read_request(socket: &mut tokio::net::TcpStream) -> String {
    let mut bytes = Vec::new();
    let mut chunk = [0_u8; 4096];
    while let Ok(read) = socket.read(&mut chunk).await {
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_alpaca_mount_is_sent_the_recorded_commands() {
    let trace: Trace = Default::default();
    let base_url = fake_alpaca_telescope(Arc::clone(&trace)).await;
    let manager = build_device_manager();
    let id = "alpaca:mount-trace";
    register_mount(&manager, id, DriverType::Alpaca).await;
    install_alpaca_mount(&manager, id, &base_url).await;
    drive(&manager, id, DriverType::Alpaca, &trace).await;
    check(
        "mount_trace_alpaca.txt",
        include_str!("golden/mount_trace_alpaca.txt"),
        &trace,
    );
}

/// A vendor mount driver that records every call and keeps the state the
/// script changes.
struct TraceMount {
    trace: Trace,
    tracking: bool,
    parked: bool,
    position: (f64, f64),
    rate: skotiq_device::TrackingRate,
}

impl std::fmt::Debug for TraceMount {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("TraceMount")
    }
}

impl TraceMount {
    fn saw(&self, call: impl Into<String>) {
        push(&self.trace, format!("  {}", call.into()));
    }
}

#[async_trait::async_trait]
impl skotiq_device::DeviceDriver for TraceMount {
    fn id(&self) -> &str {
        "native:trace:mount"
    }
    fn name(&self) -> &str {
        "Trace Mount"
    }
    fn vendor(&self) -> skotiq_device::Vendor {
        skotiq_device::Vendor::Zwo
    }
    fn serial_number(&self) -> Option<String> {
        None
    }
    fn is_connected(&self) -> bool {
        self.saw("is_connected");
        true
    }
    async fn connect(&mut self) -> Result<(), skotiq_device::DriverError> {
        self.saw("connect");
        Ok(())
    }
    async fn disconnect(&mut self) -> Result<(), skotiq_device::DriverError> {
        self.saw("disconnect");
        Ok(())
    }
}

#[async_trait::async_trait]
impl skotiq_device::MountDriver for TraceMount {
    async fn slew_to_coordinates(
        &mut self,
        ra: f64,
        dec: f64,
    ) -> Result<(), skotiq_device::DriverError> {
        self.saw(format!("slew_to_coordinates {ra:.1} {dec:.1}"));
        self.position = (ra, dec);
        Ok(())
    }
    async fn get_coordinates(&self) -> Result<(f64, f64), skotiq_device::DriverError> {
        self.saw("get_coordinates");
        Ok(self.position)
    }
    async fn sync_to_coordinates(
        &mut self,
        ra: f64,
        dec: f64,
    ) -> Result<(), skotiq_device::DriverError> {
        self.saw(format!("sync_to_coordinates {ra:.1} {dec:.1}"));
        self.position = (ra, dec);
        Ok(())
    }
    async fn park(&mut self) -> Result<(), skotiq_device::DriverError> {
        self.saw("park");
        self.parked = true;
        self.tracking = false;
        Ok(())
    }
    async fn unpark(&mut self) -> Result<(), skotiq_device::DriverError> {
        self.saw("unpark");
        self.parked = false;
        Ok(())
    }
    async fn is_slewing(&self) -> Result<bool, skotiq_device::DriverError> {
        self.saw("is_slewing");
        Ok(false)
    }
    async fn is_parked(&self) -> Result<bool, skotiq_device::DriverError> {
        self.saw("is_parked");
        Ok(self.parked)
    }
    async fn pulse_guide(
        &mut self,
        direction: skotiq_device::GuideDirection,
        duration_ms: u32,
    ) -> Result<(), skotiq_device::DriverError> {
        self.saw(format!("pulse_guide {direction:?} {duration_ms}"));
        Ok(())
    }
    async fn abort_slew(&mut self) -> Result<(), skotiq_device::DriverError> {
        self.saw("abort_slew");
        Ok(())
    }
    async fn set_tracking(&mut self, enabled: bool) -> Result<(), skotiq_device::DriverError> {
        self.saw(format!("set_tracking {enabled}"));
        self.tracking = enabled;
        Ok(())
    }
    async fn get_tracking(&self) -> Result<bool, skotiq_device::DriverError> {
        self.saw("get_tracking");
        Ok(self.tracking)
    }
    async fn set_tracking_rate(
        &mut self,
        rate: skotiq_device::TrackingRate,
    ) -> Result<(), skotiq_device::DriverError> {
        self.saw(format!("set_tracking_rate {rate:?}"));
        self.rate = rate;
        Ok(())
    }
    async fn get_tracking_rate(
        &self,
    ) -> Result<skotiq_device::TrackingRate, skotiq_device::DriverError> {
        self.saw("get_tracking_rate");
        Ok(self.rate)
    }
    async fn can_slew(&self) -> bool {
        self.saw("can_slew");
        true
    }
    async fn can_sync(&self) -> bool {
        self.saw("can_sync");
        true
    }
    async fn can_pulse_guide(&self) -> bool {
        self.saw("can_pulse_guide");
        true
    }
    async fn tracking_rates(&self) -> Vec<skotiq_device::TrackingRate> {
        self.saw("tracking_rates");
        vec![
            skotiq_device::TrackingRate::Sidereal,
            skotiq_device::TrackingRate::Lunar,
        ]
    }
    async fn get_side_of_pier(
        &self,
    ) -> Result<skotiq_device::PierSide, skotiq_device::DriverError> {
        self.saw("get_side_of_pier");
        Ok(skotiq_device::PierSide::East)
    }
    async fn get_alt_az(&self) -> Result<(f64, f64), skotiq_device::DriverError> {
        self.saw("get_alt_az");
        Ok((45.0, 180.0))
    }
    async fn get_sidereal_time(&self) -> Result<f64, skotiq_device::DriverError> {
        self.saw("get_sidereal_time");
        Ok(5.0)
    }
    async fn get_site(&self) -> Result<skotiq_device::MountSiteInfo, skotiq_device::DriverError> {
        self.saw("get_site");
        Ok(skotiq_device::MountSiteInfo {
            latitude_deg: 40.0,
            longitude_deg: -75.0,
            elevation_m: None,
        })
    }
    async fn set_site(
        &mut self,
        site: skotiq_device::MountSiteInfo,
    ) -> Result<(), skotiq_device::DriverError> {
        self.saw(format!(
            "set_site {:.4} {:.4} {:?}",
            site.latitude_deg, site.longitude_deg, site.elevation_m
        ));
        Ok(())
    }
    async fn get_clock(&self) -> Result<skotiq_device::MountClock, skotiq_device::DriverError> {
        self.saw("get_clock");
        Ok(skotiq_device::MountClock {
            utc_unix_seconds: 1_793_000_000,
            utc_offset_hours: -5.0,
        })
    }
    async fn set_clock(
        &mut self,
        clock: skotiq_device::MountClock,
    ) -> Result<(), skotiq_device::DriverError> {
        self.saw(format!(
            "set_clock {} {}",
            clock.utc_unix_seconds, clock.utc_offset_hours
        ));
        Ok(())
    }
    async fn can_find_home(&self) -> Result<bool, skotiq_device::DriverError> {
        self.saw("can_find_home");
        Ok(true)
    }
    async fn find_home(&mut self) -> Result<(), skotiq_device::DriverError> {
        self.saw("find_home");
        Ok(())
    }
    async fn at_home(&self) -> Result<bool, skotiq_device::DriverError> {
        self.saw("at_home");
        Ok(false)
    }
    async fn can_set_park(&self) -> Result<bool, skotiq_device::DriverError> {
        self.saw("can_set_park");
        Ok(true)
    }
    async fn set_park(&mut self) -> Result<(), skotiq_device::DriverError> {
        self.saw("set_park");
        Ok(())
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_vendor_mount_is_sent_the_recorded_calls() {
    let trace: Trace = Default::default();
    let manager = build_device_manager();
    let id = "native:trace:mount";
    register_mount(&manager, id, DriverType::Native).await;
    install_vendor_mount(
        &manager,
        id,
        Box::new(TraceMount {
            trace: Arc::clone(&trace),
            tracking: false,
            parked: true,
            position: (5.5, 22.0),
            rate: skotiq_device::TrackingRate::Sidereal,
        }),
    )
    .await;
    drive(&manager, id, DriverType::Native, &trace).await;
    check(
        "mount_trace_vendor.txt",
        include_str!("golden/mount_trace_vendor.txt"),
        &trace,
    );
}

/// The ASCOM COM path: the commands the wrapper queues for the STA worker.
#[cfg(windows)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ascom_mount_is_sent_the_recorded_commands() {
    let trace: Trace = Default::default();
    let manager = build_device_manager();
    let id = "ascom:Trace.Telescope";
    register_mount(&manager, id, DriverType::Ascom).await;
    let recorder = Arc::clone(&trace);
    let wrapper =
        crate::ascom_wrapper::mount::test_support::build_recording_mount_wrapper(move |command| {
            push(&recorder, format!("  {command}"))
        });
    install_ascom_mount(&manager, id, wrapper).await;
    drive(&manager, id, DriverType::Ascom, &trace).await;
    check(
        "mount_trace_ascom.txt",
        include_str!("golden/mount_trace_ascom.txt"),
        &trace,
    );
}

async fn install_alpaca_mount(manager: &DeviceManager, id: &str, base_url: &str) {
    manager.hold_alpaca_mount(id, skotiq_alpaca::AlpacaTelescope::from_server(base_url, 0));
}

async fn install_vendor_mount(
    manager: &DeviceManager,
    id: &str,
    mount: Box<dyn skotiq_device::MountDriver + Send + Sync>,
) {
    manager.hold_vendor_mount(id, mount);
}

#[cfg(windows)]
async fn install_ascom_mount(
    manager: &DeviceManager,
    id: &str,
    wrapper: crate::ascom_wrapper::mount::AscomMountWrapper,
) {
    manager.hold_ascom_mount(id, wrapper);
}
