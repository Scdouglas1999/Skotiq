//! Alpaca HTTP Client

mod builder;
mod config;
mod error;
#[cfg(test)]
mod tests;
mod version;

pub use builder::*;
pub use config::*;
pub use error::*;
pub use version::*;

use crate::{AlpacaDevice, AlpacaDeviceType};
use chrono::{DateTime, Utc};
use reqwest::Client;
use serde::{de::DeserializeOwned, Deserialize};
use std::any::TypeId;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;
use thiserror::Error;
use tracing::{debug, warn};

/// Allocate unique Alpaca ClientID values per `AlpacaClient` instance.
static NEXT_CLIENT_ID: AtomicU32 = AtomicU32::new(1);

/// Decode the JSON body of an Alpaca PUT (void) operation.
///
/// ASCOM Alpaca PUT operations (Connected=true, slew, move, switch set, cover
/// open, ...) are void: their response carries only ClientTransactionID /
/// ServerTransactionID / ErrorNumber / ErrorMessage and NO "Value" field.
/// Decoding those into `AlpacaResponse<()>` fails with "missing field Value",
/// which broke EVERY Alpaca PUT (connect included). We instead read the error
/// fields directly and tolerate an absent "Value". Some bridges return a
/// non-standard informational `Value` even for a void command (libindi's
/// Alpaca server returns `Value: true` for `Connected=true`). For `T = ()` we
/// therefore ignore `Value` entirely; value-returning PUTs still decode it.
fn decode_put_response<T: DeserializeOwned + 'static>(
    raw: serde_json::Value,
) -> Result<T, AlpacaError> {
    let error_number = raw
        .get("ErrorNumber")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(0) as i32;
    if error_number != 0 {
        let error_message = raw
            .get("ErrorMessage")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .to_string();
        return Err(AlpacaError::DeviceError {
            code: error_number,
            message: error_message,
        });
    }
    let value_json = if TypeId::of::<T>() == TypeId::of::<()>() {
        serde_json::Value::Null
    } else {
        raw.get("Value").cloned().unwrap_or(serde_json::Value::Null)
    };
    serde_json::from_value(value_json).map_err(|e| AlpacaError::RequestFailed(e.to_string()))
}

/// Alpaca API response wrapper
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct AlpacaResponse<T> {
    pub value: T,
    #[serde(rename = "ClientTransactionID", alias = "ClientTransactionId")]
    pub client_transaction_id: u32,
    #[serde(rename = "ServerTransactionID", alias = "ServerTransactionId")]
    pub server_transaction_id: u32,
    pub error_number: i32,
    pub error_message: String,
}

/// Server API information response
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct ApiVersionsResponse {
    pub value: Vec<u32>,
}

/// Alpaca client for communicating with a device
pub struct AlpacaClient {
    http_client: Option<Client>,
    http_client_error: Option<String>,
    base_url: String,
    device_type: AlpacaDeviceType,
    device_number: u32,
    timeout_config: TimeoutConfig,
    retry_config: RetryConfig,
    api_version: ApiVersion,
    client_id: u32,
    transaction_id: AtomicU32,
}

impl AlpacaClient {
    /// Create a new Alpaca client for a device with default configuration
    pub fn new(device: &AlpacaDevice) -> Self {
        Self::with_config(device, TimeoutConfig::default(), RetryConfig::default())
    }

    /// Create a new Alpaca client with custom timeout and retry configuration
    pub fn with_config(
        device: &AlpacaDevice,
        timeout_config: TimeoutConfig,
        retry_config: RetryConfig,
    ) -> Self {
        let http_client = Client::builder()
            .timeout(Duration::from_millis(timeout_config.standard_operation_ms))
            .connect_timeout(Duration::from_millis(timeout_config.connect_ms))
            .pool_idle_timeout(Duration::from_secs(30))
            .build();

        let (http_client, http_client_error) = match http_client {
            Ok(client) => (Some(client), None),
            Err(err) => (None, Some(err.to_string())),
        };

        let client_id = NEXT_CLIENT_ID.fetch_add(1, Ordering::Relaxed);
        Self {
            http_client,
            http_client_error,
            base_url: device.base_url.clone(),
            device_type: device.device_type,
            device_number: device.device_number,
            timeout_config,
            retry_config,
            api_version: ApiVersion::V1,
            client_id,
            transaction_id: AtomicU32::new(0),
        }
    }

    /// Return `(ClientID, ClientTransactionID)` for this client instance.
    pub fn client_transaction(&self) -> (u32, u32) {
        (
            self.client_id,
            self.transaction_id.fetch_add(1, Ordering::SeqCst),
        )
    }

    /// Get the base URL for this client
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// Get the device number for this client
    pub fn device_number(&self) -> u32 {
        self.device_number
    }

    /// Get the timeout configuration
    pub fn timeout_config(&self) -> &TimeoutConfig {
        &self.timeout_config
    }

    /// Get the retry configuration
    pub fn retry_config(&self) -> &RetryConfig {
        &self.retry_config
    }

    /// Get the current API version being used
    pub fn api_version(&self) -> ApiVersion {
        self.api_version
    }

    fn standard_http_client(&self) -> Result<&Client, AlpacaError> {
        self.http_client.as_ref().ok_or_else(|| {
            // Why: if `http_client` is None we *must* have
            // recorded the construction error in `http_client_error` at
            // `with_config` time (see ~line 459-462 where the two fields are
            // populated as a (Some, None) / (None, Some) pair). The fallback
            // string only fires if a future refactor breaks that invariant,
            // in which case ClientInitializationFailed is still the correct
            // hard error to return — we just don't have the original cause
            // text to embed in it.
            AlpacaError::ClientInitializationFailed(
                self.http_client_error
                    .clone()
                    .unwrap_or_else(|| "unknown client build error".to_string()),
            )
        })
    }

    /// Get the pooled HTTP client for issuing requests with custom per-request
    /// timeouts.
    ///
    /// Callers reuse this pooled client and override only the per-request
    /// timeout via `RequestBuilder::timeout(...)`; a fresh `reqwest::Client`
    /// per frame costs a TLS handshake and a new TCP session every shot.
    pub fn http_client(&self) -> Result<&Client, AlpacaError> {
        self.standard_http_client()
    }

    /// Build the URL for an API endpoint.
    ///
    /// Why: exposed `pub(crate)` so the camera image-download path can build
    /// the same canonical URL when issuing a request directly against the
    /// pooled HTTP client.
    pub(crate) fn build_url(&self, endpoint: &str) -> String {
        format!(
            "{}/api/{}/{}/{}/{}",
            self.base_url,
            self.api_version.as_str(),
            self.device_type.as_str(),
            self.device_number,
            endpoint
        )
    }

    /// Create a client with a specific timeout for long operations
    fn create_long_timeout_client(&self) -> Result<Client, AlpacaError> {
        Client::builder()
            .timeout(Duration::from_millis(self.timeout_config.long_operation_ms))
            .connect_timeout(Duration::from_millis(self.timeout_config.connect_ms))
            .build()
            .map_err(|e| AlpacaError::RequestFailed(e.to_string()))
    }

    /// Create a client with a specific timeout for quick queries
    fn create_quick_timeout_client(&self) -> Result<Client, AlpacaError> {
        Client::builder()
            .timeout(Duration::from_millis(self.timeout_config.quick_query_ms))
            .connect_timeout(Duration::from_millis(self.timeout_config.connect_ms))
            .build()
            .map_err(|e| AlpacaError::RequestFailed(e.to_string()))
    }

    /// Create a client with a specific timeout for very long operations
    fn create_very_long_timeout_client(&self) -> Result<Client, AlpacaError> {
        Client::builder()
            .timeout(Duration::from_millis(
                self.timeout_config.very_long_operation_ms,
            ))
            .connect_timeout(Duration::from_millis(self.timeout_config.connect_ms))
            .build()
            .map_err(|e| AlpacaError::RequestFailed(e.to_string()))
    }

    /// Execute a request with retry logic
    async fn execute_with_retry<F, Fut, T>(&self, operation: F) -> Result<T, AlpacaError>
    where
        F: Fn() -> Fut,
        Fut: std::future::Future<Output = Result<T, AlpacaError>>,
    {
        let mut last_error = AlpacaError::OperationFailed("No attempts made".to_string());

        for attempt in 0..self.retry_config.max_attempts {
            match operation().await {
                Ok(result) => return Ok(result),
                Err(e) => {
                    last_error = e;

                    // Check if the error is retryable using the is_retryable method
                    if !last_error.is_retryable() {
                        return Err(last_error);
                    }

                    // If not the last attempt, wait before retrying
                    if attempt + 1 < self.retry_config.max_attempts {
                        let delay = self
                            .retry_config
                            .delay_for_retry_error(&last_error, attempt);
                        debug!(
                            "Request failed (attempt {}/{}), retrying in {:?}: {}",
                            attempt + 1,
                            self.retry_config.max_attempts,
                            delay,
                            last_error
                        );
                        tokio::time::sleep(delay).await;
                    }
                }
            }
        }

        Err(AlpacaError::RetryExhausted {
            attempts: self.retry_config.max_attempts,
            last_error: last_error.to_string(),
        })
    }

    /// Make a GET request with typed error handling
    pub async fn get_typed<T: for<'de> Deserialize<'de>>(
        &self,
        endpoint: &str,
    ) -> Result<T, AlpacaError> {
        let endpoint = endpoint.to_string();
        self.execute_with_retry(|| {
            let endpoint = endpoint.clone();
            async move {
                let (client_id, transaction_id) = self.client_transaction();
                let url = format!(
                    "{}?ClientID={}&ClientTransactionID={}",
                    self.build_url(&endpoint),
                    client_id,
                    transaction_id
                );

                let response = self.standard_http_client()?.get(&url).send().await?;

                let status = response.status();
                if !status.is_success() {
                    let retry_after = parse_retry_after_header(response.headers());
                    let body = response.text().await?;
                    return Err(AlpacaError::HttpError {
                        status: status.as_u16(),
                        message: body,
                        retry_after,
                    });
                }

                let alpaca_response: AlpacaResponse<T> = response.json().await?;

                if alpaca_response.error_number != 0 {
                    return Err(AlpacaError::DeviceError {
                        code: alpaca_response.error_number,
                        message: alpaca_response.error_message,
                    });
                }

                Ok(alpaca_response.value)
            }
        })
        .await
    }

    /// Make a GET request (backward compatible with String errors)
    pub async fn get<T: for<'de> Deserialize<'de>>(&self, endpoint: &str) -> Result<T, String> {
        self.get_typed(endpoint).await.map_err(|e| e.to_string())
    }

    /// Make a GET request with query parameters.
    pub async fn get_with_params<T: for<'de> Deserialize<'de>>(
        &self,
        endpoint: &str,
        params: &[(&str, &str)],
    ) -> Result<T, String> {
        self.get_typed_with_params(endpoint, params)
            .await
            .map_err(|e| e.to_string())
    }

    pub async fn get_typed_with_params<T: for<'de> Deserialize<'de>>(
        &self,
        endpoint: &str,
        params: &[(&str, &str)],
    ) -> Result<T, AlpacaError> {
        let endpoint = endpoint.to_string();
        let params: Vec<(String, String)> = params
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();

        self.execute_with_retry(|| {
            let endpoint = endpoint.clone();
            let params = params.clone();
            async move {
                let (client_id, transaction_id) = self.client_transaction();
                let url = self.build_url(&endpoint);
                let mut query: Vec<(&str, String)> = vec![
                    ("ClientID", client_id.to_string()),
                    ("ClientTransactionID", transaction_id.to_string()),
                ];
                for (key, value) in &params {
                    query.push((key.as_str(), value.clone()));
                }

                let response = self
                    .standard_http_client()?
                    .get(&url)
                    .query(&query)
                    .send()
                    .await?;

                let status = response.status();
                if !status.is_success() {
                    let retry_after = parse_retry_after_header(response.headers());
                    let body = response.text().await?;
                    return Err(AlpacaError::HttpError {
                        status: status.as_u16(),
                        message: body,
                        retry_after,
                    });
                }

                let alpaca_response: AlpacaResponse<T> = response.json().await?;
                if alpaca_response.error_number != 0 {
                    return Err(AlpacaError::DeviceError {
                        code: alpaca_response.error_number,
                        message: alpaca_response.error_message,
                    });
                }

                Ok(alpaca_response.value)
            }
        })
        .await
    }

    /// Make a PUT request with typed error handling
    pub async fn put_typed<T: DeserializeOwned + 'static>(
        &self,
        endpoint: &str,
        params: &[(&str, &str)],
    ) -> Result<T, AlpacaError> {
        let endpoint = endpoint.to_string();
        let params: Vec<(String, String)> = params
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();

        self.execute_with_retry(|| {
            let endpoint = endpoint.clone();
            let params = params.clone();
            async move {
                let (client_id, transaction_id) = self.client_transaction();
                let url = self.build_url(&endpoint);

                let mut form_params: Vec<(&str, String)> = vec![
                    ("ClientID", client_id.to_string()),
                    ("ClientTransactionID", transaction_id.to_string()),
                ];

                for (key, value) in &params {
                    form_params.push((key.as_str(), value.clone()));
                }

                let response = self
                    .standard_http_client()?
                    .put(&url)
                    .form(&form_params)
                    .send()
                    .await?;

                let status = response.status();
                if !status.is_success() {
                    let retry_after = parse_retry_after_header(response.headers());
                    let body = response.text().await?;
                    return Err(AlpacaError::HttpError {
                        status: status.as_u16(),
                        message: body,
                        retry_after,
                    });
                }

                decode_put_response::<T>(response.json().await?)
            }
        })
        .await
    }

    /// Make a PUT request (backward compatible with String errors)
    pub async fn put<T: DeserializeOwned + 'static>(
        &self,
        endpoint: &str,
        params: &[(&str, &str)],
    ) -> Result<T, String> {
        self.put_typed(endpoint, params)
            .await
            .map_err(|e| e.to_string())
    }

    /// Make a quick GET request with shorter timeout (no retry)
    pub async fn get_quick<T: for<'de> Deserialize<'de>>(
        &self,
        endpoint: &str,
    ) -> Result<T, AlpacaError> {
        let client = self.create_quick_timeout_client()?;
        let (client_id, transaction_id) = self.client_transaction();
        let url = format!(
            "{}?ClientID={}&ClientTransactionID={}",
            self.build_url(endpoint),
            client_id,
            transaction_id
        );

        let response = client.get(&url).send().await?;

        let status = response.status();
        if !status.is_success() {
            let retry_after = parse_retry_after_header(response.headers());
            let body = response.text().await?;
            return Err(AlpacaError::HttpError {
                status: status.as_u16(),
                message: body,
                retry_after,
            });
        }

        let alpaca_response: AlpacaResponse<T> = response.json().await?;

        if alpaca_response.error_number != 0 {
            return Err(AlpacaError::DeviceError {
                code: alpaca_response.error_number,
                message: alpaca_response.error_message,
            });
        }

        Ok(alpaca_response.value)
    }

    /// Make a long-running PUT request with extended timeout
    /// Use for operations like slewing, parking, and shutter control
    pub async fn put_long<T: DeserializeOwned + 'static>(
        &self,
        endpoint: &str,
        params: &[(&str, &str)],
    ) -> Result<T, AlpacaError> {
        let client = self.create_long_timeout_client()?;
        let (client_id, transaction_id) = self.client_transaction();
        let url = self.build_url(endpoint);

        let mut form_params: Vec<(&str, String)> = vec![
            ("ClientID", client_id.to_string()),
            ("ClientTransactionID", transaction_id.to_string()),
        ];

        for (key, value) in params {
            form_params.push((key, value.to_string()));
        }

        let response = client
            .put(&url)
            .form(&form_params)
            .send()
            .await
            .map_err(|e| {
                if e.is_timeout() {
                    AlpacaError::timeout(endpoint, self.timeout_config.long_operation_ms)
                } else {
                    e.into()
                }
            })?;

        let status = response.status();
        if !status.is_success() {
            let retry_after = parse_retry_after_header(response.headers());
            let body = response.text().await?;
            return Err(AlpacaError::HttpError {
                status: status.as_u16(),
                message: body,
                retry_after,
            });
        }

        decode_put_response::<T>(response.json().await?)
    }

    /// Make a very long-running PUT request with extended timeout
    /// Use for operations like full dome rotation, image downloads, etc.
    pub async fn put_very_long<T: DeserializeOwned + 'static>(
        &self,
        endpoint: &str,
        params: &[(&str, &str)],
    ) -> Result<T, AlpacaError> {
        let client = self.create_very_long_timeout_client()?;
        let (client_id, transaction_id) = self.client_transaction();
        let url = self.build_url(endpoint);

        let mut form_params: Vec<(&str, String)> = vec![
            ("ClientID", client_id.to_string()),
            ("ClientTransactionID", transaction_id.to_string()),
        ];

        for (key, value) in params {
            form_params.push((key, value.to_string()));
        }

        let response = client
            .put(&url)
            .form(&form_params)
            .send()
            .await
            .map_err(|e| {
                if e.is_timeout() {
                    AlpacaError::timeout(endpoint, self.timeout_config.very_long_operation_ms)
                } else {
                    e.into()
                }
            })?;

        let status = response.status();
        if !status.is_success() {
            let retry_after = parse_retry_after_header(response.headers());
            let body = response.text().await?;
            return Err(AlpacaError::HttpError {
                status: status.as_u16(),
                message: body,
                retry_after,
            });
        }

        decode_put_response::<T>(response.json().await?)
    }

    // Common device properties

    /// Check if the device is connected
    pub async fn is_connected(&self) -> Result<bool, String> {
        self.get("connected").await
    }

    /// Check if the device is connected (typed error)
    pub async fn is_connected_typed(&self) -> Result<bool, AlpacaError> {
        self.get_quick("connected").await
    }

    /// Connect to the device
    pub async fn connect(&self) -> Result<(), String> {
        self.connect_typed().await.map_err(|e| e.to_string())
    }

    /// Connect to the device (typed error)
    pub async fn connect_typed(&self) -> Result<(), AlpacaError> {
        // A successful setter response is not enough for a bridge-backed
        // device. The previous transport may still be finishing an async
        // disconnect and can flip the shared hardware connection back off
        // immediately after this PUT. Confirm the readback, and repeat the
        // idempotent connect when that handover race is observed.
        for attempt in 0..3 {
            self.put_typed::<()>("connected", &[("Connected", "true")])
                .await?;
            tokio::time::sleep(Duration::from_millis(250)).await;
            if self.is_connected_typed().await? {
                return Ok(());
            }
            if attempt < 2 {
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
        }
        Err(AlpacaError::ValidationFailed(
            "Connected=true succeeded, but the device still reports disconnected after 3 attempts"
                .to_string(),
        ))
    }

    /// Disconnect from the device
    pub async fn disconnect(&self) -> Result<(), String> {
        self.put::<()>("connected", &[("Connected", "false")]).await
    }

    /// Disconnect from the device (typed error)
    pub async fn disconnect_typed(&self) -> Result<(), AlpacaError> {
        self.put_typed::<()>("connected", &[("Connected", "false")])
            .await
    }

    /// Get the device name
    pub async fn get_name(&self) -> Result<String, String> {
        self.get("name").await
    }

    /// Get the device name (typed error)
    pub async fn get_name_typed(&self) -> Result<String, AlpacaError> {
        self.get_typed("name").await
    }

    /// Get the device description
    pub async fn get_description(&self) -> Result<String, String> {
        self.get("description").await
    }

    /// Get the device description (typed error)
    pub async fn get_description_typed(&self) -> Result<String, AlpacaError> {
        self.get_typed("description").await
    }

    /// Get the driver version
    pub async fn get_driver_version(&self) -> Result<String, String> {
        self.get("driverversion").await
    }

    /// Get the driver version (typed error)
    pub async fn get_driver_version_typed(&self) -> Result<String, AlpacaError> {
        self.get_typed("driverversion").await
    }

    /// Get the driver info
    pub async fn get_driver_info(&self) -> Result<String, String> {
        self.get("driverinfo").await
    }

    /// Get the interface version
    pub async fn get_interface_version(&self) -> Result<i32, String> {
        self.get("interfaceversion").await
    }

    /// Get supported actions
    pub async fn get_supported_actions(&self) -> Result<Vec<String>, String> {
        self.get("supportedactions").await
    }

    /// Validate that the connection is still alive and responding
    /// Performs a lightweight check that the device can process requests
    pub async fn validate_connection(&self) -> Result<bool, AlpacaError> {
        // Use a quick timeout for validation
        let client = self.create_quick_timeout_client()?;
        let (client_id, transaction_id) = self.client_transaction();
        let url = format!(
            "{}?ClientID={}&ClientTransactionID={}",
            self.build_url("connected"),
            client_id,
            transaction_id
        );

        match client.get(&url).send().await {
            Ok(response) => {
                if !response.status().is_success() {
                    return Err(AlpacaError::ValidationFailed(format!(
                        "HTTP status: {}",
                        response.status()
                    )));
                }

                let result: Result<AlpacaResponse<bool>, _> = response.json().await;
                match result {
                    Ok(alpaca_response) => {
                        if alpaca_response.error_number != 0 {
                            Err(AlpacaError::ValidationFailed(alpaca_response.error_message))
                        } else {
                            Ok(alpaca_response.value)
                        }
                    }
                    Err(e) => Err(AlpacaError::ValidationFailed(e.to_string())),
                }
            }
            Err(e) => {
                if e.is_timeout() {
                    Err(AlpacaError::timeout(
                        "connection validation",
                        self.timeout_config.quick_query_ms,
                    ))
                } else if e.is_connect() {
                    Err(AlpacaError::connection_refused(
                        &self.base_url,
                        e.to_string(),
                    ))
                } else {
                    Err(AlpacaError::ValidationFailed(e.to_string()))
                }
            }
        }
    }

    /// Send a heartbeat ping and return the round-trip time in milliseconds
    /// Uses the "connected" endpoint as a lightweight ping
    pub async fn heartbeat(&self) -> Result<u64, AlpacaError> {
        let start = std::time::Instant::now();

        let client = self.create_quick_timeout_client()?;
        let (client_id, transaction_id) = self.client_transaction();
        let url = format!(
            "{}?ClientID={}&ClientTransactionID={}",
            self.build_url("connected"),
            client_id,
            transaction_id
        );

        let response = client.get(&url).send().await?;

        if !response.status().is_success() {
            let retry_after = parse_retry_after_header(response.headers());
            return Err(AlpacaError::HttpError {
                status: response.status().as_u16(),
                message: "Heartbeat failed".to_string(),
                retry_after,
            });
        }

        // Consume the response body
        let _: AlpacaResponse<bool> = response.json().await?;

        let elapsed = start.elapsed();
        // Why: heartbeat-elapsed `as_millis()` returns
        // u128. Heartbeats time out in the seconds-range; u128 → u64
        // saturating fallback covers any pathological never-completing case
        // (which the timeout layer would have already cancelled).
        Ok(u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
    }

    /// Detect supported API versions from the server
    pub async fn detect_api_versions(&self) -> Result<Vec<u32>, AlpacaError> {
        let client = self.create_quick_timeout_client()?;
        let url = format!("{}/management/apiversions", self.base_url);

        match client.get(&url).send().await {
            Ok(response) => {
                if !response.status().is_success() {
                    let retry_after = parse_retry_after_header(response.headers());
                    return Err(AlpacaError::HttpError {
                        status: response.status().as_u16(),
                        message: "Failed to get API versions".to_string(),
                        retry_after,
                    });
                }

                let api_response: ApiVersionsResponse = response.json().await?;
                Ok(api_response.value)
            }
            Err(e) => {
                warn!("Failed to detect API versions: {}", e);
                // Default to v1 if detection fails
                Ok(vec![1])
            }
        }
    }

    /// Negotiate the best API version to use with the server
    pub async fn negotiate_api_version(&mut self) -> Result<ApiVersion, AlpacaError> {
        let versions = self.detect_api_versions().await?;

        // Currently we only support v1, but this framework allows future versions
        if let Some(version) = ApiVersion::negotiate(&versions) {
            self.api_version = version;
            Ok(version)
        } else {
            Err(AlpacaError::UnsupportedApiVersion(format!(
                "Server supports versions {:?}, but client only supports v1",
                versions
            )))
        }
    }
}
