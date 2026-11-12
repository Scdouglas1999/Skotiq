use super::*;

pub(crate) const EXPOSURE_COMPLETION_MARGIN: std::time::Duration =
    std::time::Duration::from_secs(60);

pub(crate) static EXPOSURE_ABORT_GENERATIONS: OnceLock<Mutex<HashMap<String, u64>>> =
    OnceLock::new();

pub(crate) fn exposure_abort_generations() -> &'static Mutex<HashMap<String, u64>> {
    EXPOSURE_ABORT_GENERATIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) async fn exposure_abort_generation(camera_id: &str) -> u64 {
    *exposure_abort_generations()
        .lock()
        .await
        .get(camera_id)
        .unwrap_or(&0)
}

/// Invalidate the in-flight acquisition before issuing a hardware abort.
///
/// Some camera SDKs report a terminal Success immediately after StopExposure.
/// Without a generation check the original task then downloads and publishes
/// that aborted buffer as a valid image.
pub(crate) async fn mark_camera_exposure_aborted(camera_id: &str) {
    let mut generations = exposure_abort_generations().lock().await;
    let entry = generations.entry(camera_id.to_string()).or_default();
    *entry = entry.wrapping_add(1);
}

pub(crate) fn exposure_completion_timeout(duration_secs: f64) -> std::time::Duration {
    std::time::Duration::from_secs_f64(duration_secs.max(0.0)) + EXPOSURE_COMPLETION_MARGIN
}

/// [acquisition_generation] is the abort generation read when this acquisition
/// started. Once it moves the operator has aborted, and this returns
/// immediately: a driver that answers "not complete" for an exposure it has
/// already been told to stop would otherwise keep this loop publishing
/// `ExposureProgress` until the duration+margin deadline, so the preview went
/// on counting down a frame that was never going to arrive.
pub(crate) async fn wait_for_camera_exposure_complete<F, Fut>(
    camera_id: &str,
    duration_secs: f64,
    timeout_after: std::time::Duration,
    acquisition_generation: u64,
    app_state: &SharedAppState,
    mut is_complete: F,
) -> DeviceResult<()>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<bool, String>>,
{
    let start_time = std::time::Instant::now();
    let exposure = std::time::Duration::from_secs_f64(duration_secs.max(0.0));
    let mut reading_out = false;
    let mut poller: AdaptivePoller<bool> = AdaptivePoller::from_preset(PollerPreset::Exposure);

    loop {
        if exposure_abort_generation(camera_id).await != acquisition_generation {
            return Ok(());
        }
        let elapsed_now = start_time.elapsed();
        if elapsed_now >= timeout_after {
            return Err(DeviceError::Timeout(format!(
                "Exposure on {} did not complete within {:.1}s timeout ({:.1}s requested exposure plus safety margin)",
                camera_id,
                timeout_after.as_secs_f64(),
                duration_secs
            )));
        }
        let remaining = timeout_after - elapsed_now;

        // Bound each status poll by the remaining deadline. Without this the
        // deadline check above is only reached BETWEEN polls, so a status call
        // that itself stalls (USB hiccup, or contention on a shared vendor SDK
        // mutex held by a slow/wedged download) would never return control to
        // the check and the advertised timeout could never fire. With the
        // per-poll bound the overall deadline stays authoritative.
        match tokio::time::timeout(remaining, is_complete()).await {
            Ok(Ok(true)) => return Ok(()),
            Ok(Ok(false)) => {}
            Ok(Err(e)) => return Err(format!("Failed to check exposure status: {}", e).into()),
            Err(_) => {
                return Err(DeviceError::Timeout(format!(
                    "Exposure status poll on {} did not return within the {:.1}s deadline ({:.1}s requested exposure plus safety margin)",
                    camera_id,
                    timeout_after.as_secs_f64(),
                    duration_secs
                )));
            }
        }

        let elapsed = start_time.elapsed();
        let progress = if duration_secs > 0.0 {
            (elapsed.as_secs_f64() / duration_secs).min(1.0)
        } else {
            1.0
        };
        let remaining_secs = (duration_secs - elapsed.as_secs_f64()).max(0.0);

        app_state.publish_imaging_event(
            ImagingEvent::ExposureProgress {
                progress,
                remaining_secs,
            },
            EventSeverity::Info,
        );

        // Reaching this point means the current poll observed "not complete";
        // a completed exposure returns immediately above. The backoff never
        // sleeps past the end of the exposure: the poll lands when the shutter
        // closes, and from there the readout is polled from the base interval
        // again, so a frame is fetched when it is ready rather than up to a
        // whole backed-off interval later.
        let until_exposure_end = exposure.saturating_sub(start_time.elapsed());
        let wait = if until_exposure_end.is_zero() {
            if !reading_out {
                reading_out = true;
                poller.reset();
            }
            poller.tick(&false)
        } else {
            poller.tick(&false).min(until_exposure_end)
        };
        let remaining_timeout = timeout_after.saturating_sub(start_time.elapsed());
        tokio::time::sleep(wait.min(remaining_timeout)).await;
    }
}

/// Own the sensor from configuration through download. A second consumer must
/// never replace an exposure or read its buffer, even if its UI state is stale.
static CAMERA_ACQUISITIONS: OnceLock<Mutex<HashMap<String, Arc<Mutex<()>>>>> = OnceLock::new();

pub(crate) async fn camera_acquisition_in_progress(camera_id: &str) -> bool {
    let owners = CAMERA_ACQUISITIONS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .await;
    owners
        .get(camera_id)
        .is_some_and(|owner| owner.try_lock().is_err())
}

pub(crate) async fn claim_camera_acquisition(
    camera_id: &str,
) -> DeviceResult<tokio::sync::OwnedMutexGuard<()>> {
    let owner = CAMERA_ACQUISITIONS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .await
        .entry(camera_id.to_owned())
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone();
    owner.try_lock_owned().map_err(|_| {
        format!(
            "Camera {} is busy acquiring or downloading another frame; wait for it to finish",
            camera_id
        )
        .into()
    })
}

#[cfg(test)]
mod wait_tests {
    use super::*;

    /// The poll backs off to 2 s during a long exposure; without the cap the
    /// completion of a 2 s exposure was seen at 2.64 s.
    #[tokio::test]
    async fn an_exposure_is_collected_when_it_ends_not_a_backoff_later() {
        let started = std::time::Instant::now();
        let duration = 2.0;
        wait_for_camera_exposure_complete(
            "wait-test-camera",
            duration,
            exposure_completion_timeout(duration),
            exposure_abort_generation("wait-test-camera").await,
            crate::api::get_state(),
            || async move { Ok(started.elapsed().as_secs_f64() >= duration) },
        )
        .await
        .expect("exposure completes");
        let seen = started.elapsed().as_secs_f64();
        assert!(
            seen < duration + 0.25,
            "a {duration} s exposure was collected after {seen:.2} s"
        );
    }
}

#[cfg(test)]
mod readout_tests {
    use super::*;

    /// A camera that reports its frame 0.3 s after the shutter closes: the
    /// first poll at the end of the exposure sees "not ready", and the next
    /// one must come from the base interval, not the 2 s backoff.
    #[tokio::test]
    async fn a_frame_ready_shortly_after_the_exposure_is_collected_within_the_base_polls() {
        let started = std::time::Instant::now();
        let (duration, readout) = (3.0, 0.3);
        wait_for_camera_exposure_complete(
            "readout-test-camera",
            duration,
            exposure_completion_timeout(duration),
            exposure_abort_generation("readout-test-camera").await,
            crate::api::get_state(),
            || async move { Ok(started.elapsed().as_secs_f64() >= duration + readout) },
        )
        .await
        .expect("exposure completes");
        let seen = started.elapsed().as_secs_f64();
        assert!(
            seen < duration + readout + 0.5,
            "a frame ready at {:.1} s was collected after {seen:.2} s",
            duration + readout
        );
    }
}

#[cfg(test)]
mod ownership_tests {
    use super::*;

    #[tokio::test]
    async fn competing_consumer_cannot_claim_sensor_until_download_finishes() {
        let sequence = claim_camera_acquisition("ownership-camera").await.unwrap();
        assert!(claim_camera_acquisition("ownership-camera").await.is_err());
        let ops = create_unified_device_ops();
        let competing_capture = ops
            .camera_start_exposure(skotiq_sequencer::ExposureRequest::new(
                "ownership-camera",
                5.0,
            ))
            .await;
        assert!(competing_capture
            .unwrap_err()
            .to_string()
            .contains("busy acquiring or downloading"));
        let other_camera = claim_camera_acquisition("other-camera").await.unwrap();
        assert!(camera_acquisition_in_progress("ownership-camera").await);
        drop(sequence);
        assert!(!camera_acquisition_in_progress("ownership-camera").await);
        assert!(claim_camera_acquisition("ownership-camera").await.is_ok());
        drop(other_camera);
    }
}
