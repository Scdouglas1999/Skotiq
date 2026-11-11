//! Weather (observing conditions) operations.

use crate::device::*;
use crate::device_manager::handle::device_error;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;

impl DeviceManager {
    /// What the weather station reports; a sensor it does not have is `None`.
    pub async fn weather_get_conditions(
        &self,
        device_id: &str,
    ) -> Result<WeatherConditions, DeviceOpError> {
        let r = self
            .weather(device_id)
            .await?
            .readings()
            .await
            .map_err(|e| device_error(device_id, e))?;
        Ok(WeatherConditions {
            temperature: r.temperature,
            humidity: r.humidity,
            pressure: r.pressure,
            cloud_cover: r.cloud_cover,
            dew_point: r.dew_point,
            wind_speed: r.wind_speed,
            wind_direction: r.wind_direction,
            sky_quality: r.sky_quality,
            sky_temperature: r.sky_temperature,
            rain_rate: r.rain_rate,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_manager::handle::DeviceHandle;
    use crate::device_manager::ManagedDevice;
    use crate::state::AppState;
    use skotiq_indi::IndiWeather;
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
                heartbeat_deferred_at: None,
                heartbeat_active: false,
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

        let client = std::sync::Arc::new(tokio::sync::RwLock::new(client));
        manager
            .indi_clients
            .write()
            .await
            .insert(format!("127.0.0.1:{}", port), client.clone());
        manager.handles.insert(
            &device_id,
            DeviceHandle::Weather(std::sync::Arc::new(IndiWeather::new(client, device_name))),
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
        let err = weather
            .readings_within(Duration::from_millis(1))
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
