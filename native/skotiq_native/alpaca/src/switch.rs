//! Alpaca Switch API implementation

use crate::{AlpacaClient, AlpacaDevice, AlpacaDeviceType};

/// Alpaca Switch client
pub struct AlpacaSwitch {
    client: AlpacaClient,
}

impl AlpacaSwitch {
    /// Create a new Alpaca switch client
    pub fn new(device: &AlpacaDevice) -> Self {
        assert_eq!(device.device_type, AlpacaDeviceType::Switch);
        Self {
            client: AlpacaClient::new(device),
        }
    }

    /// Create from server details
    pub fn from_server(base_url: &str, device_number: u32) -> Self {
        let device = AlpacaDevice::from_server(AlpacaDeviceType::Switch, base_url, device_number);
        Self::new(&device)
    }

    // Connection methods

    pub async fn connect(&self) -> Result<(), String> {
        self.client.connect().await
    }

    pub async fn disconnect(&self) -> Result<(), String> {
        self.client.disconnect().await
    }

    pub async fn is_connected(&self) -> Result<bool, String> {
        self.client.is_connected().await
    }

    // Switch information

    pub async fn name(&self) -> Result<String, String> {
        self.client.get_name().await
    }

    pub async fn description(&self) -> Result<String, String> {
        self.client.get_description().await
    }

    /// Get the driver version string
    pub async fn driver_version(&self) -> Result<String, String> {
        self.client.get_driver_version().await
    }

    /// Get the driver info string
    pub async fn driver_info(&self) -> Result<String, String> {
        self.client.get_driver_info().await
    }

    /// Get the interface version number
    pub async fn interface_version(&self) -> Result<i32, String> {
        self.client.get_interface_version().await
    }

    /// Get the list of supported custom actions
    pub async fn supported_actions(&self) -> Result<Vec<String>, String> {
        self.client.get_supported_actions().await
    }

    pub async fn max_switch(&self) -> Result<i32, String> {
        self.client.get("maxswitch").await
    }

    // Switch operations

    pub async fn get_switch(&self, id: i32) -> Result<bool, String> {
        self.client
            .get_with_params("getswitch", &[("Id", &id.to_string())])
            .await
    }

    pub async fn set_switch(&self, id: i32, state: bool) -> Result<(), String> {
        self.client
            .put(
                "setswitch",
                &[("Id", &id.to_string()), ("State", &state.to_string())],
            )
            .await
    }

    pub async fn get_switch_name(&self, id: i32) -> Result<String, String> {
        self.client
            .get_with_params("getswitchname", &[("Id", &id.to_string())])
            .await
    }

    pub async fn set_switch_name(&self, id: i32, name: &str) -> Result<(), String> {
        self.client
            .put("setswitchname", &[("Id", &id.to_string()), ("Name", name)])
            .await
    }

    pub async fn get_switch_description(&self, id: i32) -> Result<String, String> {
        self.client
            .get_with_params("getswitchdescription", &[("Id", &id.to_string())])
            .await
    }

    pub async fn get_switch_value(&self, id: i32) -> Result<f64, String> {
        self.client
            .get_with_params("getswitchvalue", &[("Id", &id.to_string())])
            .await
    }

    pub async fn set_switch_value(&self, id: i32, value: f64) -> Result<(), String> {
        self.client
            .put(
                "setswitchvalue",
                &[("Id", &id.to_string()), ("Value", &value.to_string())],
            )
            .await
    }

    pub async fn min_switch_value(&self, id: i32) -> Result<f64, String> {
        self.client
            .get_with_params("minswitchvalue", &[("Id", &id.to_string())])
            .await
    }

    pub async fn max_switch_value(&self, id: i32) -> Result<f64, String> {
        self.client
            .get_with_params("maxswitchvalue", &[("Id", &id.to_string())])
            .await
    }

    pub async fn can_write(&self, id: i32) -> Result<bool, String> {
        self.client
            .get_with_params("canwrite", &[("Id", &id.to_string())])
            .await
    }
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
