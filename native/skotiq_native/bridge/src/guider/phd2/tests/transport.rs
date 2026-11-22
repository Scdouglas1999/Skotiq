//! Exercise connection recovery through the same bridge entry point the flip uses.
use super::super::*;
use crate::event::bus::EventPayload;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};

#[tokio::test]
async fn stop_guiding_recovers_the_connection_and_waits_for_stopped() {
    let _slot = sim_singleton_test_lock().lock().await;
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
    connect(Some("127.0.0.1".into()), Some(port)).await.unwrap();
    let mut events = get_state().event_bus.subscribe();
    let result = stop_guiding().await;
    let mut disconnected = false;
    while let Ok(event) = events.try_recv() {
        disconnected |= matches!(
            event.payload,
            EventPayload::Guiding(GuidingEvent::Disconnected)
        );
    }
    disconnect().await.unwrap();
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

/// A PHD2 stand-in on `listener` that answers every request until `close`
/// is set, then drops the connection the way a PHD2 that quit does.
fn serve_until_closed(
    listener: TcpListener,
    close: Arc<AtomicBool>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut line = String::new();
        while !close.load(Ordering::SeqCst) {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => {}
                Err(_) => continue,
            }
            let Ok(request) = serde_json::from_str::<serde_json::Value>(&line) else {
                continue;
            };
            let result = match request["method"].as_str().unwrap_or_default() {
                "get_app_state" => serde_json::json!("Stopped"),
                _ => serde_json::json!(0),
            };
            let _ = writeln!(
                stream,
                "{}",
                serde_json::json!({"jsonrpc": "2.0", "result": result, "id": request["id"]})
            );
        }
        let _ = stream.shutdown(std::net::Shutdown::Both);
    })
}

/// PHD2 restarted (or crashed and was started again) while Skotiq was
/// connected: its socket closed, and nothing connected to it again. The
/// bridge now reconnects to the PHD2 server on its own, with backoff, and
/// lists PHD2 as the connected guider again.
#[tokio::test]
async fn a_phd2_that_restarts_is_connected_again() {
    use std::sync::atomic::AtomicBool;
    let _slot = sim_singleton_test_lock().lock().await;
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let close = Arc::new(AtomicBool::new(false));
    let first = serve_until_closed(listener, close.clone());
    connect(Some("127.0.0.1".into()), Some(port)).await.unwrap();
    let mut events = get_state().event_bus.subscribe();

    // PHD2 quits; its port stays closed for a while, then it is back.
    close.store(true, Ordering::SeqCst);
    first.join().unwrap();
    tokio::time::sleep(Duration::from_secs(1)).await;
    let listener = TcpListener::bind(("127.0.0.1", port)).unwrap();
    let second = serve_until_closed(listener, Arc::new(AtomicBool::new(false)));

    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    let mut reconnected = false;
    while tokio::time::Instant::now() < deadline && !reconnected {
        match tokio::time::timeout(Duration::from_millis(200), events.recv()).await {
            Ok(Ok(event)) => {
                reconnected |= matches!(
                    event.payload,
                    EventPayload::Guiding(GuidingEvent::Connected)
                );
            }
            Ok(Err(_)) | Err(_) => {}
        }
    }
    let listed = get_device_manager()
        .is_device_connected(DeviceType::Guider, DEVICE_ID)
        .await;
    disconnect().await.unwrap();
    drop(second);
    assert!(reconnected, "the bridge connects to the restarted PHD2");
    assert!(listed, "PHD2 is listed as the connected guider again");
}

/// A deliberate disconnect stays disconnected: nothing reconnects it.
#[tokio::test]
async fn a_phd2_the_user_disconnected_is_not_connected_again() {
    use std::sync::atomic::AtomicBool;
    let _slot = sim_singleton_test_lock().lock().await;
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let close = Arc::new(AtomicBool::new(false));
    let first = serve_until_closed(listener, close.clone());
    connect(Some("127.0.0.1".into()), Some(port)).await.unwrap();
    // PHD2 drops, then the user disconnects before it is back.
    close.store(true, Ordering::SeqCst);
    first.join().unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    disconnect().await.unwrap();
    let listener = TcpListener::bind(("127.0.0.1", port)).unwrap();
    listener.set_nonblocking(true).unwrap();
    tokio::time::sleep(Duration::from_secs(8)).await;
    let accepted = listener.accept().is_ok();
    assert!(!accepted, "a disconnected PHD2 is left alone");
    assert!(
        !get_device_manager()
            .is_device_connected(DeviceType::Guider, DEVICE_ID)
            .await
    );
}
