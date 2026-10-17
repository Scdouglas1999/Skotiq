use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomSwitch;
use std::fmt::Debug;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

#[derive(Debug)]
enum AscomSwitchCommand {
    Connect(oneshot::Sender<Result<(), String>>),
    Disconnect(oneshot::Sender<Result<(), String>>),
    GetMaxSwitch(oneshot::Sender<Result<i32, String>>),
    GetSwitch(i32, oneshot::Sender<Result<bool, String>>),
    SetSwitch(i32, bool, oneshot::Sender<Result<(), String>>),
    GetSwitchName(i32, oneshot::Sender<Result<String, String>>),
    GetSwitchDescription(i32, oneshot::Sender<Result<String, String>>),
    GetSwitchValue(i32, oneshot::Sender<Result<f64, String>>),
    SetSwitchValue(i32, f64, oneshot::Sender<Result<(), String>>),
    GetMinSwitchValue(i32, oneshot::Sender<Result<f64, String>>),
    GetMaxSwitchValue(i32, oneshot::Sender<Result<f64, String>>),
    CanWrite(i32, oneshot::Sender<Result<bool, String>>),
    // Version query commands
    GetInterfaceVersion(oneshot::Sender<Result<i32, String>>),
    GetDriverVersion(oneshot::Sender<Result<String, String>>),
    GetDriverInfo(oneshot::Sender<Result<String, String>>),
    GetSupportedActions(oneshot::Sender<Result<Vec<String>, String>>),
}

pub struct AscomSwitchWrapper {
    id: String,
    name: String,
    sender: mpsc::Sender<AscomSwitchCommand>,
    max_switch: i32,
}

impl Debug for AscomSwitchWrapper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AscomSwitchWrapper")
            .field("id", &self.id)
            .field("name", &self.name)
            .field("max_switch", &self.max_switch)
            .finish()
    }
}

impl AscomSwitchWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (tx, mut rx) = mpsc::channel(32);
        let prog_id_clone = prog_id.clone();

        // The friendly `Name` and `MaxSwitch` count are read at construction
        // (before connect) and ferried back to `new()` over this channel.
        // `register_device` owns the success/error signalling; this side channel
        // only carries the construction-time property payload the legacy init
        // channel returned.
        let (info_tx, info_rx) = std::sync::mpsc::channel();

        // Build the COM object and its command pump on the shared STA apartment.
        // A construction failure is propagated out of `register_device` so the
        // caller drops the wrapper, exactly as the legacy init-channel did.
        register_device(move || {
            let mut switch = match AscomSwitch::new(&prog_id_clone) {
                Ok(s) => s,
                Err(e) => {
                    return Err(format!("Failed to create ASCOM switch: {}", e));
                }
            };

            // Get static properties.
            // Why: `name` and `max_switch` are optional
            // ASCOM ISwitchV2 properties; absence means "the driver did not
            // expose a friendly name (use ProgID)" / "the driver does not
            // declare any switches (treat as 0-count empty array)". The UI
            // then renders the device as "ProgID — 0 switches" which is
            // the correct presentation; the user can refresh after the
            // driver finishes initialising.
            let name = switch.name().unwrap_or_else(|_| prog_id_clone.clone());
            let max_switch = switch.max_switch().unwrap_or(0);
            let _ = info_tx.send((name, max_switch));

            Ok(Box::new(move || {
                use tokio::sync::mpsc::error::TryRecvError;
                let cmd = match rx.try_recv() {
                    Ok(cmd) => cmd,
                    Err(TryRecvError::Empty) => return PumpOutcome::Idle,
                    Err(TryRecvError::Disconnected) => {
                        // Why: COM teardown ordering — the typed `AscomSwitch`
                        // (and its IDispatch) is released when this closure is
                        // dropped, still on the STA worker thread that owns the
                        // apartment. The apartment persists for the process
                        // lifetime, so COM is NOT uninitialized here.
                        return PumpOutcome::Finished;
                    }
                };
                match cmd {
                    AscomSwitchCommand::Connect(reply) => {
                        let _ = reply.send(switch.connect());
                    }
                    AscomSwitchCommand::Disconnect(reply) => {
                        let _ = reply.send(switch.disconnect());
                    }
                    AscomSwitchCommand::GetMaxSwitch(reply) => {
                        let _ = reply.send(switch.max_switch());
                    }
                    AscomSwitchCommand::GetSwitch(id, reply) => {
                        let _ = reply.send(switch.get_switch(id));
                    }
                    AscomSwitchCommand::SetSwitch(id, state, reply) => {
                        let _ = reply.send(switch.set_switch(id, state));
                    }
                    AscomSwitchCommand::GetSwitchName(id, reply) => {
                        let _ = reply.send(switch.get_switch_name(id));
                    }
                    AscomSwitchCommand::GetSwitchDescription(id, reply) => {
                        let _ = reply.send(switch.get_switch_description(id));
                    }
                    AscomSwitchCommand::GetSwitchValue(id, reply) => {
                        let _ = reply.send(switch.get_switch_value(id));
                    }
                    AscomSwitchCommand::SetSwitchValue(id, value, reply) => {
                        let _ = reply.send(switch.set_switch_value(id, value));
                    }
                    AscomSwitchCommand::GetMinSwitchValue(id, reply) => {
                        let _ = reply.send(switch.min_switch_value(id));
                    }
                    AscomSwitchCommand::GetMaxSwitchValue(id, reply) => {
                        let _ = reply.send(switch.max_switch_value(id));
                    }
                    AscomSwitchCommand::CanWrite(id, reply) => {
                        let _ = reply.send(switch.can_write(id));
                    }
                    AscomSwitchCommand::GetInterfaceVersion(reply) => {
                        let _ = reply.send(switch.interface_version());
                    }
                    AscomSwitchCommand::GetDriverVersion(reply) => {
                        let _ = reply.send(switch.driver_version());
                    }
                    AscomSwitchCommand::GetDriverInfo(reply) => {
                        let _ = reply.send(switch.driver_info());
                    }
                    AscomSwitchCommand::GetSupportedActions(reply) => {
                        let _ = reply.send(switch.supported_actions());
                    }
                }
                PumpOutcome::DidWork
            })
                as crate::ascom_wrapper::sta_worker::DevicePump)
        })?;

        // The construction-time `(name, max_switch)` was sent on `info_tx` before
        // the factory returned, so this receive completes immediately once
        // `register_device` reports the device ready.
        let (name, max_switch) = info_rx
            .recv()
            .map_err(|e| format!("Failed to receive device properties: {}", e))?;

        Ok(Self {
            id: prog_id.clone(),
            name,
            sender: tx,
            max_switch,
        })
    }

    /// Helper to receive a response with a timeout
    async fn recv_with_timeout<T>(
        rx: oneshot::Receiver<Result<T, String>>,
        timeout: Duration,
        operation: &str,
    ) -> Result<T, String> {
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_recv_err)) => Err(format!("Worker thread dead during {}", operation)),
            Err(_elapsed) => Err(format!(
                "Switch {} timed out after {:?}",
                operation, timeout
            )),
        }
    }

    pub async fn connect(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::Connect(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::connection(), "connect").await
    }

    pub async fn disconnect(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::Disconnect(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::connection(), "disconnect").await
    }

    pub async fn get_max_switch(&self) -> Result<i32, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::GetMaxSwitch(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_max_switch").await
    }

    pub async fn get_switch(&self, id: i32) -> Result<bool, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::GetSwitch(id, tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_switch").await
    }

    pub async fn set_switch(&mut self, id: i32, state: bool) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::SetSwitch(id, state, tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_switch").await
    }

    pub async fn get_switch_name(&self, id: i32) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::GetSwitchName(id, tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_switch_name").await
    }

    pub async fn get_switch_description(&self, id: i32) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::GetSwitchDescription(id, tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_switch_description").await
    }

    pub async fn get_switch_value(&self, id: i32) -> Result<f64, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::GetSwitchValue(id, tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_switch_value").await
    }

    pub async fn set_switch_value(&mut self, id: i32, value: f64) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::SetSwitchValue(id, value, tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_switch_value").await
    }

    pub async fn get_min_switch_value(&self, id: i32) -> Result<f64, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::GetMinSwitchValue(id, tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_min_switch_value").await
    }

    pub async fn get_max_switch_value(&self, id: i32) -> Result<f64, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::GetMaxSwitchValue(id, tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_max_switch_value").await
    }

    pub async fn can_write(&self, id: i32) -> Result<bool, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::CanWrite(id, tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "can_write").await
    }

    /// Get the ASCOM interface version number
    pub async fn interface_version(&self) -> Result<i32, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::GetInterfaceVersion(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "interface_version").await
    }

    /// Get the driver version string
    pub async fn driver_version(&self) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::GetDriverVersion(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_version").await
    }

    /// Get the driver info/description
    pub async fn driver_info(&self) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::GetDriverInfo(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_info").await
    }

    /// Get the list of supported actions
    pub async fn supported_actions(&self) -> Result<Vec<String>, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSwitchCommand::GetSupportedActions(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "supported_actions").await
    }
}
