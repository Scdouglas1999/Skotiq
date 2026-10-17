//! Keepalive, connection-health, reconnect and version negotiation.

use super::*;

impl IndiClient {
    /// Send keepalive to detect dead connections (atomic operation)
    ///
    /// This method is safe to call concurrently due to atomic guards.
    pub(super) async fn send_keepalive(&mut self) -> IndiResult<()> {
        // Update timestamp atomically BEFORE sending
        self.last_keepalive_ms
            .store(current_time_ms(), Ordering::SeqCst);

        // Use configured protocol version
        let version = &self.protocol_config.preferred_version;
        self.send_command(&format!("<getProperties version=\"{}\"/>", version))
            .await
    }

    /// Check if keepalive is needed and send it (atomic operations to prevent race)
    ///
    /// This method provides race-safe keepalive checking:
    /// 1. Uses compare_exchange to prevent overlapping keepalive checks
    /// 2. Skips keepalive during reconnection to avoid false disconnects
    /// 3. Checks for keepalive response timeout
    ///
    /// Returns Ok(()) if keepalive was sent or not needed
    /// Returns Err if keepalive response timeout was detected (connection may be dead)
    pub async fn check_keepalive(&mut self) -> IndiResult<()> {
        // Skip keepalive if not connected
        if !self.connected.load(Ordering::SeqCst) {
            return Ok(());
        }

        // Skip keepalive if reconnection is in progress
        // This prevents false disconnection events during reconnection attempts
        if self.reconnecting.load(Ordering::SeqCst) {
            tracing::debug!("Skipping keepalive: reconnection in progress");
            return Ok(());
        }

        // Use compare_exchange to atomically acquire the keepalive lock
        // This prevents overlapping keepalive checks if previous check didn't complete
        if self
            .keepalive_in_progress
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            // Another keepalive is already in progress, skip this one
            tracing::debug!("Skipping keepalive: another keepalive check is in progress");
            return Ok(());
        }

        // Ensure we release the lock when done (using a scope guard pattern)
        let result = self.do_keepalive_check().await;

        // Release the keepalive lock
        self.keepalive_in_progress.store(false, Ordering::SeqCst);

        result
    }

    /// Internal keepalive check logic (called while holding keepalive_in_progress lock)
    pub(super) async fn do_keepalive_check(&mut self) -> IndiResult<()> {
        let keepalive_interval_ms = self.timeout_config.keepalive_interval_secs * 1000;
        let keepalive_timeout_ms = keepalive_interval_ms * 2; // Response timeout is 2x interval
        let current_ms = current_time_ms();

        // Check if we haven't received any response in too long (connection may be dead)
        let last_response_ms = self.last_keepalive_response_ms.load(Ordering::SeqCst);
        let time_since_last_response = current_ms.saturating_sub(last_response_ms);

        if time_since_last_response > keepalive_timeout_ms {
            tracing::warn!(
                "Keepalive response timeout: no response in {} ms (timeout: {} ms)",
                time_since_last_response,
                keepalive_timeout_ms
            );
            // Don't emit disconnect event here - let the reader task handle that
            // Just return an error so caller knows connection may be dead
            return Err(IndiError::OperationTimeout {
                operation: "keepalive".to_string(),
                device: None,
                property: None,
                duration: Duration::from_millis(time_since_last_response),
                context: format!(
                    "No keepalive response received in {} ms",
                    time_since_last_response
                ),
            });
        }

        // Check if enough time has passed since last keepalive was SENT
        let last_sent_ms = self.last_keepalive_ms.load(Ordering::SeqCst);
        if current_ms.saturating_sub(last_sent_ms) >= keepalive_interval_ms {
            self.send_keepalive().await?;
        }

        Ok(())
    }

    /// Check if a keepalive is currently in progress
    pub fn is_keepalive_in_progress(&self) -> bool {
        self.keepalive_in_progress.load(Ordering::SeqCst)
    }

    /// Get the time in milliseconds since the last keepalive response was received
    pub fn time_since_last_keepalive_response_ms(&self) -> u64 {
        current_time_ms().saturating_sub(self.last_keepalive_response_ms.load(Ordering::SeqCst))
    }

    /// Check if the connection is considered healthy based on keepalive responses
    ///
    /// Returns true if we've received a response within 2x the keepalive interval
    pub fn is_connection_healthy(&self) -> bool {
        if !self.connected.load(Ordering::SeqCst) {
            return false;
        }

        let keepalive_timeout_ms = self.timeout_config.keepalive_interval_secs * 1000 * 2;
        self.time_since_last_keepalive_response_ms() < keepalive_timeout_ms
    }

    /// Attempt to reconnect with exponential backoff and jitter
    ///
    /// This method sets the `reconnecting` flag to prevent false disconnection
    /// events from keepalive checks during the reconnection process.
    pub async fn reconnect_with_backoff(&mut self) -> IndiResult<()> {
        let max_attempts = self.reconnection_config.max_attempts;
        let mut last_error = String::new();

        // Set reconnecting flag to skip keepalive checks during reconnection.
        // The guard clears it, and the attempt counter, however this ends —
        // including when the caller's future is dropped mid-backoff.
        self.reconnecting.store(true, Ordering::SeqCst);
        let _in_progress = RecoveryInProgress {
            reconnecting: self.reconnecting.clone(),
            reconnect_attempts: self.reconnect_attempts.clone(),
            reader_status: None,
        };

        async {
            for attempt in 1..=max_attempts {
                self.reconnect_attempts.store(attempt, Ordering::SeqCst);

                tracing::info!(
                    "Reconnection attempt {}/{} to {}:{}",
                    attempt,
                    max_attempts,
                    self.host,
                    self.port
                );

                match self.connect().await {
                    Ok(_) => {
                        tracing::info!("Successfully reconnected to {}:{}", self.host, self.port);
                        self.reconnect_attempts.store(0, Ordering::SeqCst);
                        return Ok(());
                    }
                    Err(e) => {
                        last_error = e.to_string();
                        tracing::warn!("Reconnection attempt {} failed: {}", attempt, last_error);

                        if attempt < max_attempts {
                            let delay = self
                                .reconnection_config
                                .calculate_delay(attempt, &self.jitter_rng);
                            tracing::info!("Waiting {:?} before next reconnection attempt", delay);
                            sleep(delay).await;
                        }
                    }
                }
            }

            Err(IndiError::ReconnectionFailed {
                attempts: max_attempts,
                last_error,
            })
        }
        .await
    }

    /// Check if reconnection is currently in progress
    pub fn is_reconnecting(&self) -> bool {
        self.reconnecting.load(Ordering::SeqCst)
    }

    /// Attempt to recover from a reader crash with proper supervision
    ///
    /// This method should be called when receiving a `ReaderRestarting` event.
    /// It will:
    /// 1. Wait for the suggested delay (based on failure count and backoff)
    /// 2. Attempt to reconnect
    /// 3. Emit appropriate events on success/failure
    ///
    /// Note: Sets the `reconnecting` flag to prevent false disconnection events
    /// from keepalive checks during the recovery process.
    ///
    /// Returns Ok(()) if reconnection succeeds, Err if it fails.
    pub async fn recover_reader(&mut self) -> IndiResult<()> {
        // Check if we've already exceeded max failures
        if self.is_reader_failed_permanently() {
            let failures = self.reader_consecutive_failures();
            return Err(IndiError::ReconnectionFailed {
                attempts: failures,
                last_error: "Exceeded maximum consecutive reader failures".to_string(),
            });
        }

        // Set reconnecting flag to skip keepalive checks during recovery. The
        // guard clears it however this ends, and moves a reader still marked
        // Restarting to Crashed: a heartbeat stopped or restarted while this
        // slept its restart delay drops the future before either line below
        // runs, and both markers make `can_reconnect()` refuse for good.
        self.reconnecting.store(true, Ordering::SeqCst);
        let _in_progress = RecoveryInProgress {
            reconnecting: self.reconnecting.clone(),
            reconnect_attempts: self.reconnect_attempts.clone(),
            reader_status: Some(self.reader_status.clone()),
        };

        // Get current failure count for delay calculation
        let failures = self.reader_consecutive_failures();

        // Update status to Restarting
        *self.reader_status.write().await = ReaderStatus::Restarting;
        send_indi_event(
            &self.event_tx,
            IndiEvent::ReaderHealthChanged {
                healthy: false,
                status: ReaderStatus::Restarting,
                consecutive_failures: failures,
            },
            "recover_reader.reader_health_restarting",
        );

        // Calculate and wait for delay
        if failures > 0 {
            let delay = self
                .reader_task_config
                .calculate_restart_delay(failures, &self.jitter_rng);
            tracing::info!(
                "Waiting {:?} before reader recovery attempt {}",
                delay,
                failures
            );
            sleep(delay).await;
        }

        // Attempt to reconnect
        match self.connect().await {
            Ok(_) => {
                tracing::info!("Reader recovery successful after {} attempts", failures);
                send_indi_event(
                    &self.event_tx,
                    IndiEvent::ReaderRestarted {
                        attempts_used: failures,
                    },
                    "recover_reader.reader_restarted",
                );
                Ok(())
            }
            Err(e) => {
                tracing::error!("Reader recovery failed: {}", e);
                // The reader is no longer "Restarting" — the restart failed and
                // nothing is coming back on its own. The status has to say so,
                // because `can_reconnect()` refuses to recover a client sitting
                // in Restarting: leaving it there wedges the flag false for the
                // lifetime of the client, so one failed recovery would strand a
                // server that comes back a minute later. Crashed is what the
                // supervised reader task records for the same condition.
                //
                // The consecutive-failure counter is deliberately NOT bumped
                // here. When connect() fails at the TCP layer the reader task
                // never spawns, so nothing else counts this attempt — but
                // counting it would trip `is_reader_failed_permanently()` after
                // five heartbeats and refuse recovery for good. The retry
                // cadence belongs to the heartbeat interval, not to a one-way
                // failure budget.
                *self.reader_status.write().await = ReaderStatus::Crashed;
                send_indi_event(
                    &self.event_tx,
                    IndiEvent::ReaderHealthChanged {
                        healthy: false,
                        status: ReaderStatus::Crashed,
                        consecutive_failures: self.reader_consecutive_failures(),
                    },
                    "recover_reader.reader_health_crashed",
                );
                Err(e)
            }
        }
    }

    /// Check if a reconnection is safe (not already in progress)
    ///
    /// Returns false if:
    /// - Already connected
    /// - Reader is in Restarting state
    /// - A reconnection is in progress (reconnecting flag is set)
    /// - A reconnection attempt counter is non-zero
    pub async fn can_reconnect(&self) -> bool {
        if self.connected.load(Ordering::SeqCst) {
            return false;
        }

        // Check if reconnection is already in progress
        if self.reconnecting.load(Ordering::SeqCst) {
            return false;
        }

        let status = *self.reader_status.read().await;
        if status == ReaderStatus::Restarting {
            return false;
        }

        let reconnect_attempts = self.reconnect_attempts.load(Ordering::SeqCst);
        reconnect_attempts == 0
    }

    /// Get the number of reconnection attempts
    pub async fn reconnect_attempts(&self) -> u32 {
        self.reconnect_attempts.load(Ordering::SeqCst)
    }

    /// Request protocol version info from server
    pub async fn request_version(&mut self) -> IndiResult<()> {
        self.send_command("<getProperties version=\"\"/>").await
    }

    /// Check if server version is compatible with minimum required version
    pub async fn check_version_compatibility(&self) -> IndiResult<()> {
        if let Some(ref min_version) = self.protocol_config.min_version {
            if let Some(server_ver) = self.server_version().await {
                if !is_version_compatible(&server_ver, min_version) {
                    return Err(IndiError::VersionMismatch {
                        required: min_version.clone(),
                        server: server_ver,
                    });
                }
            }
        }
        Ok(())
    }
}

/// Marks a reconnect or reader recovery as in progress and clears the markers
/// when it ends, by return or by being dropped mid-await.
///
/// Every marker left behind makes `can_reconnect()` refuse, and the heartbeat
/// is the only thing that retries: a stale `reconnecting` flag, a non-zero
/// attempt counter after the attempts ran out, or a reader still Restarting
/// after its recovery was cancelled each stranded the server for the rest of
/// the night, although it answered again a minute later.
struct RecoveryInProgress {
    reconnecting: Arc<AtomicBool>,
    reconnect_attempts: Arc<AtomicU32>,
    reader_status: Option<Arc<RwLock<ReaderStatus>>>,
}

impl Drop for RecoveryInProgress {
    fn drop(&mut self) {
        self.reconnecting.store(false, Ordering::SeqCst);
        self.reconnect_attempts.store(0, Ordering::SeqCst);
        if let Some(status) = &self.reader_status {
            // Nothing else holds this lock across an await, so the write is
            // free here; if it were not, the holder is setting the status.
            if let Ok(mut status) = status.try_write() {
                if *status == ReaderStatus::Restarting {
                    *status = ReaderStatus::Crashed;
                }
            }
        }
    }
}
