//! The command handler: drains ExecutorCommand messages for the life of the
//! run and applies each to the shared run state (pause/resume, stop, skip,
//! runtime-config edits, plugin-node replies).

use super::*;

pub(super) struct CommandHandlerArgs {
    pub cloud_motion_for_recovery: Arc<RwLock<CloudMotionSnapshot>>,
    pub conditions_score_for_cmd: Arc<RwLock<Option<crate::scheduling::ConditionsScore>>>,
    pub current_recovery_for_cmd: Arc<StdRwLock<Option<crate::recovery::RecoveryContext>>>,
    pub default_adaptive_for_cmd: Arc<RwLock<Option<crate::scheduling::AdaptiveExposureConfig>>>,
    pub defect_map_apply_for_cmd: Arc<RwLock<Option<crate::executor::DefectMapApplyState>>>,
    pub event_tx: broadcast::Sender<ExecutorEvent>,
    pub is_cancelled: Arc<AtomicBool>,
    pub is_paused_cmd: Arc<AtomicBool>,
    pub plugin_node_pending_for_cmd: Arc<
        RwLock<
            HashMap<NodeId, tokio::sync::oneshot::Sender<crate::node::context::PluginNodeReply>>,
        >,
    >,
    pub progress_for_commands: Arc<StdRwLock<SequenceProgress>>,
    pub recovery_signals_cmd: Arc<crate::recovery::RecoverySignals>,
    pub resume_notify_cmd: Arc<tokio::sync::Notify>,
    pub rx: mpsc::Receiver<ExecutorCommand>,
    pub runtime_config: Arc<StdRwLock<RuntimeConfig>>,
    pub safety_fail_mode_for_cmd: Arc<StdRwLock<SafetyFailMode>>,
    pub skip_to_next_target_cmd: Arc<AtomicBool>,
    pub skip_to_node_cmd: Arc<StdRwLock<Option<NodeId>>>,
    pub sky_brightness_for_cmd: Arc<RwLock<Option<f64>>>,
    pub state: Arc<RwLock<ExecutorState>>,
    pub transparency_backup_for_cmd:
        Arc<RwLock<Option<crate::node::context::TransparencyBackupPlan>>>,
    pub transparency_for_cmd: Arc<RwLock<Option<f64>>>,
    pub trigger_manager: Arc<RwLock<TriggerManager>>,
}

pub(super) async fn run_command_handler(args: CommandHandlerArgs) {
    let CommandHandlerArgs {
        cloud_motion_for_recovery,
        conditions_score_for_cmd,
        current_recovery_for_cmd,
        default_adaptive_for_cmd,
        defect_map_apply_for_cmd,
        event_tx,
        is_cancelled,
        is_paused_cmd,
        plugin_node_pending_for_cmd,
        progress_for_commands,
        recovery_signals_cmd,
        resume_notify_cmd,
        mut rx,
        runtime_config,
        safety_fail_mode_for_cmd,
        skip_to_next_target_cmd,
        skip_to_node_cmd,
        sky_brightness_for_cmd,
        state,
        transparency_backup_for_cmd,
        transparency_for_cmd,
        trigger_manager,
    } = args;
    while let Some(cmd) = rx.recv().await {
        match cmd {
            ExecutorCommand::Pause => {
                is_paused_cmd.store(true, Ordering::Relaxed);
                *state.write().await = ExecutorState::Paused;
                // `SequencerState` is built from the progress
                // snapshot (`api/sequencer.rs`,
                // `From<SequenceProgress>`), NOT from the lock
                // above. Stamping only the lock is why
                // `POST /api/sequencer/pause` answered
                // `{"status":"paused"}` and the very next
                // `GET /api/sequencer/status` said
                // `"state":"running"` — reproduced on the Linux
                // appliance 2026-08-09. A remote operator, or an
                // unattended rig's watchdog, sees a healthy run
                // while the node tree is parked.
                progress_for_commands.write().state = ExecutorState::Paused;
                let _ = event_tx.send(ExecutorEvent::StateChanged(ExecutorState::Paused));
            }
            ExecutorCommand::Resume if current_recovery_for_cmd.read().is_some() => {
                // The node tree is frozen by a recovery ladder, not by a
                // pause, and unfreezing it would expose through the fault the
                // ladder is still fixing (a guide star not yet re-acquired).
                // Resume withdraws a pause placed during the ladder and
                // nothing more; Try now and Abort are the controls over the
                // ladder itself.
                *state.write().await = ExecutorState::Recovering;
                progress_for_commands.write().state = ExecutorState::Recovering;
                let _ = event_tx.send(ExecutorEvent::StateChanged(ExecutorState::Recovering));
                let _ = event_tx.send(ExecutorEvent::Warning {
                    message: "Recovery is still running, so the run stays frozen until it \
                              finishes. Use Try now or Abort recovery to act on it."
                        .to_string(),
                });
            }
            ExecutorCommand::Resume => {
                // A node may be parked on `resume_notify.notified()`; we have
                // to wake all waiters *before* flipping is_paused so the
                // resumed branch sees the new state without racing.
                is_paused_cmd.store(false, Ordering::Relaxed);
                resume_notify_cmd.notify_waiters();
                *state.write().await = ExecutorState::Running;
                // Symmetric with Pause above: without this the
                // snapshot would stay `Paused` forever and a
                // resumed run would report as paused — swapping
                // one untruth for its mirror image.
                progress_for_commands.write().state = ExecutorState::Running;
                let _ = event_tx.send(ExecutorEvent::StateChanged(ExecutorState::Running));
            }
            ExecutorCommand::Stop => {
                is_cancelled.store(true, Ordering::Relaxed);
                *state.write().await = ExecutorState::Stopping;
                let _ = event_tx.send(ExecutorEvent::StateChanged(ExecutorState::Stopping));
                // Keep the command future alive. Breaking here
                // lets this select! branch win and drops the
                // node-execution future before its hardware
                // cancellation cleanup can abort an exposure.
                // The shared cancellation flag makes execution
                // finish; that branch owns termination.
            }
            ExecutorCommand::Skip => {
                tracing::info!("Skip requested - advancing to next target");
                skip_to_next_target_cmd.store(true, Ordering::Relaxed);
            }
            ExecutorCommand::SkipToNode(node_id) => {
                // Implement SkipToNode for
                // real. Post the target id into the shared
                // slot; the next iteration of the node tree
                // walk will mark preceding siblings as
                // Skipped and continue executing from the
                // target. The request clears itself when
                // the target subtree is entered (see
                // RuntimeNode::execute_children_sequential).
                //
                // We deliberately accept the request even
                // mid-instruction: the long-running
                // instruction (e.g. an exposure burst)
                // continues to completion, then the parent
                // container observes the skip request and
                // jumps to the target on the NEXT child. A
                // user who wants to interrupt mid-burst
                // sends Stop first, then re-Starts with the
                // sequence trimmed.
                tracing::info!(
                    "[SKIP_TO_NODE] Received request for target node '{}'",
                    node_id
                );
                *skip_to_node_cmd.write() = Some(node_id.clone());
                let _ = event_tx.send(skip_to_node_accepted_event(node_id));
            }
            ExecutorCommand::UpdateDitherConfig {
                pixels,
                settle_pixels,
                settle_time,
                settle_timeout,
                ra_only,
            } => {
                // write through the shared Arc so the
                // change takes effect on the next dither without
                // requiring a sequence reload.
                {
                    let mut rc = runtime_config.write();
                    rc.dither.pixels = pixels;
                    rc.dither.settle_pixels = settle_pixels;
                    rc.dither.settle_time = settle_time;
                    rc.dither.settle_timeout = settle_timeout;
                    rc.dither.ra_only = ra_only;
                }
                {
                    let manager = trigger_manager.read().await;
                    let state_lock = manager.state();
                    state_lock.write().await.guider_settle = crate::GuiderSettle {
                        pixels: settle_pixels,
                        time_secs: settle_time,
                        timeout_secs: settle_timeout,
                    };
                }
                tracing::info!(
                "Runtime dither config updated: pixels={}, settle_pixels={}, settle_time={}, settle_timeout={}, ra_only={}",
                pixels, settle_pixels, settle_time, settle_timeout, ra_only
            );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "dither".to_string(),
                });
            }
            ExecutorCommand::UpdateLocation {
                latitude,
                longitude,
            } => {
                // write through the Arc and also push
                // into the trigger state so altitude-aware
                // triggers (AltitudeLimit, MeridianFlip hour-angle
                // calc) read the new value on their next poll.
                {
                    let mut rc = runtime_config.write();
                    rc.latitude = latitude;
                    rc.longitude = longitude;
                }
                {
                    let manager = trigger_manager.read().await;
                    let state_lock = manager.state();
                    let mut state = state_lock.write().await;
                    state.set_observer_location(latitude, longitude);
                }
                tracing::info!(
                    "Runtime location updated: lat={:?}, lon={:?}",
                    latitude,
                    longitude
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "location".to_string(),
                });
            }
            ExecutorCommand::UpdateMaxSunAltitude { degrees } => {
                // The threshold is written through the Arc AND patched into
                // the live trigger state: the daylight gate reads it through
                // the trigger-state handle, so both must agree before the
                // next slew / exposure. A `None`/non-finite push resolves to
                // the DEFAULT (-12°) so the gate never weakens.
                {
                    let mut rc = runtime_config.write();
                    rc.max_sun_altitude_degrees = degrees;
                }
                let effective = match degrees {
                    Some(v) if v.is_finite() => v,
                    _ => crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES,
                };
                {
                    let manager = trigger_manager.read().await;
                    let state_lock = manager.state();
                    let mut state = state_lock.write().await;
                    state.set_max_sun_altitude_degrees(effective);
                }
                tracing::info!(
                    "Runtime max Sun altitude (W1 daylight gate) updated: {:?} -> effective {:.1}°",
                    degrees,
                    effective
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "max_sun_altitude".to_string(),
                });
            }
            ExecutorCommand::UpdateFilterOffsets { offsets } => {
                // write through the Arc so the next
                // filter change reads the updated offsets.
                let count = offsets.len();
                {
                    let mut rc = runtime_config.write();
                    rc.filter_focus_offsets = offsets;
                }
                tracing::info!("Runtime filter focus offsets updated: {} entries", count);
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "filter_offsets".to_string(),
                });
            }
            ExecutorCommand::UpdateDefaultQualityCheck { check } => {
                // write through the shared Arc so the
                // next exposure's instruction context sees the
                // new default. Pre-existing per-node
                // `quality_check` settings still win.
                {
                    let mut rc = runtime_config.write();
                    rc.default_quality_check = check.clone();
                }
                tracing::info!(
                    "Runtime default_quality_check updated (active={})",
                    check.as_ref().map(|c| c.is_active()).unwrap_or(false)
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "default_quality_check".to_string(),
                });
            }
            ExecutorCommand::UpdateRejectFolderPath { path } => {
                // write through the shared Arc so the
                // next reject lands in the new folder.
                {
                    let mut rc = runtime_config.write();
                    rc.reject_folder_path = path.clone();
                }
                tracing::info!("Runtime reject_folder_path updated: {:?}", path);
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "reject_folder_path".to_string(),
                });
            }
            ExecutorCommand::UpdateObserverProfile { profile } => {
                // write through the shared Arc so the
                // next FITS save stamps real keywords.
                {
                    let mut rc = runtime_config.write();
                    rc.observer_profile = profile.clone();
                }
                tracing::info!(
                    "Runtime observer_profile updated: observer={:?}, telescope={:?}",
                    profile.observer_name,
                    profile.telescope_name
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "observer_profile".to_string(),
                });
            }
            ExecutorCommand::UpdateAutofocusInterval { every_n_frames } => {
                // write through runtime_config
                // AND patch the live trigger's `every_n_frames`
                // so the next AutofocusInterval evaluation sees
                // the new cadence without a sequence reload.
                {
                    let mut rc = runtime_config.write();
                    rc.autofocus_interval_frames = Some(every_n_frames);
                }
                {
                    let mut mgr = trigger_manager.write().await;
                    if let Some(trigger) = mgr.get_trigger_mut("autofocus_interval") {
                        if let TriggerType::AutofocusInterval {
                            every_n_frames: live,
                        } = &mut trigger.trigger_type
                        {
                            *live = every_n_frames;
                        }
                    }
                }
                tracing::info!(
                    "Runtime autofocus-interval cadence updated: every {} frames",
                    every_n_frames
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "autofocus_interval".to_string(),
                });
            }
            ExecutorCommand::RecoveryTryNow => {
                // Recovery Mode — flag the signal bus
                // so the next recovery driver tick fires an
                // immediate attempt instead of waiting for
                // the retry interval. Safe to issue from any
                // state; the driver only consumes the flag
                // while inside a recovery loop, so a stray
                // TryNow in Running is a documented no-op
                // (the operator sees the toast confirmation
                // and nothing else).
                recovery_signals_cmd.request_try_now();
                tracing::info!("[RECOVERY] TryNow requested by operator");
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "recovery_try_now".to_string(),
                });
            }
            ExecutorCommand::RecoveryAbort => {
                // Recovery Mode — flag the signal bus.
                // The recovery driver checks `take_abort()`
                // on every tick and exits the loop with a
                // GaveUp transition.
                recovery_signals_cmd.request_abort();
                tracing::info!("[RECOVERY] Abort requested by operator");
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "recovery_abort".to_string(),
                });
            }
            ExecutorCommand::UpdateSkyBrightness { mag } => {
                // push the latest live
                // sky-brightness reading into the shared
                // ExecutionContext field. Uses the
                // pre-cloned `sky_brightness_for_cmd`
                // Arc captured above so the closure does
                // not have to borrow `context` (which
                // collides with the root_node.execute
                // mutable borrow).
                {
                    let mut slot = sky_brightness_for_cmd.write().await;
                    *slot = mag;
                }
                tracing::debug!("Runtime sky brightness updated: {:?} mag/arcsec²", mag);
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "sky_brightness".to_string(),
                });
            }
            ExecutorCommand::UpdateDefaultAdaptiveExposure { config } => {
                // push the global default
                // sky-brightness adaptive-exposure config.
                // Per-node `ExposureConfig.adaptive_exposure`
                // still wins; this is the fallback consulted
                // when the node carries no own block.
                {
                    let mut rc = runtime_config.write();
                    rc.default_adaptive_exposure = config.clone();
                }
                let cfg_for_log = config.clone();
                {
                    let mut slot = default_adaptive_for_cmd.write().await;
                    *slot = config;
                }
                tracing::info!(
                    "Runtime default_adaptive_exposure updated (enabled={})",
                    cfg_for_log.as_ref().map(|c| c.enabled).unwrap_or(false)
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "default_adaptive_exposure".to_string(),
                });
            }
            ExecutorCommand::UpdateCloudMotion {
                current_cover_percent,
                predicted_arrival_minutes,
                predicted_opening_minutes,
                predicted_opening_duration_secs,
                predicted_clear_sky_alt,
                predicted_clear_sky_az,
            } => {
                // feed the trigger state from
                // the Dart-side cloud-motion analyzer. The
                // three cloud-aware triggers
                // (`CloudArrivingIn`, `CloudOpeningIn`,
                // `CloudCoverThreshold`) read these values on
                // their next evaluation tick. Lock the
                // trigger manager's state directly here so
                // the update is atomic with respect to a
                // concurrent evaluator pass.
                let clear_sky = match (predicted_clear_sky_alt, predicted_clear_sky_az) {
                    (Some(alt), Some(az)) => Some((alt, az)),
                    // Half-specified directions are
                    // ambiguous; refuse them rather than
                    // making up a default — that would be a
                    // silent fallback.
                    _ => None,
                };
                {
                    let manager = trigger_manager.read().await;
                    let state_lock = manager.state();
                    let mut state = state_lock.write().await;
                    state.update_cloud_motion(
                        current_cover_percent,
                        predicted_arrival_minutes,
                        predicted_opening_minutes,
                        predicted_opening_duration_secs,
                        clear_sky,
                    );
                }
                // Mirror the same values into the shared
                // ExecutionContext so recovery actions
                // (`SlewToGapAndContinue`) and the run-
                // dashboard panel can read them without
                // holding the trigger-state lock. We use
                // the pre-cloned `cloud_motion_for_recovery`
                // Arc captured outside this closure (an
                // identical-content clone of
                // `context.cloud_motion_snapshot`) — using
                // `context.cloud_motion_snapshot` directly
                // would re-borrow `context` immutably and
                // conflict with the parallel
                // `root_node.execute(&mut context)` future.
                {
                    let mut slot = cloud_motion_for_recovery.write().await;
                    *slot = CloudMotionSnapshot {
                        current_cover_percent,
                        predicted_arrival_minutes,
                        predicted_opening_minutes,
                        predicted_opening_duration_secs,
                        predicted_clear_sky_direction: clear_sky,
                        last_update_unix_secs: Some(chrono::Utc::now().timestamp()),
                    };
                }
                tracing::debug!(
                    "Runtime cloud motion updated: cover={:?}%, arrival={:?}min, opening={:?}min ({:?}s), clear=({:?},{:?})",
                    current_cover_percent,
                    predicted_arrival_minutes,
                    predicted_opening_minutes,
                    predicted_opening_duration_secs,
                    predicted_clear_sky_alt,
                    predicted_clear_sky_az,
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "cloud_motion".to_string(),
                });
            }
            ExecutorCommand::UpdateTransparency { transparency } => {
                // Science — push the live transparency
                // reading into BOTH the trigger state (so the
                // `TransparencyDropped` evaluator sees it on
                // its next tick) AND the shared
                // ExecutionContext (so the photometry node's
                // per-frame quality gates and the run-
                // dashboard panel can read it without
                // holding the trigger-state lock).
                {
                    let manager = trigger_manager.read().await;
                    let state_lock = manager.state();
                    let mut state = state_lock.write().await;
                    state.update_transparency(transparency);
                }
                {
                    let mut slot = transparency_for_cmd.write().await;
                    *slot = transparency;
                }
                tracing::debug!("Runtime transparency updated: {:?}", transparency);
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "transparency".to_string(),
                });
            }
            ExecutorCommand::UpdateTransparencyBackup { plan } => {
                // Science — operator-configured
                // backup plan for the
                // `SwitchTargetOrFilter` recovery action.
                let summary = plan.as_ref().map(|p| {
                    format!(
                        "filter={:?}, target={:?}",
                        p.backup_filter, p.backup_target_id,
                    )
                });
                {
                    let mut slot = transparency_backup_for_cmd.write().await;
                    *slot = plan;
                }
                tracing::info!("Runtime transparency backup plan updated: {:?}", summary);
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "transparency_backup".to_string(),
                });
            }
            ExecutorCommand::UpdateConditionsScore { score } => {
                // push the live ConditionsScore
                // into the shared ExecutionContext so the
                // TargetScheduler's adaptive-swap logic
                // reads it on its next decision tick. The
                // Dart-side `AdaptiveSwapService` composes
                // the score from transparency / seeing /
                // cloud cover / wind every ~30 seconds.
                // Pass `None` to clear (telemetry lost).
                let summary = score.as_ref().map(|s| {
                    format!(
                        "score={:.1} (T={:?} S={:?} C={:?} W={:?})",
                        s.score, s.transparency_score, s.seeing_score, s.cloud_score, s.wind_score,
                    )
                });
                {
                    let mut slot = conditions_score_for_cmd.write().await;
                    *slot = score;
                }
                tracing::debug!("Runtime conditions score updated: {:?}", summary);
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "conditions_score".to_string(),
                });
            }
            ExecutorCommand::UpdateWeatherVerdict {
                unsafe_override,
                advisory,
            } => {
                // Full-night audit 2026-06-04 (defense-in-depth) —
                // fold the Dart-side weather-safety verdict into the
                // trigger state so the in-sequencer `WeatherUnsafe`
                // trigger reacts even on rigs without a hardware
                // safety device. The evaluator ORs this with the
                // hardware `weather_safe` reading (never less safe).
                {
                    let manager = trigger_manager.read().await;
                    let state_lock = manager.state();
                    let mut state = state_lock.write().await;
                    state.update_weather_verdict_from(unsafe_override, advisory);
                }
                tracing::debug!(
                    "Runtime weather verdict updated: unsafe_override={:?} advisory={}",
                    unsafe_override,
                    advisory
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "weather_verdict".to_string(),
                });
            }
            ExecutorCommand::UpdateRecoveryConfig { config } => {
                // Recovery Mode — push the user's
                // tunable defaults through the shared Arc.
                // The next time the trigger monitor enters
                // a recovery loop (Running -> Recovering)
                // it reads from the runtime config and uses
                // these values to construct the new
                // `RecoveryContext`.
                let interval = config.retry_interval_secs;
                let max_duration = config.max_duration_secs;
                {
                    let mut rc = runtime_config.write();
                    rc.recovery = config;
                }
                tracing::info!(
                    "Runtime recovery config updated: interval={:.0}s, max_duration={:.0}s",
                    interval,
                    max_duration,
                );
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "recovery_config".to_string(),
                });
            }
            ExecutorCommand::UpdateSafetyFailMode { mode } => {
                {
                    let mut rc = runtime_config.write();
                    rc.safety_fail_mode = mode;
                }
                *safety_fail_mode_for_cmd.write() = mode;
                tracing::info!("Runtime safety fail mode updated: {:?}", mode);
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "safety_fail_mode".to_string(),
                });
            }
            ExecutorCommand::UpdateSafetyCheckInterval { seconds } => {
                let seconds = effective_safety_check_interval_secs(seconds);
                {
                    let mut rc = runtime_config.write();
                    rc.safety_check_interval_secs = seconds;
                }
                tracing::info!("Runtime safety check interval updated: {}s", seconds);
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "safety_check_interval".to_string(),
                });
            }
            ExecutorCommand::UpdateDefectMap { state } => {
                // push the active defect
                // map (or clear it). Write through the
                // shared RuntimeConfig AND the shared
                // ExecutionContext Arc so subsequent
                // captures see the update on their next
                // `defect_map_apply.read().await`.
                let summary = state.as_ref().map(|s| {
                    (
                        s.camera_id.clone(),
                        s.map.defective_count(),
                        s.kernel.diameter(),
                        s.method.as_str(),
                        s.save_original,
                    )
                });
                {
                    let mut rc = runtime_config.write();
                    rc.defect_map_apply = state.clone();
                }
                {
                    let mut slot = defect_map_apply_for_cmd.write().await;
                    *slot = state;
                }
                match summary {
                    Some((camera, defects, kernel, method, save_original)) => {
                        tracing::info!(
                            "Runtime defect map updated: camera={}, defects={}, kernel={}x{}, method={}, save_original={}",
                            camera,
                            defects,
                            kernel,
                            kernel,
                            method,
                            save_original,
                        );
                    }
                    None => {
                        tracing::info!(
                            "Runtime defect map cleared (per-frame defect correction disabled)"
                        );
                    }
                }
                let _ = event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
                    what: "defect_map".to_string(),
                });
            }
            ExecutorCommand::PluginNodeFinished {
                node_id,
                success,
                message,
                structured_detail_json,
            } => {
                // resolve the oneshot the
                // matching `PluginNodeInstruction::execute`
                // is awaiting. A stray finish (no pending
                // entry) is logged at warn and dropped;
                // it means either the Dart side replied
                // twice for the same node id, or the
                // executor torch-down already cleaned up
                // the entry on timeout. Either case is
                // benign for the rest of the run.
                let sender = {
                    let mut pending = plugin_node_pending_for_cmd.write().await;
                    pending.remove(&node_id)
                };
                let parsed_detail = structured_detail_json
                    .as_deref()
                    .and_then(|json| {
                        if json.is_empty() {
                            None
                        } else {
                            match serde_json::from_str::<serde_json::Value>(json) {
                                Ok(v) => Some(v),
                                Err(e) => {
                                    tracing::warn!(
                                        "[PLUGIN] PluginNodeFinished structured_detail_json was invalid \
                                         JSON for node {}: {}; payload dropped.",
                                        node_id,
                                        e,
                                    );
                                    None
                                }
                            }
                        }
                    });
                match sender {
                    Some(tx) => {
                        if tx
                            .send(crate::node::context::PluginNodeReply {
                                success,
                                message: message.clone(),
                                structured_detail: parsed_detail,
                            })
                            .is_err()
                        {
                            // Receiver was dropped (timeout
                            // already fired). Log so a
                            // late reply doesn't vanish
                            // silently.
                            tracing::warn!(
                                "[PLUGIN] PluginNodeFinished for node {} arrived after the awaiting future \
                                 had already given up; verdict dropped (success={}, message={:?})",
                                node_id,
                                success,
                                message,
                            );
                        }
                    }
                    None => {
                        tracing::warn!(
                            "[PLUGIN] PluginNodeFinished for unknown node {} (no pending oneshot). \
                             Either the Dart side replied twice, or the request already timed out.",
                            node_id,
                        );
                    }
                }
            }
        }
    }
}
