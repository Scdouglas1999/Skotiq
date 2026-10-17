use super::*;

/// Builder for creating AlpacaClient with custom configuration
pub struct AlpacaClientBuilder {
    device: AlpacaDevice,
    timeout_config: TimeoutConfig,
    retry_config: RetryConfig,
}

impl AlpacaClientBuilder {
    pub fn new(device: AlpacaDevice) -> Self {
        Self {
            device,
            timeout_config: TimeoutConfig::default(),
            retry_config: RetryConfig::default(),
        }
    }

    pub fn timeout_config(mut self, config: TimeoutConfig) -> Self {
        self.timeout_config = config;
        self
    }

    pub fn retry_config(mut self, config: RetryConfig) -> Self {
        self.retry_config = config;
        self
    }

    pub fn quick_query_timeout(mut self, ms: u64) -> Self {
        self.timeout_config.quick_query_ms = ms;
        self
    }

    pub fn standard_timeout(mut self, ms: u64) -> Self {
        self.timeout_config.standard_operation_ms = ms;
        self
    }

    pub fn long_timeout(mut self, ms: u64) -> Self {
        self.timeout_config.long_operation_ms = ms;
        self
    }

    pub fn connect_timeout(mut self, ms: u64) -> Self {
        self.timeout_config.connect_ms = ms;
        self
    }

    pub fn max_retry_attempts(mut self, attempts: u32) -> Self {
        self.retry_config.max_attempts = attempts;
        self
    }

    pub fn no_retry(mut self) -> Self {
        self.retry_config = RetryConfig::no_retry();
        self
    }

    pub fn build(self) -> AlpacaClient {
        AlpacaClient::with_config(&self.device, self.timeout_config, self.retry_config)
    }
}
