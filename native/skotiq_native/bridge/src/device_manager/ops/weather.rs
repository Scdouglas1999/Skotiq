//! Weather (observing conditions) operations dispatcher.
//!
//! Methods in this module are an additional impl block on `DeviceManager`
//! using Rust's split-impl-block feature. Behavior is identical to the
//! previous monolithic `devices.rs`.

use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use skotiq_indi::{IndiWeather, DEFAULT_WEATHER_STALE_MS};
use std::time::Duration;

async fn indi_weather_conditions(
    device_id: &str,
    weather: &IndiWeather,
    max_age: Duration,
) -> Result<WeatherConditions, DeviceOpError> {
    if weather.has_weather_parameters().await && weather.is_parameters_stale(max_age).await {
        return Err(DeviceOpError::hardware(
            Some(device_id.to_string()),
            format!(
                "INDI weather parameters for {} are stale or have never updated",
                device_id
            ),
        ));
    }

    Ok(WeatherConditions {
        temperature: weather.get_temperature().await,
        humidity: weather.get_humidity().await,
        pressure: weather.get_pressure().await,
        cloud_cover: weather.get_cloud_cover().await,
        dew_point: weather.get_dew_point().await,
        wind_speed: weather.get_wind_speed().await,
        wind_direction: weather.get_wind_direction().await,
        sky_quality: weather.get_sky_quality().await,
        sky_temperature: weather.get_sky_temperature().await,
        rain_rate: weather.get_rain_rate().await,
    })
}

impl DeviceManager {
    // Weather (observing conditions)

    /// Get weather conditions
    pub async fn weather_get_conditions(
        &self,
        device_id: &str,
    ) -> Result<WeatherConditions, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let weather_devs = self.alpaca_weather.read().await;
                if let Some(weather) = weather_devs.get(device_id) {
                    return Ok(WeatherConditions {
                        temperature: weather.temperature().await.ok(),
                        humidity: weather.humidity().await.ok(),
                        pressure: weather.pressure().await.ok(),
                        cloud_cover: weather.cloud_cover().await.ok(),
                        dew_point: weather.dew_point().await.ok(),
                        wind_speed: weather.wind_speed().await.ok(),
                        wind_direction: weather.wind_direction().await.ok(),
                        sky_quality: weather.sky_quality().await.ok(),
                        sky_temperature: weather.sky_temperature().await.ok(),
                        rain_rate: weather.rain_rate().await.ok(),
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca weather device {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                let client = clients.get(&server_key).cloned();
                drop(clients);

                if let Some(client) = client {
                    let weather = IndiWeather::new(client, &device_name);
                    return indi_weather_conditions(
                        device_id,
                        &weather,
                        Duration::from_millis(DEFAULT_WEATHER_STALE_MS),
                    )
                    .await;
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI weather device not connected",
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let weather_devices = self.ascom_weather.read().await;
                    if let Some(weather) = weather_devices.get(device_id) {
                        let weather_guard = weather.read().await;
                        return Ok(WeatherConditions {
                            temperature: weather_guard.temperature().await.ok(),
                            humidity: weather_guard.humidity().await.ok(),
                            pressure: weather_guard.pressure().await.ok(),
                            cloud_cover: weather_guard.cloud_cover().await.ok(),
                            dew_point: weather_guard.dew_point().await.ok(),
                            wind_speed: weather_guard.wind_speed().await.ok(),
                            wind_direction: weather_guard.wind_direction().await.ok(),
                            sky_quality: weather_guard.sky_quality().await.ok(),
                            sky_temperature: weather_guard.sky_temperature().await.ok(),
                            rain_rate: weather_guard.rain_rate().await.ok(),
                        });
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM weather device {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM is only available on Windows",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native weather device not connected",
            )),
            Some(DriverType::Simulator) => {
                let weather = crate::api::devices::simulation::get_sim_weather()
                    .read()
                    .await;
                if !weather.connected {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Simulator weather device not connected",
                    ));
                }
                Ok(weather.conditions.clone())
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_manager::ManagedDevice;
    use crate::state::AppState;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn build_weather_info(id: &str) -> DeviceInfo {
        DeviceInfo {
            id: id.to_string(),
            name: "Test Weather".to_string(),
            device_type: DeviceType::Weather,
            driver_type: DriverType::Indi,
            description: "Test INDI weather station".to_string(),
            driver_version: "1.0".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: "Test Weather".to_string(),
        }
    }

    async fn connect_fake_weather(
        xml: &'static str,
        device_name: &'static str,
    ) -> (
        std::sync::Arc<DeviceManager>,
        String,
        tokio::task::JoinHandle<()>,
    ) {
        let manager = DeviceManager::new(AppState::new());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind fake INDI weather server");
        let port = listener.local_addr().expect("read listener address").port();
        let device_id = format!("indi:127.0.0.1:{}:{}", port, device_name);

        manager.devices.write().await.insert(
            device_id.clone(),
            ManagedDevice {
                info: build_weather_info(&device_id),
                connection_state: ConnectionState::Connected,
                last_error: None,
                reconnect_attempts: 0,
                auto_reconnect: false,
                last_successful_comm: None,
                heartbeat_active: false,
                api_version: None,
                desired_cooler: None,
                desired_tracking: None,
            },
        );

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept INDI client");
            let mut buf = vec![0_u8; 4096];
            let _ = socket
                .read(&mut buf)
                .await
                .expect("read initial getProperties");
            socket.write_all(xml.as_bytes()).await.expect("write XML");
            tokio::time::sleep(Duration::from_secs(2)).await;
        });

        let timeout_config = skotiq_indi::IndiTimeoutConfig {
            connection_timeout_secs: 1,
            ..Default::default()
        };
        let mut client =
            skotiq_indi::IndiClient::with_timeout_config("127.0.0.1", Some(port), timeout_config);
        client.connect().await.expect("connect fake INDI client");

        manager.indi_clients.write().await.insert(
            format!("127.0.0.1:{}", port),
            std::sync::Arc::new(tokio::sync::RwLock::new(client)),
        );

        (manager, device_id, server)
    }

    async fn wait_for_weather_property(manager: &DeviceManager, device_id: &str) {
        let (host, port, device_name) =
            DeviceManager::parse_indi_device_id(device_id).expect("test id is a valid INDI id");
        let server_key = format!("{host}:{port}");
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);

        loop {
            let client = {
                let clients = manager.indi_clients.read().await;
                clients.get(&server_key).cloned()
            }
            .expect("fake INDI client should be registered");

            if client
                .read()
                .await
                .has_property(&device_name, "WEATHER_PARAMETERS")
                .await
            {
                break;
            }

            assert!(
                tokio::time::Instant::now() < deadline,
                "fake INDI WEATHER_PARAMETERS property was not parsed in time"
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    #[tokio::test]
    async fn indi_weather_conditions_reject_stale_parameters() {
        let xml = r#"
<defNumberVector device="Weather Station" name="WEATHER_PARAMETERS" state="Idle" perm="ro">
  <defNumber name="WEATHER_TEMPERATURE">12.5</defNumber>
  <defNumber name="WEATHER_HUMIDITY">55</defNumber>
</defNumberVector>
"#;
        let (manager, device_id, server) = connect_fake_weather(xml, "Weather Station").await;
        wait_for_weather_property(&manager, &device_id).await;

        let (host, port, _device_name) =
            DeviceManager::parse_indi_device_id(&device_id).expect("test id is a valid INDI id");
        let server_key = format!("{host}:{port}");
        let clients = manager.indi_clients.read().await;
        let client = clients.get(&server_key).cloned();
        drop(clients);
        let client = client.expect("fake INDI client should be registered");
        let weather = IndiWeather::new(client, "Weather Station");

        tokio::time::sleep(Duration::from_millis(5)).await;
        let err = indi_weather_conditions(&device_id, &weather, Duration::from_millis(1))
            .await
            .expect_err("stale weather parameters must fail closed");

        assert!(
            err.to_string().contains("stale") || err.to_string().contains("never updated"),
            "unexpected weather staleness error: {}",
            err
        );
        server.await.expect("fake INDI server should finish");
    }

    #[tokio::test]
    async fn indi_weather_conditions_accept_fresh_parameters() {
        let xml = r#"
<defNumberVector device="Weather Station" name="WEATHER_PARAMETERS" state="Idle" perm="ro">
  <defNumber name="WEATHER_TEMPERATURE">0</defNumber>
  <defNumber name="WEATHER_HUMIDITY">0</defNumber>
</defNumberVector>
<setNumberVector device="Weather Station" name="WEATHER_PARAMETERS" state="Ok">
  <oneNumber name="WEATHER_TEMPERATURE">12.5</oneNumber>
  <oneNumber name="WEATHER_HUMIDITY">55</oneNumber>
  <oneNumber name="WEATHER_PRESSURE">1001.2</oneNumber>
</setNumberVector>
"#;
        let (manager, device_id, server) = connect_fake_weather(xml, "Weather Station").await;
        wait_for_weather_property(&manager, &device_id).await;

        let conditions = manager
            .weather_get_conditions(&device_id)
            .await
            .expect("fresh weather parameters should be returned");

        assert_eq!(conditions.temperature, Some(12.5));
        assert_eq!(conditions.humidity, Some(55.0));
        assert_eq!(conditions.pressure, Some(1001.2));
        server.await.expect("fake INDI server should finish");
    }
}
