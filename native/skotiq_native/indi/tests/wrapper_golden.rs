//! Golden record of what the INDI device wrappers return and send.
//!
//! Each case calls one public wrapper function against a scripted INDI server
//! on a loopback socket and records the returned value or the error's text,
//! plus every XML line the client sent while the call ran. The bridge shows
//! these error strings to the operator and some callers match on parts of
//! them, so the text is compared byte for byte with `tests/golden/*.txt`.
//!
//! Regenerate the files with `SKOTIQ_INDI_BLESS=1 cargo test -p skotiq_indi
//! --test wrapper_golden` and read the diff before committing it.

use skotiq_indi::{
    IndiCamera, IndiClient, IndiCoverCalibrator, IndiDome, IndiFilterWheel, IndiFocuser, IndiMount,
    IndiRotator, IndiSafetyMonitor, IndiTimeoutConfig,
};
use std::fmt::{Debug, Display, Write as _};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::{Mutex, RwLock};

/// What the server writes back when a line from the client contains the
/// trigger: each step after its own delay in milliseconds.
type Reply = (String, Vec<(u64, String)>);

struct Rig {
    client: Arc<RwLock<IndiClient>>,
    sent: Arc<Mutex<Vec<String>>>,
    marks: AtomicUsize,
    server: tokio::task::JoinHandle<()>,
}

impl Drop for Rig {
    fn drop(&mut self) {
        self.server.abort();
    }
}

fn config() -> IndiTimeoutConfig {
    IndiTimeoutConfig {
        connection_timeout_secs: 5,
        property_timeout_secs: 2,
        property_poll_interval_ms: 20,
        filter_change_timeout_secs: 1,
        ..Default::default()
    }
}

impl Rig {
    async fn start(definitions: String, replies: Vec<Reply>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind the scripted INDI server");
        let port = listener.local_addr().expect("listener address").port();
        let sent = Arc::new(Mutex::new(Vec::new()));
        let server_sent = sent.clone();
        let definitions = format!(
            "{definitions}{}",
            switch_def("_rig", "READY", None, "Ok", "ro", &[("READY", true)])
        );

        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.expect("accept the INDI client");
            let (reader, writer) = socket.into_split();
            let writer = Arc::new(Mutex::new(writer));
            let mut lines = BufReader::new(reader).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                server_sent.lock().await.push(line.clone());
                if line.contains("<getProperties") {
                    let _ = writer.lock().await.write_all(definitions.as_bytes()).await;
                }
                for (trigger, steps) in &replies {
                    if line.contains(trigger.as_str()) {
                        let writer = writer.clone();
                        let steps = steps.clone();
                        tokio::spawn(async move {
                            for (delay_ms, xml) in steps {
                                tokio::time::sleep(Duration::from_millis(delay_ms)).await;
                                let _ = writer.lock().await.write_all(xml.as_bytes()).await;
                            }
                        });
                    }
                }
            }
        });

        let mut client = IndiClient::with_timeout_config("127.0.0.1", Some(port), config());
        client
            .connect()
            .await
            .expect("connect to the scripted server");
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while !client.has_property("_rig", "READY").await {
            assert!(
                tokio::time::Instant::now() < deadline,
                "the scripted server's definitions never arrived"
            );
            tokio::time::sleep(Duration::from_millis(5)).await;
        }

        let rig = Self {
            client: Arc::new(RwLock::new(client)),
            sent,
            marks: AtomicUsize::new(0),
            server,
        };
        rig.take_sent().await;
        rig
    }

    /// Everything the client sent since the last call. A marker command is
    /// sent through the same ordered channel and waited for, so nothing the
    /// call under test queued is still in flight when this returns.
    async fn take_sent(&self) -> Vec<String> {
        let mark = format!("_mark{}", self.marks.fetch_add(1, Ordering::SeqCst));
        self.client
            .write()
            .await
            .enable_blob(&mark)
            .await
            .expect("send the marker");
        let needle = format!("device=\"{mark}\"");
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        loop {
            {
                let mut sent = self.sent.lock().await;
                if sent.iter().any(|line| line.contains(&needle)) {
                    return sent
                        .drain(..)
                        .filter(|line| !line.contains("device=\"_mark"))
                        .collect();
                }
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "the marker never reached the scripted server"
            );
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }

    async fn record<T: Debug, E: Display>(
        &self,
        log: &mut String,
        name: &str,
        result: Result<T, E>,
    ) {
        let sent = self.take_sent().await;
        write_case(log, name, result, &sent);
    }
}

fn write_case<T: Debug, E: Display>(
    log: &mut String,
    name: &str,
    result: Result<T, E>,
    sent: &[String],
) {
    writeln!(log, "## {name}").unwrap();
    match result {
        Ok(value) => writeln!(log, "result: Ok({value:?})").unwrap(),
        Err(error) => writeln!(log, "result: Err({error})").unwrap(),
    }
    if sent.is_empty() {
        writeln!(log, "sent: (nothing)").unwrap();
    }
    for line in sent {
        writeln!(log, "sent: {line}").unwrap();
    }
    writeln!(log).unwrap();
}

/// A case on a client that never connected to a server: nothing can be sent.
fn record_offline<T: Debug, E: Display>(log: &mut String, name: &str, result: Result<T, E>) {
    write_case(log, name, result, &["(client never connected)".to_string()]);
}

fn offline_client() -> Arc<RwLock<IndiClient>> {
    Arc::new(RwLock::new(IndiClient::new("127.0.0.1", Some(1))))
}

fn check_golden(name: &str, log: &str) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("golden")
        .join(format!("{name}.txt"));
    if std::env::var_os("SKOTIQ_INDI_BLESS").is_some() {
        std::fs::create_dir_all(path.parent().expect("golden directory"))
            .expect("create golden dir");
        std::fs::write(&path, log).expect("write golden file");
        return;
    }
    let expected =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    assert_eq!(
        log,
        expected,
        "wrapper results or sent XML differ from {}",
        path.display()
    );
}

// Definition and update builders for the scripted server.

type Number<'a> = (&'a str, f64, Option<(f64, f64)>);

fn number_def(
    device: &str,
    property: &str,
    state: &str,
    perm: &str,
    elements: &[Number],
) -> String {
    let mut xml = format!(
        "<defNumberVector device=\"{device}\" name=\"{property}\" state=\"{state}\" perm=\"{perm}\">"
    );
    for (name, value, limits) in elements {
        match limits {
            Some((min, max)) => write!(
                xml,
                "<defNumber name=\"{name}\" min=\"{min}\" max=\"{max}\">{value}</defNumber>"
            ),
            None => write!(xml, "<defNumber name=\"{name}\">{value}</defNumber>"),
        }
        .unwrap();
    }
    xml.push_str("</defNumberVector>\n");
    xml
}

fn switch_def(
    device: &str,
    property: &str,
    rule: Option<&str>,
    state: &str,
    perm: &str,
    elements: &[(&str, bool)],
) -> String {
    let rule = rule.map(|r| format!(" rule=\"{r}\"")).unwrap_or_default();
    let mut xml = format!(
        "<defSwitchVector device=\"{device}\" name=\"{property}\" state=\"{state}\" perm=\"{perm}\"{rule}>"
    );
    for (name, on) in elements {
        let value = if *on { "On" } else { "Off" };
        write!(xml, "<defSwitch name=\"{name}\">{value}</defSwitch>").unwrap();
    }
    xml.push_str("</defSwitchVector>\n");
    xml
}

fn light_def(device: &str, property: &str, elements: &[(&str, &str)]) -> String {
    let mut xml = format!("<defLightVector device=\"{device}\" name=\"{property}\" state=\"Ok\">");
    for (name, value) in elements {
        write!(xml, "<defLight name=\"{name}\">{value}</defLight>").unwrap();
    }
    xml.push_str("</defLightVector>\n");
    xml
}

fn text_def(device: &str, property: &str, elements: &[(&str, &str)]) -> String {
    let mut xml =
        format!("<defTextVector device=\"{device}\" name=\"{property}\" state=\"Ok\" perm=\"rw\">");
    for (name, value) in elements {
        write!(xml, "<defText name=\"{name}\">{value}</defText>").unwrap();
    }
    xml.push_str("</defTextVector>\n");
    xml
}

fn connection_def(device: &str) -> String {
    switch_def(
        device,
        "CONNECTION",
        Some("OneOfMany"),
        "Ok",
        "rw",
        &[("CONNECT", true), ("DISCONNECT", false)],
    )
}

fn number_update(device: &str, property: &str, state: &str, elements: &[(&str, f64)]) -> String {
    let mut xml =
        format!("<setNumberVector device=\"{device}\" name=\"{property}\" state=\"{state}\">");
    for (name, value) in elements {
        write!(xml, "<oneNumber name=\"{name}\">{value}</oneNumber>").unwrap();
    }
    xml.push_str("</setNumberVector>\n");
    xml
}

fn switch_update(device: &str, property: &str, state: &str, elements: &[(&str, bool)]) -> String {
    let mut xml =
        format!("<setSwitchVector device=\"{device}\" name=\"{property}\" state=\"{state}\">");
    for (name, on) in elements {
        let value = if *on { "On" } else { "Off" };
        write!(xml, "<oneSwitch name=\"{name}\">{value}</oneSwitch>").unwrap();
    }
    xml.push_str("</setSwitchVector>\n");
    xml
}

fn on_number(device: &str, property: &str) -> String {
    format!("<newNumberVector device=\"{device}\" name=\"{property}\">")
}

fn on_switch(device: &str, property: &str) -> String {
    format!("<newSwitchVector device=\"{device}\" name=\"{property}\">")
}

// Focuser

fn focuser_defs(device: &str) -> String {
    [
        connection_def(device),
        number_def(
            device,
            "ABS_FOCUS_POSITION",
            "Ok",
            "rw",
            &[("FOCUS_ABSOLUTE_POSITION", 5000.0, Some((0.0, 50000.0)))],
        ),
        number_def(
            device,
            "REL_FOCUS_POSITION",
            "Ok",
            "rw",
            &[("FOCUS_RELATIVE_POSITION", 0.0, Some((0.0, 50000.0)))],
        ),
        switch_def(
            device,
            "FOCUS_MOTION",
            Some("OneOfMany"),
            "Ok",
            "rw",
            &[("FOCUS_IN", true), ("FOCUS_OUT", false)],
        ),
        number_def(
            device,
            "FOCUS_TEMPERATURE",
            "Ok",
            "ro",
            &[("TEMPERATURE", 12.5, None)],
        ),
    ]
    .concat()
}

fn abs_focus(device: &str, state: &str, position: f64) -> String {
    number_update(
        device,
        "ABS_FOCUS_POSITION",
        state,
        &[("FOCUS_ABSOLUTE_POSITION", position)],
    )
}

fn rel_focus(device: &str, state: &str) -> String {
    number_update(
        device,
        "REL_FOCUS_POSITION",
        state,
        &[("FOCUS_RELATIVE_POSITION", 0.0)],
    )
}

#[tokio::test]
async fn focuser_results_and_sent_xml() {
    let devices = [
        "Focuser",
        "FAbsOk",
        "FAbsBusy",
        "FAbsAlert",
        "FAbsLate",
        "FAbsSilent",
        "FRelOk",
        "FRelOut",
        "FRelBusy",
        "FRelAlert",
    ];
    let mut definitions: String = devices.iter().map(|d| focuser_defs(d)).collect();
    definitions.push_str(&connection_def("Bare"));
    let replies = vec![
        (
            on_number("FAbsOk", "ABS_FOCUS_POSITION"),
            vec![
                (0, abs_focus("FAbsOk", "Busy", 5040.0)),
                (100, abs_focus("FAbsOk", "Ok", 6000.0)),
            ],
        ),
        (
            on_number("FAbsBusy", "ABS_FOCUS_POSITION"),
            vec![(0, abs_focus("FAbsBusy", "Busy", 5040.0))],
        ),
        (
            on_number("FAbsAlert", "ABS_FOCUS_POSITION"),
            vec![(0, abs_focus("FAbsAlert", "Alert", 5000.0))],
        ),
        (
            on_number("FAbsLate", "ABS_FOCUS_POSITION"),
            vec![
                (0, abs_focus("FAbsLate", "Busy", 5040.0)),
                (800, abs_focus("FAbsLate", "Alert", 5100.0)),
            ],
        ),
        (
            on_number("FRelOk", "REL_FOCUS_POSITION"),
            vec![
                (0, rel_focus("FRelOk", "Busy")),
                (100, rel_focus("FRelOk", "Ok")),
            ],
        ),
        (
            on_number("FRelOut", "REL_FOCUS_POSITION"),
            vec![(0, rel_focus("FRelOut", "Ok"))],
        ),
        (
            on_number("FRelBusy", "REL_FOCUS_POSITION"),
            vec![(0, rel_focus("FRelBusy", "Busy"))],
        ),
        (
            on_number("FRelAlert", "REL_FOCUS_POSITION"),
            vec![(0, rel_focus("FRelAlert", "Alert"))],
        ),
    ];
    let rig = Rig::start(definitions, replies).await;
    let focuser = |device: &str| IndiFocuser::new(rig.client.clone(), device);
    let mut log = String::new();
    let wait = Some(Duration::from_secs(5));
    let short = Some(Duration::from_millis(300));

    rig.record(
        &mut log,
        "get_position, published",
        focuser("Focuser").get_position().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_position, not published",
        focuser("Bare").get_position().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_temperature, published",
        focuser("Focuser").get_temperature().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_temperature, not published",
        focuser("Bare").get_temperature().await,
    )
    .await;

    rig.record(
        &mut log,
        "move_to_with_timeout, driver goes Busy then Ok at the target",
        focuser("FAbsOk").move_to_with_timeout(6000, wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to_with_timeout, driver stays Busy past the timeout",
        focuser("FAbsBusy").move_to_with_timeout(6000, short).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to_with_timeout, driver answers Alert",
        focuser("FAbsAlert").move_to_with_timeout(6000, wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to_with_timeout, driver goes Busy then Alert",
        focuser("FAbsLate").move_to_with_timeout(6000, wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to_with_timeout, target beyond the driver's limits",
        focuser("Focuser").move_to_with_timeout(60000, wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to, driver answers Alert",
        focuser("FAbsAlert").move_to(6000).await,
    )
    .await;

    rig.record(
        &mut log,
        "move_relative_with_timeout, inward, driver goes Busy then Ok",
        focuser("FRelOk")
            .move_relative_with_timeout(100, wait)
            .await,
    )
    .await;
    rig.record(
        &mut log,
        "move_relative_with_timeout, outward",
        focuser("FRelOut")
            .move_relative_with_timeout(-50, wait)
            .await,
    )
    .await;
    rig.record(
        &mut log,
        "move_relative_with_timeout, driver stays Busy past the timeout",
        focuser("FRelBusy")
            .move_relative_with_timeout(100, short)
            .await,
    )
    .await;
    rig.record(
        &mut log,
        "move_relative_with_timeout, driver answers Alert",
        focuser("FRelAlert")
            .move_relative_with_timeout(100, wait)
            .await,
    )
    .await;
    // The cases the driver never answers come last: each waits out the
    // answer deadline, and nothing after them depends on a server reply.
    rig.record(
        &mut log,
        "move_to_with_timeout, driver never answers (default timeout)",
        focuser("FAbsSilent").move_to_with_timeout(6000, None).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to, driver never answers",
        focuser("FAbsSilent").move_to(6100).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_relative_with_timeout, no relative property",
        focuser("Bare").move_relative_with_timeout(100, short).await,
    )
    .await;

    let offline = IndiFocuser::new(offline_client(), "Focuser");
    record_offline(
        &mut log,
        "move_to_with_timeout, client not connected",
        offline.move_to_with_timeout(6000, short).await,
    );
    record_offline(
        &mut log,
        "move_relative_with_timeout, client not connected",
        offline.move_relative_with_timeout(100, short).await,
    );
    record_offline(
        &mut log,
        "get_position, client not connected",
        offline.get_position().await,
    );

    check_golden("focuser", &log);
}

// Mount

fn mount_defs(device: &str, coord_state: &str) -> String {
    [
        connection_def(device),
        number_def(
            device,
            "EQUATORIAL_EOD_COORD",
            coord_state,
            "rw",
            &[
                ("RA", 5.5, Some((0.0, 24.0))),
                ("DEC", 20.0, Some((-90.0, 90.0))),
            ],
        ),
        switch_def(
            device,
            "ON_COORD_SET",
            Some("OneOfMany"),
            "Ok",
            "rw",
            &[("SLEW", false), ("TRACK", true), ("SYNC", false)],
        ),
        number_def(
            device,
            "HORIZONTAL_COORD",
            "Ok",
            "rw",
            &[("ALT", 45.0, None), ("AZ", 180.0, None)],
        ),
    ]
    .concat()
}

fn eod(device: &str, state: &str, ra: f64, dec: f64) -> String {
    number_update(
        device,
        "EQUATORIAL_EOD_COORD",
        state,
        &[("RA", ra), ("DEC", dec)],
    )
}

#[tokio::test]
async fn mount_results_and_sent_xml() {
    let definitions = [
        mount_defs("Mount", "Ok"),
        mount_defs("MSlewOk", "Busy"),
        mount_defs("MSlewBusy", "Busy"),
        mount_defs("MSlewAlert", "Alert"),
        mount_defs("MGotoBusy", "Ok"),
        mount_defs("MGotoAlert", "Ok"),
        mount_defs("MGotoThere", "Ok"),
        mount_defs("MGotoSilent", "Ok"),
        connection_def("Bare"),
        number_def(
            "MJ2000RaOnly",
            "EQUATORIAL_COORD",
            "Ok",
            "rw",
            &[("RA", 5.5, None)],
        ),
        number_def(
            "MAltOnly",
            "HORIZONTAL_COORD",
            "Ok",
            "rw",
            &[("ALT", 45.0, None)],
        ),
    ]
    .concat();
    let replies = vec![
        (
            on_number("MSlewOk", "EQUATORIAL_EOD_COORD"),
            vec![(100, eod("MSlewOk", "Ok", 6.0, 30.0))],
        ),
        (
            on_number("MGotoBusy", "EQUATORIAL_EOD_COORD"),
            vec![(0, eod("MGotoBusy", "Busy", 5.5, 20.0))],
        ),
        (
            on_number("MGotoAlert", "EQUATORIAL_EOD_COORD"),
            vec![(0, eod("MGotoAlert", "Alert", 5.5, 20.0))],
        ),
        (
            on_number("MGotoThere", "EQUATORIAL_EOD_COORD"),
            vec![(0, eod("MGotoThere", "Ok", 5.5, 20.0))],
        ),
    ];
    let rig = Rig::start(definitions, replies).await;
    let mount = |device: &str| IndiMount::new(rig.client.clone(), device);
    let mut log = String::new();
    let wait = Some(Duration::from_secs(5));
    let short = Some(Duration::from_millis(300));

    rig.record(
        &mut log,
        "get_coordinates, published",
        mount("Mount").get_coordinates().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_coordinates, nothing published",
        mount("Bare").get_coordinates().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_coordinates, J2000 vector without DEC",
        mount("MJ2000RaOnly").get_coordinates().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_horizontal_coordinates, published",
        mount("Mount").get_horizontal_coordinates().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_horizontal_coordinates, nothing published",
        mount("Bare").get_horizontal_coordinates().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_horizontal_coordinates, ALT without AZ",
        mount("MAltOnly").get_horizontal_coordinates().await,
    )
    .await;

    rig.record(
        &mut log,
        "slew_to_coordinates_with_timeout, Busy then Ok",
        mount("MSlewOk")
            .slew_to_coordinates_with_timeout(6.0, 30.0, wait)
            .await,
    )
    .await;
    rig.record(
        &mut log,
        "slew_to_coordinates_with_timeout, stays Busy past the timeout",
        mount("MSlewBusy")
            .slew_to_coordinates_with_timeout(6.0, 30.0, short)
            .await,
    )
    .await;
    rig.record(
        &mut log,
        "slew_to_coordinates_with_timeout, vector in Alert",
        mount("MSlewAlert")
            .slew_to_coordinates_with_timeout(6.0, 30.0, wait)
            .await,
    )
    .await;
    rig.record(
        &mut log,
        "slew_to_coordinates_with_timeout, RA beyond the driver's limits",
        mount("Mount")
            .slew_to_coordinates_with_timeout(30.0, 20.0, wait)
            .await,
    )
    .await;
    rig.record(
        &mut log,
        "slew_to_coordinates_with_timeout, no ON_COORD_SET (default timeout)",
        mount("MJ2000RaOnly")
            .slew_to_coordinates_with_timeout(6.0, 30.0, None)
            .await,
    )
    .await;

    rig.record(
        &mut log,
        "slew_to_coordinates, driver answers Busy",
        mount("MGotoBusy").slew_to_coordinates(6.0, 30.0).await,
    )
    .await;
    rig.record(
        &mut log,
        "slew_to_coordinates, driver answers Alert",
        mount("MGotoAlert").slew_to_coordinates(6.0, 30.0).await,
    )
    .await;
    rig.record(
        &mut log,
        "slew_to_coordinates, already at the target",
        mount("MGotoThere").slew_to_coordinates(5.5, 20.0).await,
    )
    .await;
    rig.record(
        &mut log,
        "slew_to_coordinates, driver never answers",
        mount("MGotoSilent").slew_to_coordinates(6.0, 30.0).await,
    )
    .await;

    let offline = IndiMount::new(offline_client(), "Mount");
    record_offline(
        &mut log,
        "slew_to_coordinates_with_timeout, client not connected",
        offline
            .slew_to_coordinates_with_timeout(6.0, 30.0, short)
            .await,
    );
    record_offline(
        &mut log,
        "get_coordinates, client not connected",
        offline.get_coordinates().await,
    );

    check_golden("mount", &log);
}

// Filter wheel

fn wheel_defs(device: &str, slot_state: &str, min: f64, names: bool) -> String {
    let mut xml = [
        connection_def(device),
        number_def(
            device,
            "FILTER_SLOT",
            slot_state,
            "rw",
            &[("FILTER_SLOT_VALUE", 2.0, Some((min, min + 4.0)))],
        ),
    ]
    .concat();
    if names {
        xml.push_str(&text_def(
            device,
            "FILTER_NAME",
            &[
                ("FILTER_SLOT_NAME_1", "L"),
                ("FILTER_SLOT_NAME_2", "R"),
                ("FILTER_SLOT_NAME_3", "G"),
                ("FILTER_SLOT_NAME_4", "B"),
                ("FILTER_SLOT_NAME_5", "Ha"),
            ],
        ));
    }
    xml
}

fn slot(device: &str, state: &str, value: f64) -> String {
    number_update(
        device,
        "FILTER_SLOT",
        state,
        &[("FILTER_SLOT_VALUE", value)],
    )
}

#[tokio::test]
async fn filter_wheel_results_and_sent_xml() {
    let definitions = [
        wheel_defs("Wheel", "Ok", 1.0, true),
        wheel_defs("WZero", "Ok", 0.0, false),
        wheel_defs("WMoveOk", "Ok", 1.0, true),
        wheel_defs("WMoveAlert", "Ok", 1.0, true),
        wheel_defs("WMoveStuck", "Ok", 1.0, true),
        connection_def("Bare"),
    ]
    .concat();
    let replies = vec![
        (
            on_number("WMoveOk", "FILTER_SLOT"),
            vec![
                (0, slot("WMoveOk", "Busy", 2.0)),
                (100, slot("WMoveOk", "Ok", 4.0)),
            ],
        ),
        (
            on_number("WMoveAlert", "FILTER_SLOT"),
            vec![(0, slot("WMoveAlert", "Alert", 2.0))],
        ),
        (
            on_number("WMoveStuck", "FILTER_SLOT"),
            vec![(0, slot("WMoveStuck", "Busy", 2.0))],
        ),
    ];
    let rig = Rig::start(definitions, replies).await;
    let wheel = |device: &str| IndiFilterWheel::new(rig.client.clone(), device);
    let mut log = String::new();

    rig.record(
        &mut log,
        "get_position, one-based driver",
        wheel("Wheel").get_position().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_position, zero-based driver",
        wheel("WZero").get_position().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_position, not published",
        wheel("Bare").get_position().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_names, published",
        wheel("Wheel").get_names().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_names, synthesized from the slot range",
        wheel("WZero").get_names().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_names, nothing published",
        wheel("Bare").get_names().await,
    )
    .await;

    rig.record(
        &mut log,
        "move_to_position, Busy then Ok at the slot",
        wheel("WMoveOk").move_to_position(3).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to_position, already at the slot",
        wheel("Wheel").move_to_position(1).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to_position, zero-based driver",
        wheel("WZero").move_to_position(2).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to_position, driver answers Alert",
        wheel("WMoveAlert").move_to_position(3).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to_position, never reaches the slot",
        wheel("WMoveStuck").move_to_position(3).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to_position, slot beyond the driver's limits",
        wheel("Wheel").move_to_position(9).await,
    )
    .await;

    let offline = IndiFilterWheel::new(offline_client(), "Wheel");
    record_offline(
        &mut log,
        "move_to_position, client not connected",
        offline.move_to_position(3).await,
    );
    record_offline(
        &mut log,
        "get_position, client not connected",
        offline.get_position().await,
    );
    record_offline(
        &mut log,
        "get_names, client not connected",
        offline.get_names().await,
    );

    check_golden("filter_wheel", &log);
}

/// The entry points the filter wheel had beside `move_to_position`, recorded
/// so merging them can be checked against what they sent and returned.
#[tokio::test]
async fn filter_wheel_other_entry_points() {
    let definitions = [
        wheel_defs("Wheel", "Ok", 1.0, true),
        wheel_defs("WZero", "Ok", 0.0, false),
        wheel_defs("WSlotOk", "Busy", 1.0, true),
        wheel_defs("WSlotBusy", "Busy", 1.0, true),
        wheel_defs("WSlotAlert", "Alert", 1.0, true),
        connection_def("Bare"),
    ]
    .concat();
    let replies = vec![(
        on_number("WSlotOk", "FILTER_SLOT"),
        vec![(100, slot("WSlotOk", "Ok", 4.0))],
    )];
    let rig = Rig::start(definitions, replies).await;
    let wheel = |device: &str| IndiFilterWheel::new(rig.client.clone(), device);
    let mut log = String::new();
    let wait = Some(Duration::from_secs(5));
    let short = Some(Duration::from_millis(300));

    rig.record(
        &mut log,
        "get_slot, published",
        wheel("Wheel").get_slot().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_slot, not published",
        wheel("Bare").get_slot().await,
    )
    .await;
    rig.record(
        &mut log,
        "set_position, one-based driver",
        wheel("Wheel").set_position(3).await,
    )
    .await;
    rig.record(
        &mut log,
        "set_position, zero-based driver",
        wheel("WZero").set_position(3).await,
    )
    .await;
    rig.record(&mut log, "set_slot", wheel("Wheel").set_slot(4).await)
        .await;
    rig.record(
        &mut log,
        "set_slot_with_timeout, Busy then Ok",
        wheel("WSlotOk").set_slot_with_timeout(4, wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "set_slot_with_timeout, stays Busy past the timeout",
        wheel("WSlotBusy").set_slot_with_timeout(4, short).await,
    )
    .await;
    rig.record(
        &mut log,
        "set_slot_with_timeout, property in Alert",
        wheel("WSlotAlert").set_slot_with_timeout(4, wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "set_slot_with_timeout, returns at once on a wheel that has not gone Busy yet",
        wheel("Wheel").set_slot_with_timeout(5, None).await,
    )
    .await;
    {
        let client = rig.client.read().await;
        let published = client.get_filter_names("Wheel").await;
        let synthesized = client.get_filter_names("WZero").await;
        let nothing = client.get_filter_names("Bare").await;
        drop(client);
        rig.record(
            &mut log,
            "IndiClient::get_filter_names, published",
            published,
        )
        .await;
        rig.record(
            &mut log,
            "IndiClient::get_filter_names, synthesized from the slot range",
            synthesized,
        )
        .await;
        rig.record(
            &mut log,
            "IndiClient::get_filter_names, nothing published",
            nothing,
        )
        .await;
    }

    let offline = IndiFilterWheel::new(offline_client(), "Wheel");
    record_offline(
        &mut log,
        "set_slot_with_timeout, client not connected",
        offline.set_slot_with_timeout(4, short).await,
    );

    check_golden("filter_wheel_other_entry_points", &log);
}

// Rotator

fn rotator_defs(device: &str, state: &str) -> String {
    [
        connection_def(device),
        number_def(
            device,
            "ABS_ROTATOR_ANGLE",
            state,
            "rw",
            &[("ANGLE", 45.0, Some((0.0, 360.0)))],
        ),
    ]
    .concat()
}

#[tokio::test]
async fn rotator_results_and_sent_xml() {
    let definitions = [
        rotator_defs("Rotator", "Ok"),
        rotator_defs("RMoveOk", "Busy"),
        rotator_defs("RMoveBusy", "Busy"),
        rotator_defs("RMoveAlert", "Alert"),
        number_def(
            "RRaw",
            "ROTATOR_RAW_ANGLE",
            "Ok",
            "ro",
            &[("ANGLE", 11.0, None)],
        ),
        number_def(
            "RPosition",
            "ROTATOR_POSITION",
            "Ok",
            "ro",
            &[("POSITION", 12.0, None)],
        ),
        number_def(
            "RMechanical",
            "MECHANICAL_POSITION",
            "Ok",
            "ro",
            &[("POSITION", 13.0, None)],
        ),
        connection_def("Bare"),
    ]
    .concat();
    let replies = vec![(
        on_number("RMoveOk", "ABS_ROTATOR_ANGLE"),
        vec![(
            100,
            number_update("RMoveOk", "ABS_ROTATOR_ANGLE", "Ok", &[("ANGLE", 90.0)]),
        )],
    )];
    let rig = Rig::start(definitions, replies).await;
    let rotator = |device: &str| IndiRotator::new(rig.client.clone(), device);
    let mut log = String::new();
    let wait = Some(Duration::from_secs(5));
    let short = Some(Duration::from_millis(300));

    rig.record(
        &mut log,
        "get_angle, published",
        rotator("Rotator").get_angle().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_angle, not published",
        rotator("Bare").get_angle().await,
    )
    .await;
    for device in ["RRaw", "RPosition", "RMechanical", "Bare"] {
        rig.record(
            &mut log,
            &format!("get_mechanical_position, {device}"),
            rotator(device).get_mechanical_position().await,
        )
        .await;
    }
    rig.record(
        &mut log,
        "move_to_with_timeout, Busy then Ok",
        rotator("RMoveOk").move_to_with_timeout(90.0, wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to_with_timeout, stays Busy past the timeout",
        rotator("RMoveBusy")
            .move_to_with_timeout(90.25, short)
            .await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to_with_timeout, property in Alert",
        rotator("RMoveAlert").move_to_with_timeout(90.0, wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to_with_timeout, angle beyond the driver's limits",
        rotator("Rotator").move_to_with_timeout(400.0, wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "move_to_with_timeout, default timeout",
        rotator("Rotator").move_to_with_timeout(100.0, None).await,
    )
    .await;

    let offline = IndiRotator::new(offline_client(), "Rotator");
    record_offline(
        &mut log,
        "move_to_with_timeout, client not connected",
        offline.move_to_with_timeout(90.0, short).await,
    );
    record_offline(
        &mut log,
        "get_angle, client not connected",
        offline.get_angle().await,
    );

    check_golden("rotator", &log);
}

// Dome

fn dome_defs(device: &str, azimuth_state: &str, shutter_state: &str) -> String {
    [
        connection_def(device),
        number_def(
            device,
            "ABS_DOME_POSITION",
            azimuth_state,
            "rw",
            &[("DOME_ABSOLUTE_POSITION", 90.0, Some((0.0, 360.0)))],
        ),
        switch_def(
            device,
            "DOME_SHUTTER",
            Some("OneOfMany"),
            shutter_state,
            "rw",
            &[("SHUTTER_OPEN", false), ("SHUTTER_CLOSE", true)],
        ),
        number_def(
            device,
            "DOME_PARAMS",
            "Ok",
            "rw",
            &[("HOME_POSITION", 10.0, None), ("PARK_POSITION", 20.0, None)],
        ),
    ]
    .concat()
}

#[tokio::test]
async fn dome_results_and_sent_xml() {
    let definitions = [
        dome_defs("Dome", "Ok", "Ok"),
        dome_defs("DMoveOk", "Busy", "Busy"),
        dome_defs("DCloseOk", "Ok", "Busy"),
        dome_defs("DBusy", "Busy", "Busy"),
        dome_defs("DAlert", "Alert", "Alert"),
        connection_def("Bare"),
    ]
    .concat();
    let replies = vec![
        (
            on_number("DMoveOk", "ABS_DOME_POSITION"),
            vec![(
                100,
                number_update(
                    "DMoveOk",
                    "ABS_DOME_POSITION",
                    "Ok",
                    &[("DOME_ABSOLUTE_POSITION", 180.0)],
                ),
            )],
        ),
        (
            on_switch("DMoveOk", "DOME_SHUTTER"),
            vec![(
                100,
                switch_update(
                    "DMoveOk",
                    "DOME_SHUTTER",
                    "Ok",
                    &[("SHUTTER_OPEN", true), ("SHUTTER_CLOSE", false)],
                ),
            )],
        ),
        (
            on_switch("DCloseOk", "DOME_SHUTTER"),
            vec![(
                100,
                switch_update(
                    "DCloseOk",
                    "DOME_SHUTTER",
                    "Ok",
                    &[("SHUTTER_OPEN", false), ("SHUTTER_CLOSE", true)],
                ),
            )],
        ),
    ];
    let rig = Rig::start(definitions, replies).await;
    let dome = |device: &str| IndiDome::new(rig.client.clone(), device);
    let mut log = String::new();
    let wait = Some(Duration::from_secs(5));
    let short = Some(Duration::from_millis(300));

    rig.record(
        &mut log,
        "get_azimuth, published",
        dome("Dome").get_azimuth().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_azimuth, not published",
        dome("Bare").get_azimuth().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_home_position, published",
        dome("Dome").get_home_position().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_home_position, not published",
        dome("Bare").get_home_position().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_park_position, published",
        dome("Dome").get_park_position().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_park_position, not published",
        dome("Bare").get_park_position().await,
    )
    .await;

    rig.record(
        &mut log,
        "slew_to_azimuth_with_timeout, Busy then Ok",
        dome("DMoveOk")
            .slew_to_azimuth_with_timeout(180.0, wait)
            .await,
    )
    .await;
    rig.record(
        &mut log,
        "slew_to_azimuth_with_timeout, stays Busy past the timeout",
        dome("DBusy")
            .slew_to_azimuth_with_timeout(180.25, short)
            .await,
    )
    .await;
    rig.record(
        &mut log,
        "slew_to_azimuth_with_timeout, property in Alert",
        dome("DAlert")
            .slew_to_azimuth_with_timeout(180.0, wait)
            .await,
    )
    .await;
    rig.record(
        &mut log,
        "slew_to_azimuth_with_timeout, azimuth beyond the driver's limits",
        dome("Dome").slew_to_azimuth_with_timeout(400.0, wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "slew_to_azimuth_with_timeout, default timeout",
        dome("Dome").slew_to_azimuth_with_timeout(100.0, None).await,
    )
    .await;

    rig.record(
        &mut log,
        "open_shutter_with_timeout, Busy then Ok",
        dome("DMoveOk").open_shutter_with_timeout(wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "open_shutter_with_timeout, stays Busy past the timeout",
        dome("DBusy").open_shutter_with_timeout(short).await,
    )
    .await;
    rig.record(
        &mut log,
        "open_shutter_with_timeout, property in Alert",
        dome("DAlert").open_shutter_with_timeout(wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "open_shutter_with_timeout, no shutter property",
        dome("Bare").open_shutter_with_timeout(short).await,
    )
    .await;
    rig.record(
        &mut log,
        "close_shutter_with_timeout, Busy then Ok",
        dome("DCloseOk").close_shutter_with_timeout(wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "close_shutter_with_timeout, stays Busy past the timeout",
        dome("DBusy").close_shutter_with_timeout(short).await,
    )
    .await;
    rig.record(
        &mut log,
        "close_shutter_with_timeout, property in Alert",
        dome("DAlert").close_shutter_with_timeout(wait).await,
    )
    .await;
    rig.record(
        &mut log,
        "close_shutter_with_timeout, default timeout",
        dome("Dome").close_shutter_with_timeout(None).await,
    )
    .await;

    let offline = IndiDome::new(offline_client(), "Dome");
    record_offline(
        &mut log,
        "slew_to_azimuth_with_timeout, client not connected",
        offline.slew_to_azimuth_with_timeout(180.0, short).await,
    );
    record_offline(
        &mut log,
        "open_shutter_with_timeout, client not connected",
        offline.open_shutter_with_timeout(short).await,
    );
    record_offline(
        &mut log,
        "close_shutter_with_timeout, client not connected",
        offline.close_shutter_with_timeout(short).await,
    );
    record_offline(
        &mut log,
        "get_azimuth, client not connected",
        offline.get_azimuth().await,
    );

    check_golden("dome", &log);
}

// Safety monitor

#[tokio::test]
async fn safety_monitor_results() {
    let definitions = [
        light_def("SWeatherOk", "WEATHER_STATUS", &[("WEATHER_SAFE", "Ok")]),
        light_def(
            "SWeatherIdle",
            "WEATHER_STATUS",
            &[("WEATHER_SAFE", "Idle")],
        ),
        light_def(
            "SWeatherBusy",
            "WEATHER_STATUS",
            &[("WEATHER_SAFE", "Busy")],
        ),
        light_def(
            "SWeatherAlert",
            "WEATHER_STATUS",
            &[("WEATHER_SAFE", "Alert")],
        ),
        switch_def(
            "SSwitchSafe",
            "SAFETY_STATUS",
            None,
            "Ok",
            "ro",
            &[("SAFE", true)],
        ),
        switch_def(
            "SSwitchUnsafe",
            "SAFETY_STATUS",
            None,
            "Ok",
            "ro",
            &[("SAFE", false)],
        ),
        switch_def(
            "SAuxOn",
            "AUX_SAFETY",
            None,
            "Ok",
            "ro",
            &[("ENABLED", true)],
        ),
        switch_def(
            "SAuxOff",
            "AUX_SAFETY",
            None,
            "Ok",
            "ro",
            &[("ENABLED", false)],
        ),
        light_def("SRain", "WEATHER_STATUS", &[("WEATHER_RAIN", "Alert")]),
        light_def("SWind", "WEATHER_STATUS", &[("WEATHER_WIND", "Alert")]),
        light_def("SClouds", "WEATHER_STATUS", &[("WEATHER_CLOUDS", "Alert")]),
        light_def(
            "SQuiet",
            "WEATHER_STATUS",
            &[
                ("WEATHER_RAIN", "Ok"),
                ("WEATHER_WIND", "Ok"),
                ("WEATHER_CLOUDS", "Ok"),
            ],
        ),
        connection_def("Bare"),
    ]
    .concat();
    let rig = Rig::start(definitions, Vec::new()).await;
    let mut log = String::new();

    for device in [
        "SWeatherOk",
        "SWeatherIdle",
        "SWeatherBusy",
        "SWeatherAlert",
        "SSwitchSafe",
        "SSwitchUnsafe",
        "SAuxOn",
        "SAuxOff",
        "SRain",
        "SWind",
        "SClouds",
        "SQuiet",
        "Bare",
    ] {
        let monitor = IndiSafetyMonitor::new(rig.client.clone(), device);
        rig.record(
            &mut log,
            &format!("is_safe, {device}"),
            monitor.is_safe().await,
        )
        .await;
    }
    let offline = IndiSafetyMonitor::new(offline_client(), "Safety");
    record_offline(
        &mut log,
        "is_safe, client not connected",
        offline.is_safe().await,
    );

    check_golden("safety_monitor", &log);
}

// Cover calibrator

#[tokio::test]
async fn cover_calibrator_results_and_sent_xml() {
    let park = [("PARK", true), ("UNPARK", false)];
    let open_close = [("OPEN", false), ("CLOSE", true)];
    let light = [("FLAT_LIGHT_ON", false), ("FLAT_LIGHT_OFF", true)];
    let intensity = [("FLAT_LIGHT_INTENSITY_VALUE", 100.0, Some((0.0, 255.0)))];
    let definitions = [
        // The standard dust cap and flat light vocabulary.
        switch_def("CCap", "CAP_PARK", Some("OneOfMany"), "Ok", "rw", &park),
        switch_def("CCap", "CAP_ABORT", None, "Ok", "rw", &[("ABORT", false)]),
        switch_def(
            "CCap",
            "FLAT_LIGHT_CONTROL",
            Some("OneOfMany"),
            "Ok",
            "rw",
            &light,
        ),
        number_def("CCap", "FLAT_LIGHT_INTENSITY", "Ok", "rw", &intensity),
        // DUST_CAP without a switch rule: any element name is sent as given.
        switch_def(
            "CDust",
            "DUST_CAP",
            None,
            "Ok",
            "rw",
            &[("OPEN", false), ("CLOSE", true), ("ABORT", false)],
        ),
        // DUST_CAP with a one-of-many rule: only defined elements can be sent.
        switch_def(
            "CDustRule",
            "DUST_CAP",
            Some("OneOfMany"),
            "Ok",
            "rw",
            &open_close,
        ),
        switch_def(
            "CDustUnpark",
            "DUST_CAP",
            Some("OneOfMany"),
            "Ok",
            "rw",
            &[("CAP_PARK", true), ("CAP_UNPARK", false)],
        ),
        switch_def("CDustcap", "DUSTCAP_CONTROL", None, "Ok", "rw", &open_close),
        switch_def(
            "CLightbox",
            "LIGHTBOX_CONTROL",
            None,
            "Ok",
            "rw",
            &open_close,
        ),
        number_def(
            "CLightbox",
            "LIGHTBOX_BRIGHTNESS",
            "Ok",
            "rw",
            &[("BRIGHTNESS", 50.0, Some((0.0, 100.0)))],
        ),
        switch_def("CAbort", "ABORT", None, "Ok", "rw", &[("ABORT", false)]),
        number_def("CIntensity", "FLAT_LIGHT_INTENSITY", "Ok", "rw", &intensity),
        number_def(
            "CNoLimits",
            "FLAT_LIGHT_INTENSITY",
            "Ok",
            "rw",
            &[("FLAT_LIGHT_INTENSITY_VALUE", 7.0, None)],
        ),
        switch_def(
            "CReadOnly",
            "CAP_PARK",
            Some("OneOfMany"),
            "Ok",
            "ro",
            &park,
        ),
        switch_def(
            "CReadOnly",
            "CAP_ABORT",
            None,
            "Ok",
            "ro",
            &[("ABORT", false)],
        ),
        switch_def(
            "CReadOnly",
            "FLAT_LIGHT_CONTROL",
            Some("OneOfMany"),
            "Ok",
            "ro",
            &light,
        ),
        number_def("CReadOnly", "FLAT_LIGHT_INTENSITY", "Ok", "ro", &intensity),
        connection_def("Bare"),
    ]
    .concat();
    let rig = Rig::start(definitions, Vec::new()).await;
    let cover = |device: &str| IndiCoverCalibrator::new(rig.client.clone(), device);
    let mut log = String::new();

    let cover_devices = [
        "CCap",
        "CDust",
        "CDustRule",
        "CDustUnpark",
        "CDustcap",
        "CLightbox",
        "CAbort",
        "CReadOnly",
        "Bare",
    ];
    for device in cover_devices {
        rig.record(
            &mut log,
            &format!("open_cover, {device}"),
            cover(device).open_cover().await,
        )
        .await;
    }
    for device in cover_devices {
        rig.record(
            &mut log,
            &format!("close_cover, {device}"),
            cover(device).close_cover().await,
        )
        .await;
    }
    for device in cover_devices {
        rig.record(
            &mut log,
            &format!("halt_cover, {device}"),
            cover(device).halt_cover().await,
        )
        .await;
    }

    let light_devices = [
        "CCap",
        "CLightbox",
        "CIntensity",
        "CNoLimits",
        "CReadOnly",
        "Bare",
    ];
    for device in light_devices {
        rig.record(
            &mut log,
            &format!("calibrator_on(100), {device}"),
            cover(device).calibrator_on(100).await,
        )
        .await;
    }
    rig.record(
        &mut log,
        "calibrator_on(0), CCap",
        cover("CCap").calibrator_on(0).await,
    )
    .await;
    rig.record(
        &mut log,
        "calibrator_on(0), CLightbox",
        cover("CLightbox").calibrator_on(0).await,
    )
    .await;
    rig.record(
        &mut log,
        "calibrator_on(300), beyond the driver's limits, CCap",
        cover("CCap").calibrator_on(300).await,
    )
    .await;
    rig.record(
        &mut log,
        "calibrator_on(300), beyond the driver's limits, CLightbox",
        cover("CLightbox").calibrator_on(300).await,
    )
    .await;
    for device in light_devices {
        rig.record(
            &mut log,
            &format!("calibrator_off, {device}"),
            cover(device).calibrator_off().await,
        )
        .await;
    }
    for device in light_devices {
        rig.record(
            &mut log,
            &format!("get_brightness, {device}"),
            cover(device).get_brightness().await,
        )
        .await;
    }
    for device in light_devices {
        rig.record(
            &mut log,
            &format!("set_brightness(42), {device}"),
            cover(device).set_brightness(42).await,
        )
        .await;
    }
    rig.record(
        &mut log,
        "set_brightness(300), beyond the driver's limits, CCap",
        cover("CCap").set_brightness(300).await,
    )
    .await;
    for device in light_devices {
        rig.record(
            &mut log,
            &format!("get_max_brightness, {device}"),
            cover(device).get_max_brightness().await,
        )
        .await;
    }

    let offline = IndiCoverCalibrator::new(offline_client(), "Cover");
    record_offline(
        &mut log,
        "open_cover, client not connected",
        offline.open_cover().await,
    );
    record_offline(
        &mut log,
        "close_cover, client not connected",
        offline.close_cover().await,
    );
    record_offline(
        &mut log,
        "halt_cover, client not connected",
        offline.halt_cover().await,
    );
    record_offline(
        &mut log,
        "calibrator_on, client not connected",
        offline.calibrator_on(100).await,
    );
    record_offline(
        &mut log,
        "calibrator_off, client not connected",
        offline.calibrator_off().await,
    );
    record_offline(
        &mut log,
        "get_brightness, client not connected",
        offline.get_brightness().await,
    );
    record_offline(
        &mut log,
        "set_brightness, client not connected",
        offline.set_brightness(42).await,
    );
    record_offline(
        &mut log,
        "get_max_brightness, client not connected",
        offline.get_max_brightness().await,
    );

    check_golden("cover_calibrator", &log);
}

// Camera

fn camera_defs(device: &str, frame_perm: &str) -> String {
    [
        connection_def(device),
        number_def(
            device,
            "CCD_TEMPERATURE",
            "Ok",
            "rw",
            &[("CCD_TEMPERATURE_VALUE", -10.5, None)],
        ),
        number_def(device, "CCD_GAIN", "Ok", "rw", &[("GAIN", 120.0, None)]),
        number_def(device, "CCD_OFFSET", "Ok", "rw", &[("OFFSET", 30.0, None)]),
        number_def(
            device,
            "CCD_INFO",
            "Ok",
            "ro",
            &[("CCD_MAX_X", 4656.0, None), ("CCD_MAX_Y", 3520.0, None)],
        ),
        number_def(
            device,
            "CCD_FRAME",
            "Ok",
            frame_perm,
            &[
                ("X", 100.0, Some((0.0, 4656.0))),
                ("Y", 100.0, Some((0.0, 3520.0))),
                ("WIDTH", 1000.0, Some((1.0, 4656.0))),
                ("HEIGHT", 1000.0, Some((1.0, 3520.0))),
            ],
        ),
        number_def(
            device,
            "CCD_EXPOSURE",
            "Ok",
            "rw",
            &[("CCD_EXPOSURE_VALUE", 0.0, Some((0.0, 3600.0)))],
        ),
    ]
    .concat()
}

#[tokio::test]
async fn camera_results_and_sent_xml() {
    let definitions = [
        camera_defs("CCD", "rw"),
        camera_defs("CFrameRo", "ro"),
        camera_defs("CBlob", "rw"),
        camera_defs("CBlob2", "rw"),
        number_def(
            "CWidthOnly",
            "CCD_INFO",
            "Ok",
            "ro",
            &[("CCD_MAX_X", 4656.0, None)],
        ),
        connection_def("Bare"),
    ]
    .concat();
    let replies = vec![
        (
            on_number("CBlob", "CCD_EXPOSURE"),
            vec![(
                100,
                "<setBLOBVector device=\"CBlob\" name=\"CCD1\">\
                 <oneBLOB name=\"CCD1\" size=\"6\">/9j/4AAA</oneBLOB></setBLOBVector>\n"
                    .to_string(),
            )],
        ),
        (
            on_number("CBlob2", "CCD_EXPOSURE"),
            vec![(
                100,
                "<setBLOBVector device=\"CBlob2\" name=\"CCD2\">\
                 <oneBLOB name=\"CCD2\" size=\"6\">/9j/4AAA</oneBLOB></setBLOBVector>\n"
                    .to_string(),
            )],
        ),
    ];
    let rig = Rig::start(definitions, replies).await;
    let camera = |device: &str| IndiCamera::new(rig.client.clone(), device);
    let mut log = String::new();
    let buffer = Some(Duration::from_millis(200));

    rig.record(
        &mut log,
        "get_temperature, published",
        camera("CCD").get_temperature().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_temperature, not published",
        camera("Bare").get_temperature().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_gain, published",
        camera("CCD").get_gain().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_gain, not published",
        camera("Bare").get_gain().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_offset, published",
        camera("CCD").get_offset().await,
    )
    .await;
    rig.record(
        &mut log,
        "get_offset, not published",
        camera("Bare").get_offset().await,
    )
    .await;

    rig.record(
        &mut log,
        "reset_frame, published sensor size",
        camera("CCD").reset_frame().await,
    )
    .await;
    rig.record(
        &mut log,
        "reset_frame, no sensor size",
        camera("Bare").reset_frame().await,
    )
    .await;
    rig.record(
        &mut log,
        "reset_frame, width without height",
        camera("CWidthOnly").reset_frame().await,
    )
    .await;
    rig.record(
        &mut log,
        "reset_frame, read-only frame",
        camera("CFrameRo").reset_frame().await,
    )
    .await;

    rig.record(
        &mut log,
        "capture_image_with_timeout, image on CCD1",
        camera("CBlob")
            .capture_image_with_timeout(0.1, buffer)
            .await,
    )
    .await;
    rig.record(
        &mut log,
        "capture_image_with_timeout, image on CCD2",
        camera("CBlob2")
            .capture_image_with_timeout(0.1, buffer)
            .await,
    )
    .await;
    rig.record(
        &mut log,
        "capture_image_with_timeout, no image arrives",
        camera("CCD").capture_image_with_timeout(0.1, buffer).await,
    )
    .await;
    rig.record(
        &mut log,
        "capture_image_with_timeout, exposure beyond the driver's limits",
        camera("CCD")
            .capture_image_with_timeout(4000.0, buffer)
            .await,
    )
    .await;

    let offline = IndiCamera::new(offline_client(), "CCD");
    record_offline(
        &mut log,
        "capture_image_with_timeout, client not connected",
        offline.capture_image_with_timeout(0.1, buffer).await,
    );
    record_offline(
        &mut log,
        "reset_frame, client not connected",
        offline.reset_frame().await,
    );
    record_offline(
        &mut log,
        "get_temperature, client not connected",
        offline.get_temperature().await,
    );

    check_golden("camera", &log);
}
