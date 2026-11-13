//! The range of a number as real drivers publish it.
//!
//! INDI's CCD simulator (2.2.5) defines `CCD_FRAME` with no range (`min` and
//! `max` both 0) when the camera connects and sends the sensor's range in a
//! `setNumberVector` right after. A scripted server replays that exchange.

use skotiq_indi::{IndiClient, IndiError};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

const CCD: &str = "CCD Simulator";

const DEFINED_WITHOUT_RANGE: &str = r#"<defNumberVector device="CCD Simulator" name="CCD_FRAME" label="Frame" group="Image Settings" state="Idle" perm="rw" timeout="60" timestamp="2026-11-13T00:21:17">
    <defNumber name="X" label="Left " format="%4.0f" min="0" max="0" step="0">
0
    </defNumber>
    <defNumber name="WIDTH" label="Width" format="%4.0f" min="0" max="0" step="0">
0
    </defNumber>
</defNumberVector>
"#;

const RANGE_SENT_AFTER: &str = r#"<setNumberVector device="CCD Simulator" name="CCD_FRAME" state="Idle" timeout="60" timestamp="2026-11-13T00:21:17">
    <oneNumber name="X" min="0" max="1279" step="0">
0
    </oneNumber>
    <oneNumber name="WIDTH" min="1" max="1280" step="0">
0
    </oneNumber>
</setNumberVector>
<setNumberVector device="CCD Simulator" name="CCD_FRAME" state="Idle" timeout="60" timestamp="2026-11-13T00:21:17">
    <oneNumber name="X">
0
    </oneNumber>
    <oneNumber name="WIDTH">
1280
    </oneNumber>
</setNumberVector>
"#;

/// A client on a server that answers getProperties with `messages` and
/// nothing else, once `ready` holds for it.
async fn client_after(messages: String, ready_width: Option<f64>) -> IndiClient {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("address").port();
    tokio::spawn(async move {
        let (socket, _) = listener.accept().await.expect("accept");
        let (reader, mut writer) = socket.into_split();
        let mut lines = BufReader::new(reader).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if line.contains("<getProperties") {
                let _ = writer.write_all(messages.as_bytes()).await;
            }
        }
    });
    let mut client = IndiClient::new("127.0.0.1", Some(port));
    client.connect().await.expect("connect");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let width = client.get_number(CCD, "CCD_FRAME", "WIDTH").await;
        if width.is_some() && (ready_width.is_none() || width == ready_width) {
            return client;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "the messages arrived"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// A frame of 1280 columns was refused as "out of range [0, 0]", so no
/// exposure could start on a camera whose driver had not sent a range yet.
#[tokio::test]
async fn a_number_defined_with_equal_limits_has_no_range() {
    let mut client = client_after(DEFINED_WITHOUT_RANGE.to_string(), None).await;
    client
        .set_number(CCD, "CCD_FRAME", "WIDTH", 1280.0)
        .await
        .expect("no range, so any width is sent to the driver");
}

/// The range a driver sends after the definition replaces the defined one.
#[tokio::test]
async fn a_range_sent_with_a_number_update_is_the_numbers_range() {
    let mut client = client_after(
        format!("{DEFINED_WITHOUT_RANGE}{RANGE_SENT_AFTER}"),
        Some(1280.0),
    )
    .await;
    let limits = client
        .get_number_limits(CCD, "CCD_FRAME", "WIDTH")
        .await
        .expect("limits");
    assert_eq!((limits.min, limits.max), (Some(1.0), Some(1280.0)));
    assert_eq!(limits.format.as_deref(), Some("%4.0f"));

    client
        .set_number(CCD, "CCD_FRAME", "WIDTH", 640.0)
        .await
        .expect("inside the range");
    let refused = client
        .set_number(CCD, "CCD_FRAME", "WIDTH", 5000.0)
        .await
        .expect_err("outside the range");
    assert!(
        matches!(refused, IndiError::ValueOutOfRange { max, .. } if max == 1280.0),
        "{refused}"
    );
}
