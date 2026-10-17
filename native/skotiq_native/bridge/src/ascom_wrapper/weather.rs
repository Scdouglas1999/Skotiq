use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomObservingConditions;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

enum AscomWeatherCommand {
    Connect(oneshot::Sender<Result<(), String>>),
    Disconnect(oneshot::Sender<Result<(), String>>),
    Temperature(oneshot::Sender<Result<f64, String>>),
    Humidity(oneshot::Sender<Result<f64, String>>),
    Pressure(oneshot::Sender<Result<f64, String>>),
    CloudCover(oneshot::Sender<Result<f64, String>>),
    DewPoint(oneshot::Sender<Result<f64, String>>),
    WindSpeed(oneshot::Sender<Result<f64, String>>),
    WindDirection(oneshot::Sender<Result<f64, String>>),
    SkyQuality(oneshot::Sender<Result<f64, String>>),
    SkyTemperature(oneshot::Sender<Result<f64, String>>),
    RainRate(oneshot::Sender<Result<f64, String>>),
    // ASCOM-Common metadata query commands. Mirrors the four
    // `InterfaceVersion` / `DriverVersion` / `DriverInfo` /
    // `SupportedActions` properties common to every ASCOM driver and is
    // consumed by `DeviceCommonMetadata` via `dispatch::ascom_device_common`.
    GetInterfaceVersion(oneshot::Sender<Result<i32, String>>),
    GetDriverVersion(oneshot::Sender<Result<String, String>>),
    GetDriverInfo(oneshot::Sender<Result<String, String>>),
    GetSupportedActions(oneshot::Sender<Result<Vec<String>, String>>),
}

pub struct AscomObservingConditionsWrapper {
    sender: mpsc::Sender<AscomWeatherCommand>,
    connected: AtomicBool,
}

impl AscomObservingConditionsWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (tx, mut rx) = mpsc::channel(32);
        let prog_id_clone = prog_id.clone();

        // Build the COM object and its command pump on the shared STA apartment.
        // A construction failure is propagated out of `register_device` so the
        // caller drops the wrapper, exactly as the legacy init-channel did.
        register_device(move || {
            let mut weather = match AscomObservingConditions::new(&prog_id_clone) {
                Ok(weather) => weather,
                Err(error) => {
                    return Err(format!(
                        "Failed to create ASCOM observing conditions device: {}",
                        error
                    ));
                }
            };

            Ok(Box::new(move || {
                use tokio::sync::mpsc::error::TryRecvError;
                let command = match rx.try_recv() {
                    Ok(command) => command,
                    Err(TryRecvError::Empty) => return PumpOutcome::Idle,
                    Err(TryRecvError::Disconnected) => {
                        // Why: COM teardown ordering — the typed
                        // `AscomObservingConditions` (and its IDispatch) is
                        // released when this closure is dropped, still on the STA
                        // worker thread that owns the apartment. The apartment
                        // persists for the process lifetime, so COM is NOT
                        // uninitialized here.
                        return PumpOutcome::Finished;
                    }
                };
                match command {
                    AscomWeatherCommand::Connect(reply) => {
                        let _ = reply.send(weather.connect());
                    }
                    AscomWeatherCommand::Disconnect(reply) => {
                        let _ = reply.send(weather.disconnect());
                    }
                    AscomWeatherCommand::Temperature(reply) => {
                        let _ = reply.send(weather.temperature());
                    }
                    AscomWeatherCommand::Humidity(reply) => {
                        let _ = reply.send(weather.humidity());
                    }
                    AscomWeatherCommand::Pressure(reply) => {
                        let _ = reply.send(weather.pressure());
                    }
                    AscomWeatherCommand::CloudCover(reply) => {
                        let _ = reply.send(weather.cloud_cover());
                    }
                    AscomWeatherCommand::DewPoint(reply) => {
                        let _ = reply.send(weather.dew_point());
                    }
                    AscomWeatherCommand::WindSpeed(reply) => {
                        let _ = reply.send(weather.wind_speed());
                    }
                    AscomWeatherCommand::WindDirection(reply) => {
                        let _ = reply.send(weather.wind_direction());
                    }
                    AscomWeatherCommand::SkyQuality(reply) => {
                        let _ = reply.send(weather.sky_quality());
                    }
                    AscomWeatherCommand::SkyTemperature(reply) => {
                        let _ = reply.send(weather.sky_temperature());
                    }
                    AscomWeatherCommand::RainRate(reply) => {
                        let _ = reply.send(weather.rain_rate());
                    }
                    AscomWeatherCommand::GetInterfaceVersion(reply) => {
                        let _ = reply.send(weather.interface_version());
                    }
                    AscomWeatherCommand::GetDriverVersion(reply) => {
                        let _ = reply.send(weather.driver_version());
                    }
                    AscomWeatherCommand::GetDriverInfo(reply) => {
                        let _ = reply.send(weather.driver_info());
                    }
                    AscomWeatherCommand::GetSupportedActions(reply) => {
                        let _ = reply.send(weather.supported_actions());
                    }
                }
                PumpOutcome::DidWork
            })
                as crate::ascom_wrapper::sta_worker::DevicePump)
        })?;

        Ok(Self {
            sender: tx,
            connected: AtomicBool::new(false),
        })
    }

    async fn recv_with_timeout<T>(
        rx: oneshot::Receiver<Result<T, String>>,
        timeout: Duration,
        operation: &str,
    ) -> Result<T, String> {
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(format!("Worker thread dead during {}", operation)),
            Err(_) => Err(format!(
                "Weather {} timed out after {:?}",
                operation, timeout
            )),
        }
    }

    pub async fn connect(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomWeatherCommand::Connect(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        let result = Self::recv_with_timeout(rx, Timeouts::connection(), "connect").await;
        if result.is_ok() {
            self.connected.store(true, Ordering::SeqCst);
        }
        result
    }

    pub async fn disconnect(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomWeatherCommand::Disconnect(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        let result = Self::recv_with_timeout(rx, Timeouts::connection(), "disconnect").await;
        if result.is_ok() {
            self.connected.store(false, Ordering::SeqCst);
        }
        result
    }

    pub async fn temperature(&self) -> Result<f64, String> {
        self.read_float(AscomWeatherCommand::Temperature, "temperature")
            .await
    }

    pub async fn humidity(&self) -> Result<f64, String> {
        self.read_float(AscomWeatherCommand::Humidity, "humidity")
            .await
    }

    pub async fn pressure(&self) -> Result<f64, String> {
        self.read_float(AscomWeatherCommand::Pressure, "pressure")
            .await
    }

    pub async fn cloud_cover(&self) -> Result<f64, String> {
        self.read_float(AscomWeatherCommand::CloudCover, "cloud_cover")
            .await
    }

    pub async fn dew_point(&self) -> Result<f64, String> {
        self.read_float(AscomWeatherCommand::DewPoint, "dew_point")
            .await
    }

    pub async fn wind_speed(&self) -> Result<f64, String> {
        self.read_float(AscomWeatherCommand::WindSpeed, "wind_speed")
            .await
    }

    pub async fn wind_direction(&self) -> Result<f64, String> {
        self.read_float(AscomWeatherCommand::WindDirection, "wind_direction")
            .await
    }

    pub async fn sky_quality(&self) -> Result<f64, String> {
        self.read_float(AscomWeatherCommand::SkyQuality, "sky_quality")
            .await
    }

    pub async fn sky_temperature(&self) -> Result<f64, String> {
        self.read_float(AscomWeatherCommand::SkyTemperature, "sky_temperature")
            .await
    }

    pub async fn rain_rate(&self) -> Result<f64, String> {
        self.read_float(AscomWeatherCommand::RainRate, "rain_rate")
            .await
    }

    async fn read_float(
        &self,
        build_command: impl FnOnce(oneshot::Sender<Result<f64, String>>) -> AscomWeatherCommand,
        operation: &str,
    ) -> Result<f64, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(build_command(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), operation).await
    }

    /// Returns the ASCOM `InterfaceVersion` integer (ASCOM-Common §IAscomDriverV1).
    pub async fn interface_version(&self) -> Result<i32, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomWeatherCommand::GetInterfaceVersion(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "interface_version").await
    }

    /// Returns the ASCOM `DriverVersion` free-form vendor version string (ASCOM-Common §IAscomDriverV1).
    pub async fn driver_version(&self) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomWeatherCommand::GetDriverVersion(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_version").await
    }

    /// Returns the ASCOM `DriverInfo` vendor description string (ASCOM-Common §IAscomDriverV1).
    pub async fn driver_info(&self) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomWeatherCommand::GetDriverInfo(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_info").await
    }

    /// Returns the list of custom action names from ASCOM `SupportedActions` (ASCOM-Common §ISupportedActions, V2+ optional).
    pub async fn supported_actions(&self) -> Result<Vec<String>, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomWeatherCommand::GetSupportedActions(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "supported_actions").await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    fn build_test_wrapper<F>(handler: F) -> AscomObservingConditionsWrapper
    where
        F: FnMut(AscomWeatherCommand) -> bool + Send + 'static,
    {
        let (tx, mut rx) = mpsc::channel(8);
        let _handle = thread::spawn(move || {
            let mut handler = handler;
            while let Some(cmd) = crate::ascom_wrapper::pump_blocking_recv(&mut rx) {
                if handler(cmd) {
                    break;
                }
            }
        });
        AscomObservingConditionsWrapper {
            sender: tx,
            connected: AtomicBool::new(false),
        }
    }

    #[tokio::test]
    async fn interface_version_returns_worker_value() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomWeatherCommand::GetInterfaceVersion(reply) = cmd {
                let _ = reply.send(Ok(2));
            }
            false
        });
        assert_eq!(wrapper.interface_version().await.expect("ok"), 2);
    }

    #[tokio::test]
    async fn driver_version_returns_worker_value() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomWeatherCommand::GetDriverVersion(reply) = cmd {
                let _ = reply.send(Ok("7.0".to_string()));
            }
            false
        });
        assert_eq!(wrapper.driver_version().await.expect("ok"), "7.0");
    }

    #[tokio::test]
    async fn driver_info_returns_worker_value() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomWeatherCommand::GetDriverInfo(reply) = cmd {
                let _ = reply.send(Ok("Acme Sky Quality Meter".to_string()));
            }
            false
        });
        assert_eq!(
            wrapper.driver_info().await.expect("ok"),
            "Acme Sky Quality Meter"
        );
    }

    #[tokio::test]
    async fn supported_actions_returns_worker_value() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomWeatherCommand::GetSupportedActions(reply) = cmd {
                let _ = reply.send(Ok(vec!["Refresh".to_string()]));
            }
            false
        });
        let actions = wrapper.supported_actions().await.expect("ok");
        assert_eq!(actions, vec!["Refresh".to_string()]);
    }

    #[tokio::test]
    async fn supported_actions_propagates_property_not_implemented_error() {
        // ASCOM 1.x drivers without `ISupportedActions` raise
        // `PropertyNotImplementedException`. The wrapper passes the error
        // through unchanged; `fetch_api_version` is responsible for the
        // documented silent-fallback-to-empty-Vec policy at the dispatch layer.
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomWeatherCommand::GetSupportedActions(reply) = cmd {
                let _ = reply.send(Err("PropertyNotImplemented".to_string()));
            }
            false
        });
        assert!(wrapper.supported_actions().await.is_err());
    }
}
