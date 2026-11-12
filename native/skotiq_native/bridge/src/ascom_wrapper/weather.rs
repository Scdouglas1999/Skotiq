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
    /// The heartbeat's liveness read.
    GetInterfaceVersion(oneshot::Sender<Result<i32, String>>),
    SkyBrightness(oneshot::Sender<Result<f64, String>>),
    WindGust(oneshot::Sender<Result<f64, String>>),
    StarFwhm(oneshot::Sender<Result<f64, String>>),
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
                        let _ = reply.send(weather.connect().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::Disconnect(reply) => {
                        let _ = reply.send(weather.disconnect().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::Temperature(reply) => {
                        let _ = reply.send(weather.temperature().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::Humidity(reply) => {
                        let _ = reply.send(weather.humidity().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::Pressure(reply) => {
                        let _ = reply.send(weather.pressure().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::CloudCover(reply) => {
                        let _ = reply.send(weather.cloud_cover().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::DewPoint(reply) => {
                        let _ = reply.send(weather.dew_point().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::WindSpeed(reply) => {
                        let _ = reply.send(weather.wind_speed().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::WindDirection(reply) => {
                        let _ = reply.send(weather.wind_direction().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::SkyQuality(reply) => {
                        let _ = reply.send(weather.sky_quality().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::SkyTemperature(reply) => {
                        let _ = reply.send(weather.sky_temperature().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::RainRate(reply) => {
                        let _ = reply.send(weather.rain_rate().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::GetInterfaceVersion(reply) => {
                        let _ = reply.send(weather.interface_version().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::SkyBrightness(reply) => {
                        let _ = reply.send(weather.sky_brightness().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::WindGust(reply) => {
                        let _ = reply.send(weather.wind_gust().map_err(|e| e.to_string()));
                    }
                    AscomWeatherCommand::StarFwhm(reply) => {
                        let _ = reply.send(weather.star_fwhm().map_err(|e| e.to_string()));
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

    pub async fn connect(&self) -> Result<(), String> {
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

    pub async fn disconnect(&self) -> Result<(), String> {
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

    pub async fn sky_brightness(&self) -> Result<f64, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomWeatherCommand::SkyBrightness(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "sky_brightness").await
    }

    pub async fn wind_gust(&self) -> Result<f64, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomWeatherCommand::WindGust(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "wind_gust").await
    }

    /// Seeing, as the FWHM of a star in arc seconds.
    pub async fn star_fwhm(&self) -> Result<f64, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomWeatherCommand::StarFwhm(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "star_fwhm").await
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
}
