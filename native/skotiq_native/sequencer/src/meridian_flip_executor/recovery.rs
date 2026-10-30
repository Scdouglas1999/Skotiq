//! Acquisition recovery after the mount has already reached its intended side.
use super::*;

impl MeridianFlipExecutor {
    pub(super) async fn plate_solve_and_center(&self, ctx: &FlipContext) -> Result<(), String> {
        if ctx.simulate {
            return Ok(());
        }
        let extended = self.attempts_made > 1;
        let wheel = ctx
            .autofocus_config
            .as_ref()
            .and_then(|a| a.filterwheel_id.as_deref());
        // Read the actual slot, not the plan's next filter. Always restore it,
        // including failed solving and cancellation, before releasing capture.
        if extended && self.original_recovery_filter.lock().is_none() {
            if let Some(id) = wheel {
                let position = self.device_ops.filterwheel_get_position(id).await?;
                *self.original_recovery_filter.lock() = Some((id.to_string(), position));
            }
        }
        let original = self.original_recovery_filter.lock().clone();
        let result = async {
            if let Some(id) = wheel.filter(|_| extended) {
                let names = self.device_ops.filterwheel_get_names(id).await?;
                if let Some(index) = names.iter().position(|name| {
                    matches!(name.trim().to_ascii_lowercase().as_str(), "l" | "lum" | "luminance")
                }) {
                    self.recovery_filter(id, index as i32 + 1).await?;
                }
            }
            let exposure = if extended { 15.0 } else { 5.0 };
            let result = self.center_attempts(ctx, exposure).await;
            if result.is_ok()
                || self.is_cancelled(ctx)
                || self.attempts_made != self.config.max_retries + 1
                || !extended
            {
                return result;
            }
            self.warn_operator("Target acquisition still failed; trying one nearby higher field to correct pointing before returning.".into());
            self.nearby_pointing_reference(ctx).await.map_err(|e| {
                format!("{}; nearby recovery: {e}", result.unwrap_err())
            })?;
            self.center_attempts(ctx, 15.0).await
        }
        .await;
        if let Some((id, position)) = original {
            if let Err(error) = self.recovery_filter(&id, position).await {
                return Err(format!(
                    "Could not restore the science filter: {error}; recovery result: {result:?}"
                ));
            }
        }
        result
    }

    async fn recovery_filter(&self, id: &str, position: i32) -> Result<(), String> {
        // Cleanup uses this too, so cancellation cannot skip restoration.
        tokio::time::timeout(std::time::Duration::from_secs(120), async {
            self.device_ops
                .filterwheel_set_position(id, position)
                .await?;
            loop {
                if self.device_ops.filterwheel_get_position(id).await? == position {
                    return Ok(());
                }
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            }
        })
        .await
        .map_err(|_| "Filter wheel did not reach its recovery position in 120s".to_string())?
    }

    async fn nearby_pointing_reference(&self, ctx: &FlipContext) -> Result<(), String> {
        let (lat, lon) = self
            .device_ops
            .get_observer_location()
            .ok_or("Cannot attempt nearby-field recovery without an observing location")?;
        let now = chrono::Utc::now();
        let (alt, az) =
            meridian::calculate_alt_az(ctx.target_ra_hours, ctx.target_dec_degrees, lat, lon, now);
        if !(10.0..75.0).contains(&alt) {
            return Err(
                "No higher recovery field available between the horizon and zenith limits".into(),
            );
        }
        let (ra, dec) = meridian::alt_az_to_ra_dec((alt + 15.0).min(80.0), az, lat, lon, now);
        let original_side = self.get_pier_side(&ctx.mount_id).await?;
        if matches!(original_side, PierSide::Unknown) {
            return Err("Nearby recovery requires a known pier side".into());
        }
        let result = async {
            self.slew_to_target(ctx, ra, dec).await?;
            self.wait_for_mount_to_settle(ctx).await?;
            if self.is_cancelled(ctx) {
                return Err("Recovery cancelled".into());
            }
            if self.get_pier_side(&ctx.mount_id).await? != original_side {
                return Err("Nearby recovery changed pier side; refusing to sync".into());
            }
            let camera = ctx.camera_id.as_deref().ok_or("No camera configured")?;
            let image = self.device_ops.camera_start_exposure(camera, 15.0, None, None, 1, 1).await?;
            let solved = self.recovery_solve(ctx, &image, ra * 15.0, dec).await?;
            if !solved.success || !solved.ra_degrees.is_finite() || !(-90.0..=90.0).contains(&solved.dec_degrees) {
                return Err("Nearby recovery field did not solve".into());
            }
            let dec = dec.to_radians();
            let solved_dec = solved.dec_degrees.to_radians();
            let delta_ra = (ra * 15.0 - solved.ra_degrees).to_radians();
            let separation = (dec.sin() * solved_dec.sin() + dec.cos() * solved_dec.cos() * delta_ra.cos())
                .clamp(-1.0, 1.0).acos().to_degrees();
            if separation > 5.0 {
                return Err(format!("Nearby solution is {separation:.2} degrees from the requested field; refusing to sync"));
            }
            self.device_ops.mount_sync(&ctx.mount_id, solved.ra_degrees / 15.0, solved.dec_degrees).await
                .map_err(|e| format!("Nearby-field sync unavailable or failed: {e}"))
        }
        .await;
        // A failed probe must not leave the telescope aimed at the probe field.
        // A user Stop, however, must not start another slew.
        if self.is_cancelled(ctx) {
            return Err("Recovery cancelled".into());
        }
        self.slew_to_target(ctx, ctx.target_ra_hours, ctx.target_dec_degrees)
            .await?;
        self.confirm_tracking(ctx).await?;
        if self.get_pier_side(&ctx.mount_id).await? != original_side {
            return Err(
                "Recovery return changed pier side; target acquisition remains unverified".into(),
            );
        }
        result
    }

    pub(super) async fn recovery_solve(
        &self,
        ctx: &FlipContext,
        image: &crate::device_ops::ImageData,
        ra: f64,
        dec: f64,
    ) -> Result<crate::device_ops::PlateSolveResult, String> {
        let solve = tokio::time::timeout(
            std::time::Duration::from_secs(60),
            self.device_ops
                .plate_solve(image, Some(ra), Some(dec), None),
        );
        tokio::pin!(solve);
        loop {
            tokio::select! {
                result = &mut solve => return result.map_err(|_| "Recovery plate solve timed out after 60s".to_string())?,
                _ = tokio::time::sleep(std::time::Duration::from_millis(200)) => {
                    if self.is_cancelled(ctx) {
                return Err("Recovery cancelled".into());
            }
                }
            }
        }
    }

    /// Reacquire after a probe without ever requesting another meridian flip.
    /// The caller owns the imaging train until this returns and handles failure.
    pub(crate) async fn recover_target(&mut self, ctx: &FlipContext) -> Result<(), String> {
        if self.config.max_retries > 0 && self.config.retry_delays_secs.is_empty() {
            return Err("Target recovery configuration error: retry_delays_secs is empty".into());
        }
        *self.original_recovery_filter.lock() = None;
        let mut problem = String::new();
        for attempt in 1..=self.config.max_retries + 1 {
            self.attempts_made = attempt;
            if self.is_cancelled(ctx) {
                return Err("Recovery cancelled".into());
            }
            let result = async {
                self.pause_guider(ctx).await?;
                self.confirm_tracking(ctx).await?;
                self.plate_solve_and_center(ctx).await?;
                if self.config.resume_guiding {
                    self.resume_guider(ctx).await?;
                }
                Ok(())
            }
            .await;
            match result {
                Ok(()) => return Ok(()),
                Err(e) => problem = e,
            }
            if attempt <= self.config.max_retries {
                let delay = self
                    .config
                    .retry_delays_secs
                    .get((attempt - 1) as usize)
                    .or_else(|| self.config.retry_delays_secs.last())
                    .copied()
                    .ok_or("Target recovery configuration error: retry_delays_secs is empty")?;
                self.warn_operator(format!("Target recovery attempt {attempt} failed: {problem}. Retrying in {delay:.0}s; light capture remains held."));
                let until = tokio::time::Instant::now() + std::time::Duration::from_secs_f64(delay);
                while tokio::time::Instant::now() < until {
                    if self.is_cancelled(ctx) {
                        return Err("Recovery cancelled".into());
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                }
            }
        }
        Err(problem)
    }
}
