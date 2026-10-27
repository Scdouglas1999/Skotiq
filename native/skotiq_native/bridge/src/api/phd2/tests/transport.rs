//! Exercise connection recovery through the same bridge entry point the flip uses.
use super::super::*;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;

#[tokio::test]
async fn stop_guiding_recovers_the_connection_and_waits_for_stopped() {
    let _slot = PHD2_TEST_SLOT.lock().await;
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = std::thread::spawn(move || {
        let mut stops = 0;
        let mut confirmation_reads = 0;
        for connection in 0..2 {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let reader = BufReader::new(stream.try_clone().unwrap());
            for line in reader.lines() {
                let line = line.unwrap();
                let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                let result = match request["method"].as_str().unwrap() {
                    "get_exposure" => serde_json::json!(500),
                    "get_app_state" if stops == 0 => serde_json::json!("Guiding"),
                    "get_app_state" => {
                        confirmation_reads += 1;
                        // The stop acknowledgement precedes the end of capture.
                        serde_json::json!(if confirmation_reads == 1 {
                            "Guiding"
                        } else {
                            "Stopped"
                        })
                    }
                    "stop_capture" => {
                        stops += 1;
                        if connection == 0 {
                            // Drop the first command's response; the same API call
                            // must reconnect and confirm that the retry worked.
                            break;
                        }
                        serde_json::json!(0)
                    }
                    method => panic!("unexpected command: {method}"),
                };
                writeln!(
                    stream,
                    "{}",
                    serde_json::json!({
                        "jsonrpc": "2.0", "result": result, "id": request["id"]
                    })
                )
                .unwrap();
            }
        }
        (stops, confirmation_reads)
    });
    api_phd2_connect(Some("127.0.0.1".into()), Some(port))
        .await
        .unwrap();
    let mut events = get_state().event_bus.subscribe();
    let result = api_phd2_stop_guiding().await;
    let mut disconnected = false;
    while let Ok(event) = events.try_recv() {
        disconnected |= matches!(
            event.payload,
            EventPayload::Guiding(GuidingEvent::Disconnected)
        );
    }
    api_phd2_disconnect().await.unwrap();
    result.unwrap();
    assert!(
        !disconnected,
        "a recovered transport must not trigger UI teardown"
    );
    let (stops, confirmation_reads) = server.join().unwrap();
    assert_eq!(stops, 2);
    assert_eq!(
        confirmation_reads, 2,
        "must wait beyond the stop acknowledgement"
    );
}
