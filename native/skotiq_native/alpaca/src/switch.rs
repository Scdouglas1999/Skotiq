//! Alpaca Switch API implementation

alpaca_device!(
    AlpacaSwitch,
    Switch
);

impl AlpacaSwitch {
    skotiq_device::ascom_switch_members!(alpaca_member);
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn get_switch_uses_single_query_separator() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind fake Alpaca switch server");
        let port = listener.local_addr().expect("read listener address").port();

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept client");
            let mut buf = vec![0_u8; 4096];
            let n = socket.read(&mut buf).await.expect("read request");
            let request = String::from_utf8_lossy(&buf[..n]).to_string();
            let request_line = request.lines().next().unwrap_or_default().to_string();
            let body = "{\"Value\":true,\"ClientTransactionID\":0,\"ServerTransactionID\":1,\"ErrorNumber\":0,\"ErrorMessage\":\"\"}";
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            socket
                .write_all(response.as_bytes())
                .await
                .expect("write response");
            request_line
        });

        let switch = AlpacaSwitch::from_server(&format!("http://127.0.0.1:{port}"), 0);
        let state = switch.get_switch(3).await.expect("read switch state");
        assert!(state);

        let request_line = server.await.expect("fake server should finish");
        assert!(
            request_line.starts_with("GET /api/v1/switch/0/getswitch?"),
            "unexpected request line: {}",
            request_line
        );
        assert_eq!(
            request_line.matches('?').count(),
            1,
            "switch GET must not contain a second query separator: {}",
            request_line
        );
        assert!(
            request_line.contains("Id=3")
                && request_line.contains("ClientID=")
                && request_line.contains("ClientTransactionID="),
            "switch GET query missing expected parameters: {}",
            request_line
        );
    }
}
