part of '../sequence_executor.dart';

extension _SequenceExecutorRuntimeConfigOperations on SequenceExecutor {
  /// Push the launch-authoritative configuration — location, simulation mode,
  /// safety fail mode, save path, device ids and the defect-map runtime — to
  /// the executor.
  ///
  /// ONE ordered push for both launch paths, [start] and
  /// [resumeFromCheckpoint]. The safety mode goes out RESOLVED
  /// ([_effectiveSafetyFailMode]), never raw: a raw `failClosed` on a rig with
  /// no safety-monitor device arms the always-on `WeatherUnsafe` trigger and
  /// parks the mount within milliseconds of launch.
  ///
  /// [isResume] marks the points where the checkpoint knows better than an
  /// empty setting does: the save path and the site are taken from the
  /// checkpoint rather than re-seeded from settings.
  Future<void> _pushLaunchConfig(
    NightshadeBackend backend,
    AppSettingsState settings, {
    required bool isResume,
  }) async {
    _logger.debug(
      'Pushing launch config (resume=$isResume): lat=${settings.latitude}, '
      'lon=${settings.longitude}, elev=${settings.elevation}',
      source: 'SequenceExecutor',
    );

    // The snapshot a resume restores reflects the world at checkpoint time.
    // Settings the user changed since — location, safety fail mode, AF cadence,
    // dither, grading thresholds — must win: the W1 daylight gate and the
    // meridian-flip hour-angle math both run off this location. A location of
    // exactly (0, 0) means "not configured"; forwarding it would arm the
    // altitude trigger against Null Island instead of leaving it disarmed.
    if (settings.latitude != 0.0 || settings.longitude != 0.0) {
      await backend.setLocation(
        ObserverLocation(
          latitude: settings.latitude,
          longitude: settings.longitude,
          elevation: settings.elevation,
        ),
      );
      _logger.debug('Location sync complete', source: 'SequenceExecutor');
    } else {
      _logger.debug(
        'Skipping location sync: location is 0,0',
        source: 'SequenceExecutor',
      );
    }

    // Stated explicitly, never read from a setting: the bundled native library
    // is a release build and refuses simulation mode, so a launch that pushed
    // anything but `false` would be asking for a state the executor cannot
    // enter.
    await backend.sequencerSetSimulationMode(false);

    await _pushEffectiveSafetyFailMode(backend, settings.safetyFailMode);

    final savePath = settings.imageOutputPath;
    if (savePath.isNotEmpty) {
      await backend.sequencerSetSavePath(savePath);
      _logger.debug('Save path set to: $savePath', source: 'SequenceExecutor');
    } else if (!isResume) {
      // Difference 1: a fresh run with no configured path pushes null so the
      // executor cannot inherit a previous run's path. A resume must NOT —
      // null means "don't save", and it would clobber a perfectly good path the
      // snapshot restored.
      await backend.sequencerSetSavePath(null);
      _logger.warning(
        'No save path configured - images will NOT be saved to disk!',
        source: 'SequenceExecutor',
      );
    }

    // Difference 2: on a resume the checkpoint restored the snapshot's device
    // mapping, and in the crash-recovery-at-startup case (equipment not
    // reconnected yet) those ids are the best information available —
    // overwriting them with nulls would strand the resumed run. Only push
    // fresher ids when a camera is actually connected.
    final cameraState = _ref.read(cameraStateProvider);
    final cameraConnected =
        cameraState.connectionState == DeviceConnectionState.connected;
    if (!isResume || cameraConnected) {
      final mountState = _ref.read(mountStateProvider);
      final focuserState = _ref.read(focuserStateProvider);
      final filterwheelState = _ref.read(filterWheelStateProvider);
      final rotatorState = _ref.read(rotatorStateProvider);

      final focuserId =
          focuserState.connectionState == DeviceConnectionState.connected
          ? focuserState.deviceId
          : null;

      await backend.sequencerSetDevices(
        cameraId: cameraConnected ? cameraState.deviceId : null,
        mountId: mountState.connectionState == DeviceConnectionState.connected
            ? mountState.deviceId
            : null,
        focuserId: focuserId,
        filterwheelId:
            filterwheelState.connectionState == DeviceConnectionState.connected
            ? filterwheelState.deviceId
            : null,
        rotatorId:
            rotatorState.connectionState == DeviceConnectionState.connected
            ? rotatorState.deviceId
            : null,
      );

      // Tell the operator, in the run record, that automatic refocus is off for
      // this run. With no focuser connected the native executor disarms every
      // autofocus-action trigger (HFR degradation, temperature shift, focus
      // drift, the frame-interval refocus). That is the correct behaviour — an
      // autofocus is physically impossible — but it silently removes a
      // protection the sequence editor still advertises, so the run report has
      // to say so rather than look like a night with focus management running.
      // Start only: a resume may be running against the checkpoint's device
      // mapping, which this Dart-side connection state says nothing about.
      // `persist: false` — this is a start-up fact, not a running statistic. It
      // reaches the DB via the final `finishRun` stats write like every other
      // warning; forcing an incremental `updateStats` here would add a second
      // DB round-trip before the first frame for a value that cannot change.
      if (!isResume && focuserId == null) {
        _surfaceRunWarning(
          'No focuser is connected, so automatic refocus is disabled for this '
          'run (HFR-degradation, temperature-shift, focus-drift and '
          'interval refocus triggers are all inert). Focus will not be '
          'corrected automatically.',
          persist: false,
        );
      }
    }

    // The native defect-map runtime slot is not restored from app_settings.
    // Seed it for every run so auto-apply survives restarts and headless starts.
    await seedDefectMapRuntimeForSequence(_ref);
  }

  Future<void> _startNativeExecution(
    Sequence sequence,
    AppSettingsState settings,
  ) async {
    final backend = _backend;

    await _pushLaunchConfig(backend, settings, isResume: false);

    // Meridian nodes that opt into global defaults are serialized from this
    // provider. Wait for the DB/remote-host snapshot so a fast start after app
    // launch cannot bake factory defaults into the run while the real settings
    // are still loading in the background.
    await _ref.read(globalMeridianFlipSettingsProvider.notifier).ensureLoaded();

    // The measured focuser backlash every autofocus config carries
    // (`measured_backlash_in`) is read synchronously out of a FutureProvider,
    // and it is read twice below: once per Autofocus node in the tree, and
    // once for the trigger-fired refocus config. Resolving it here covers
    // both, so a start that outran the DB cannot push a run with no figure and
    // then land focus on the wrong face of the gear train all night.
    await _ref.read(savedFocuserBacklashProvider.future);

    final json = _serializer.sequenceToJson(sequence);
    await backend.sequencerLoadJson(json);

    // Seed RuntimeConfig from persisted user settings BEFORE
    // start() so the trigger monitor's first poll honours the user's cadence
    // / dither / location / filter-offsets values instead of the Rust
    // defaults (autofocus_interval_frames=25, dither pixels=5, location 0/0,
    // empty filter offsets). The live settings watchers cannot cover this:
    // they fire only on a subsequent CHANGE, so a headless start that never
    // visits the Settings UI would run on the Rust defaults. Failures are
    // surfaced, not swallowed — a bad seed means aborting start rather than
    // running with the wrong cadence.
    //
    // Through the public entry point, not the extension method: it is the ONE
    // seed site the headless `load -> start` path shares with this one (see
    // [SequenceExecutor.seedRuntimeConfigForNativeStart]).
    await seedRuntimeConfigForNativeStart();

    // Consult the session-handoff decision for every
    // TargetHeader with an `integrationBudget` configured. The operator's
    // pre-flight decision (Resume / Restart / Continue New) decides how
    // the Rust `BudgetRegistry` is seeded for this run.
    //
    // Resume      → pre-credit per-filter integration from the prior
    //               session's carry-over so "Lum: 4h done / 8h target"
    //               persists into the new run.
    // Restart     → push an empty per-filter map so any stale checkpoint
    //               carry-over is overwritten with zeros.
    // ContinueNew → omit the target (default behaviour: tracker starts
    //               from zero without zeroing prior state).
    //
    // Done AFTER `_seedRuntimeConfigFromSettings` so the carry-over write
    // overrides any default the runtime-config push might re-stamp, and
    // BEFORE `sequencerStart()` so the consumption hook at the top of
    // the spawned executor task sees the freshly-staged map.
    await _seedIntegrationCarryOverFromHandoff(backend, sequence);

    await attachHostListenersForNativeRun();

    _startSettingsWatchers(backend);

    // Mark the native-launch boundary: a throw from here on may mean a partial
    // launch, so [_rollbackStart] will best-effort sequencerStop rather than
    // tear down blind.
    _nativeLaunchAttempted = true;
    await backend.sequencerStart();
  }

  /// Resolve the safety fail mode the native executor must actually run with,
  /// given the operator's configured [configured] mode.
  ///
  /// When weather safety is DISABLED the operator has opted out of
  /// weather-driven aborts. The Rust safety poll fail-closes on a rig with no
  /// safety-monitor device, so pushing a stale `failClosed` would keep the
  /// always-armed in-sequencer `WeatherUnsafe` trigger firing (via
  /// `!weather_safe`) even with monitoring off — parking the mount and
  /// aborting every sequence within milliseconds of start. Force the executor
  /// poll permissive (`failOpen`) while disabled; the Dart verdict already
  /// abstains (see weather_safety_provider), so nothing drives an unsafe
  /// verdict. Re-enabling restores the configured mode on the next push.
  ///
  /// This lives in ONE place because three call sites push the fail mode — run
  /// start, checkpoint resume, and the mid-run settings watcher — and any of
  /// them pushing the raw configured value instead aborts the run instantly on
  /// a rig with no safety monitor.
  SafetyFailMode _effectiveSafetyFailMode(SafetyFailMode configured) {
    final weatherSafetyEnabled = _ref
        .read(weatherSettingsProvider)
        .weatherSafetyEnabled;
    return weatherSafetyEnabled ? configured : SafetyFailMode.failOpen;
  }

  /// Push [configured] through [_effectiveSafetyFailMode] to the executor.
  Future<void> _pushEffectiveSafetyFailMode(
    NightshadeBackend backend,
    SafetyFailMode configured,
  ) async {
    final effective = _effectiveSafetyFailMode(configured);
    final wire = _serializer.safetyFailModeToBackendString(effective);
    await backend.sequencerSetSafetyFailMode(wire);
    _logger.debug(
      'Safety fail mode set to: $wire (configured=${configured.name})',
      source: 'SequenceExecutor',
    );
  }

  /// Push the operator's park settings to the executor.
  ///
  /// Weather parking is the composed gate the app's own evaluator uses,
  /// "Park on unsafe weather" AND Weather Safety's "Auto-park mount"
  /// ([SafetyConfig.autoParkOnUnsafe]): the two pages show and write one
  /// setting, and turning either off must stop the executor parking too.
  Future<void> _pushParkPolicy(
    NightshadeBackend backend,
    AppSettingsState settings,
  ) async {
    final autoParkEnabled = _ref.read(weatherSettingsProvider).autoParkEnabled;
    final parkOnUnsafeWeather = settings.parkOnUnsafeWeather && autoParkEnabled;
    await backend.sequencerSetParkPolicy(
      parkOnUnsafeWeather: parkOnUnsafeWeather,
      parkBeforeDawn: settings.parkBeforeDawn,
    );
    _logger.debug(
      'Park settings: on unsafe weather=$parkOnUnsafeWeather, '
      'before dawn=${settings.parkBeforeDawn}',
      source: 'SequenceExecutor',
    );
  }

  /// Push the operator's camera and filter-wheel retry counts to the executor.
  Future<void> _pushDeviceRetries(
    NightshadeBackend backend,
    AppSettingsState settings,
  ) async {
    await backend.sequencerSetDeviceRetries(
      cameraRetries: settings.cameraRetries,
      filterWheelRetries: settings.filterWheelRetries,
    );
    _logger.debug(
      'Device retries: camera=${settings.cameraRetries}, '
      'filter wheel=${settings.filterWheelRetries}',
      source: 'SequenceExecutor',
    );
  }

  /// Push every user-controlled RuntimeConfig field into the loaded executor.
  ///
  /// Reached through [SequenceExecutor.seedRuntimeConfigForNativeStart], the
  /// public entry point every native launch shares — the editor start, the
  /// checkpoint resume and the headless `load -> start` path. Each push is
  /// independent — a failure on one field still attempts the next, but the
  /// first failure is rethrown after the batch so the caller learns about the
  /// misconfiguration before sequencerStart() runs.
  Future<void> _seedRuntimeConfigFromSettings(NightshadeBackend backend) async {
    Object? firstError;
    StackTrace? firstStack;

    // Six of the pushes below read `appSettingsProvider.valueOrNull` and do
    // NOTHING when it is null. Awaiting the load here is what keeps that
    // branch out of reach: a start racing a cold settings load would otherwise
    // push no grading thresholds, no reject folder and no adaptive-exposure
    // config, and say so nowhere. Failure propagates — with the operator's
    // settings unknown there is nothing honest to seed.
    await _ref.read(appSettingsProvider.future);

    // Same reason, for the measured focuser backlash the autofocus config
    // below carries: it is read synchronously out of a FutureProvider, and
    // this method is also reachable on its own (the headless native start
    // calls `seedRuntimeConfigForNativeStart`), so awaiting it here rather
    // than only in `_startNativeExecution` is what keeps every entry point
    // from pushing a refocus config with no figure in it.
    await _ref.read(savedFocuserBacklashProvider.future);

    // The meridian-flip push below serializes this provider. `ensureLoaded`
    // waits for the DB/remote-host snapshot, so a start that never visited the
    // Settings UI — every headless night — cannot bake factory defaults into
    // the run while the operator's real values are still loading. Idempotent:
    // the editor start already awaits it before serializing the tree.
    await _ref.read(globalMeridianFlipSettingsProvider.notifier).ensureLoaded();

    // Same reason, for the autofocus cadence and dither config below: they
    // are read synchronously out of `sequencerDefaultsProvider`, which holds
    // the library defaults until its database load completes.
    await _ref.read(sequencerDefaultsProvider.notifier).ensureLoaded();

    // Autofocus cadence: persisted in sequencer_autofocus_interval_frames; the
    // Rust default of 25 is wrong for both very-short and very-long subs.
    try {
      final defaults = _ref.read(sequencerDefaultsProvider);
      // Zero means OFF, and must be passed through as zero: the engine reads
      // 0 as "never fire" (`TriggerType::AutofocusInterval` returns false when
      // `every_n_frames == 0`), so clamping it up to 1 would turn the one
      // value an operator reaches for to disable interval autofocus into
      // refocus-after-every-frame. Negative values are not meaningful and also
      // resolve to off rather than to a cadence.
      final frames = defaults.autofocusIntervalFrames < 1
          ? 0
          : defaults.autofocusIntervalFrames;
      await backend.sequencerUpdateAutofocusInterval(frames);
      _logger.debug(
        frames == 0
            ? 'Seeded autofocus interval: disabled'
            : 'Seeded autofocus interval: every $frames frames',
        source: 'SequenceExecutor',
      );

      // Push the operator's autofocus tuning as well as the cadence.
      //
      // The engine's only other source of trigger-autofocus config is an
      // Autofocus node inside the sequence, so a sequence without one — which
      // is exactly the sequence whose interval trigger fires unattended — ran
      // every refocus on library defaults: not the operator's step size,
      // exposure, backlash, nor their failure tolerance. An Autofocus node
      // still wins; this is the floor, not an override.
      final afSettings = _ref.read(autofocusSettingsProvider);
      await backend.sequencerUpdateAutofocusConfig(
        jsonEncode(
          _serializer.autofocusRuntimeConfig(afSettings, maxDurationSecs: 600),
        ),
      );
      _logger.debug(
        'Seeded trigger-autofocus config: attempts=${afSettings.numberOfAttempts}, '
        'failure tolerance=${afSettings.failureHfrToleranceRatio}x',
        source: 'SequenceExecutor',
      );
    } catch (e, st) {
      firstError ??= e;
      firstStack ??= st;
      _logger.error(
        'Failed to seed autofocus interval: $e',
        source: 'SequenceExecutor',
      );
    }

    // Park settings. The executor's standard Weather Unsafe and Dawn
    // Approaching triggers park the mount and close the cover and dome, and
    // until this push existed nothing told them the operator had switched
    // "Park on unsafe weather" or "Park before dawn" off: the rig was parked
    // anyway.
    try {
      await _pushParkPolicy(
        backend,
        await _ref.read(appSettingsProvider.future),
      );
    } catch (e, st) {
      firstError ??= e;
      firstStack ??= st;
      _logger.error(
        'Failed to seed the park settings: $e',
        source: 'SequenceExecutor',
      );
    }

    // Camera and filter-wheel retries. Without this push the executor keeps
    // its own default (3 each) whatever the operator set.
    try {
      await _pushDeviceRetries(
        backend,
        await _ref.read(appSettingsProvider.future),
      );
    } catch (e, st) {
      firstError ??= e;
      firstStack ??= st;
      _logger.error(
        'Failed to seed the device retries: $e',
        source: 'SequenceExecutor',
      );
    }

    // Dither config: persisted in SequencerDefaults; the Rust defaults differ
    // from what the user sees in Settings, so without this seed an unattended
    // headless start uses a stale config.
    try {
      final defaults = _ref.read(sequencerDefaultsProvider);
      await backend.sequencerUpdateDitherConfig(
        pixels: defaults.ditherPixels,
        settlePixels: defaults.ditherSettlePixels,
        settleTime: defaults.ditherSettleTime,
        settleTimeout: defaults.ditherSettleTimeout,
        raOnly: defaults.ditherRaOnly,
      );
      _logger.debug(
        'Seeded dither config: pixels=${defaults.ditherPixels} settle=${defaults.ditherSettleTime}s',
        source: 'SequenceExecutor',
      );
    } catch (e, st) {
      firstError ??= e;
      firstStack ??= st;
      _logger.error(
        'Failed to seed dither config: $e',
        source: 'SequenceExecutor',
      );
    }

    // Meridian-flip settings. The Rust `meridian_flip` trigger is seeded by
    // `TriggerManager::create_standard_triggers` with
    // `MeridianFlipConfig::default()`, and until this push existed NOTHING ever
    // replaced it — so every trigger-driven flip (the only flip that fires on
    // an unattended night) ignored the whole Settings -> Meridian Flip panel.
    // It hid because the Rust defaults happen to equal the panel's defaults;
    // only an operator who CHANGED a value was affected, and then silently.
    // Proven live: a run with `recenterAfterFlip: false` still ran
    // "Step 6/8: Plate solving and centering".
    try {
      await backend.sequencerUpdateMeridianFlipConfig(
        jsonEncode(_serializer.buildGlobalMeridianFlipConfigJson()),
      );
      _logger.debug(
        'Seeded meridian-flip trigger config from user settings',
        source: 'SequenceExecutor',
      );
    } catch (e, st) {
      firstError ??= e;
      firstStack ??= st;
      _logger.error(
        'Failed to seed meridian-flip config: $e',
        source: 'SequenceExecutor',
      );
    }

    // Observer location: distinct from setLocation() above (which sets the
    // higher-level NightshadeBackend location). The sequencer's RuntimeConfig
    // owns its own lat/lon used by meridian-flip and altitude calculations.
    try {
      final settings = _ref.read(appSettingsProvider).valueOrNull;
      // Only push a location the operator actually set. `sequencerUpdateLocation`
      // takes non-nullable doubles, so an unconfigured site arrives in Rust as
      // `Some(0.0), Some(0.0)` — a real place in the Gulf of Guinea — and the
      // executor cannot tell it from a deliberate one.
      //
      // Measured in the running desktop app 2026-08-09, on a profile with no
      // observing location (the UI said so in three places):
      //
      //   INFO Updating sequencer location: lat=Some(0.0), lon=Some(0.0)
      //   WARN Trigger fired: Altitude Limit (altitude_limit) - action: NextTarget
      //   ... once per 60 s cooldown, for the whole run
      //
      // Vega is below 30° from the equator at that hour, so the always-armed
      // altitude trigger computed a real altitude for a place the telescope is
      // not and voted to abandon the target. On an unattended rig with more than
      // one target, every one of them would be skipped in turn.
      //
      // The Rust side is already written for this: it computes an altitude only
      // when RA, Dec, latitude AND longitude are all present, returns `false`
      // from the altitude condition when the altitude is unknown, and carries a
      // one-shot "altitude triggers are dead until location is supplied"
      // warning — which never fired, because it never saw the absence.
      // Withholding the push is what lets that design work.
      //
      // `!= 0.0` is the same "is a location configured" test
      // `_startNativeExecution` already uses for the higher-level
      // `setLocation`. Null Island is not an observing site.
      final hasLocation =
          settings != null &&
          (settings.latitude != 0.0 || settings.longitude != 0.0);
      if (hasLocation) {
        await backend.sequencerUpdateLocation(
          latitude: settings.latitude,
          longitude: settings.longitude,
        );
        _logger.debug(
          'Seeded sequencer location: lat=${settings.latitude} lon=${settings.longitude}',
          source: 'SequenceExecutor',
        );
      } else if (settings != null) {
        _logger.warning(
          'No observing location is set, so the sequencer was not given one. '
          'Altitude-based triggers and meridian-flip timing stay inactive '
          'until a site is configured in Settings → Location.',
          source: 'SequenceExecutor',
        );
      }
    } catch (e, st) {
      firstError ??= e;
      firstStack ??= st;
      _logger.error(
        'Failed to seed sequencer location: $e',
        source: 'SequenceExecutor',
      );
    }

    // Filter focus offsets: merge the equipment profile table with non-zero
    // per-filter AF overrides (the same precedence DeviceService uses). Honor
    // the user's master toggle by sending an empty map when disabled.
    try {
      final profile = _ref.read(activeEquipmentProfileProvider);
      final settings = _ref.read(appSettingsProvider).valueOrNull;
      if (settings == null) {
        throw StateError(
          'AppSettings is not loaded; filter focus-offset behavior is unknown.',
        );
      }
      final offsets = <String, int>{};
      if (settings.useFilterFocusOffsets) {
        offsets.addAll(profile?.filterFocusOffsets ?? const <String, int>{});
        final autofocusFilters = AutofocusSettings.parseFilterSettingsJson(
          settings.afFilterSettingsJson,
        );
        for (final entry in autofocusFilters.entries) {
          if (entry.value.focusOffset != 0) {
            offsets[entry.key] = entry.value.focusOffset;
          }
        }
      }
      await backend.sequencerUpdateFilterOffsets(offsets);
      _logger.debug(
        'Seeded filter focus offsets: ${offsets.length} entries',
        source: 'SequenceExecutor',
      );
    } catch (e, st) {
      firstError ??= e;
      firstStack ??= st;
      _logger.error(
        'Failed to seed filter focus offsets: $e',
        source: 'SequenceExecutor',
      );
    }

    // Default image-grading thresholds + reject folder. Without
    // this seed the executor's RuntimeConfig stays at the all-None
    // default and "Enable image grading" in Settings has no effect on the
    // next sequence start.
    try {
      final settings = _ref.read(appSettingsProvider).valueOrNull;
      if (settings != null) {
        await backend.sequencerUpdateDefaultQualityCheck(
          hfrThreshold: settings.imageGradingHfrThresholdPx,
          hfrBaselinePercent: settings.imageGradingHfrBaselinePercent,
          eccentricityThreshold: settings.imageGradingEccentricityThreshold,
          starCountMin: settings.imageGradingStarCountMin,
          maxConsecutiveRejects: settings.imageGradingMaxConsecutiveRejects,
          enabled: settings.enableImageGrading,
        );
        _logger.debug(
          'Seeded default_quality_check: enabled=${settings.enableImageGrading}, hfr=${settings.imageGradingHfrThresholdPx}px, baseline=${settings.imageGradingHfrBaselinePercent}%',
          source: 'SequenceExecutor',
        );
      }
    } catch (e, st) {
      firstError ??= e;
      firstStack ??= st;
      _logger.error(
        'Failed to seed default_quality_check: $e',
        source: 'SequenceExecutor',
      );
    }

    // Reject folder path.
    try {
      final settings = _ref.read(appSettingsProvider).valueOrNull;
      if (settings != null) {
        await backend.sequencerUpdateRejectFolderPath(
          settings.imageGradingRejectFolderPath,
        );
        _logger.debug(
          'Seeded reject_folder_path: ${settings.imageGradingRejectFolderPath ?? "<default>"}',
          source: 'SequenceExecutor',
        );
      }
    } catch (e, st) {
      firstError ??= e;
      firstStack ??= st;
      _logger.error(
        'Failed to seed reject_folder_path: $e',
        source: 'SequenceExecutor',
      );
    }

    // Observer / equipment identification so FITS headers carry
    // OBSERVER, TELESCOP, FOCALLEN, APTDIA, INSTRUME, SITEELEV.
    try {
      await _pushObserverProfile(backend);
    } catch (e, st) {
      firstError ??= e;
      firstStack ??= st;
      _logger.error(
        'Failed to seed observer_profile: $e',
        source: 'SequenceExecutor',
      );
    }

    // Seed the global default sky-brightness adaptive
    // exposure config from app settings so a sequence start without a
    // settings round-trip still honours the user's choice. When the
    // master switch is off we explicitly clear the executor's value
    // (avoids a stale config sticking around from a prior run).
    try {
      final settings = _ref.read(appSettingsProvider).valueOrNull;
      if (settings != null) {
        if (settings.adaptiveExposureEnabled) {
          await backend.sequencerUpdateDefaultAdaptiveExposure(
            enabled: settings.adaptiveExposureEnabled,
            targetSnr: settings.adaptiveExposureTargetSnr,
            referenceSkyBrightnessMag: settings.adaptiveExposureReferenceMag,
            minExposureSecs: settings.adaptiveExposureMinSecs,
            maxExposureSecs: settings.adaptiveExposureMaxSecs,
            perFilterEnabled: settings.adaptiveExposurePerFilterEnabled,
            perFilterMinSecs: settings.adaptiveExposurePerFilterMinSecs,
            perFilterMaxSecs: settings.adaptiveExposurePerFilterMaxSecs,
          );
          _logger.debug(
            'Seeded default_adaptive_exposure: enabled=${settings.adaptiveExposureEnabled}, ref=${settings.adaptiveExposureReferenceMag} mag/arcsec², min=${settings.adaptiveExposureMinSecs}s, max=${settings.adaptiveExposureMaxSecs}s',
            source: 'SequenceExecutor',
          );
        } else {
          await backend.sequencerClearDefaultAdaptiveExposure();
          _logger.debug(
            'Cleared default_adaptive_exposure (disabled in settings)',
            source: 'SequenceExecutor',
          );
        }
      }
    } catch (e, st) {
      firstError ??= e;
      firstStack ??= st;
      _logger.error(
        'Failed to seed default_adaptive_exposure: $e',
        source: 'SequenceExecutor',
      );
    }

    // Replay Debug — seed the decision-logging enabled flag from
    // the ACTIVE authority's setting before start. `replayDebugEnabledProvider`
    // branches on backend: on the host it reads the local `replay_debug.enabled`
    // app-setting; on a remote client it reads the host's authoritative value.
    // Pushing it through `backend.sequencerSetDecisionLoggingEnabled` reconciles
    // the executor's runtime flag to that persisted policy for both paths. A
    // corrupt/unreadable setting throws (strict parse) and, via `firstError`,
    // aborts the start so we never begin a run under the wrong logging policy.
    try {
      final enabled = await _ref.read(replayDebugEnabledProvider.future);
      await backend.sequencerSetDecisionLoggingEnabled(enabled);
      _logger.debug(
        'Seeded replay decision logging: enabled=$enabled',
        source: 'SequenceExecutor',
      );
    } catch (e, st) {
      firstError ??= e;
      firstStack ??= st;
      _logger.error(
        'Failed to seed replay decision logging: $e',
        source: 'SequenceExecutor',
      );
    }

    if (firstError != null) {
      // Rethrow so sequencerStart() does not proceed on a partial runtime
      // config: the launch would run the night on the Rust defaults for
      // whatever failed to push, and nothing downstream would say so.
      Error.throwWithStackTrace(firstError, firstStack ?? StackTrace.current);
    }
  }

  /// Consume `sessionHandoffDecisionProvider` for every
  /// TargetHeader and push the resolved per-filter carry-over map to
  /// the Rust executor's `BudgetRegistry` seed.
  ///
  /// Three-way semantics, mirroring `SessionHandoffDecision`:
  ///
  ///   * `Resume`     → write the operator's
  ///                    `SessionCarryOver.perFilterIntegrationSecs` into
  ///                    the carry-over map. The Rust side credits those
  ///                    frames against the configured budget so the
  ///                    very first IntegrationBudget tick reads
  ///                    "Lum: 4h done / 8h target", not "Lum: 0h done".
  ///   * `Restart`    → write an explicit empty map for the target id
  ///                    so any pre-existing checkpoint state is
  ///                    overwritten with zeros.
  ///   * `ContinueNew` → omit the target entirely (no carry-over, no
  ///                    zeroing). Same effect as no prior decision.
  ///
  /// Joins `SessionCarryOver.targetName` against the sequence's
  /// `TargetHeaderNode.targetName` (case-insensitive) to resolve the
  /// Rust-side `TargetHeaderNode.id` that the BudgetRegistry keys on.
  ///
  /// Failure policy: a missing decision for a target is a no-op (the
  /// pre-flight dialog might have been dismissed); any other error is
  /// rethrown so the caller learns about misconfiguration before
  /// `sequencerStart()` runs.
  Future<void> _seedIntegrationCarryOverFromHandoff(
    NightshadeBackend backend,
    Sequence sequence,
  ) async {
    final headers = sequence.targetHeaders;
    if (headers.isEmpty) return;

    // Pull the carry-over snapshot. The provider is autoDispose +
    // FutureProvider; reading `.future` blocks until the first build
    // completes. An empty list means no prior session work to consider.
    final List<SessionCarryOver> carryOvers;
    try {
      carryOvers = await _ref.read(sessionCarryOverProvider.future);
      // A transient failure may have recovered between the pre-flight prompt
      // and executor setup. Consume the one-shot anyway and use the real data.
      if (_ref.read(sessionHandoffIgnoreUnavailableOnceProvider)) {
        _ref.read(sessionHandoffIgnoreUnavailableOnceProvider.notifier).state =
            false;
      }
    } catch (e, st) {
      // History-unavailable is not equivalent to no history. Surface it before
      // native start so a direct/API launch cannot silently reset a multi-night
      // integration budget to zero.
      if (_ref.read(sessionHandoffIgnoreUnavailableOnceProvider)) {
        _ref.read(sessionHandoffIgnoreUnavailableOnceProvider.notifier).state =
            false;
        _logger.warning(
          'Starting without session carry-over after explicit operator '
          'confirmation: $e',
          source: 'SequenceExecutor',
        );
        return;
      }
      _logger.error(
        'Failed to read session carry-over snapshot: $e',
        source: 'SequenceExecutor',
      );
      Error.throwWithStackTrace(e, st);
    }
    if (carryOvers.isEmpty) return;

    // Build a name-keyed lookup so the matching step is O(carryOvers).
    // `TargetHeaderNode.targetName` is the display name we matched
    // against in `SessionHandoffService.detectCarryOver`, so the
    // case-insensitive comparison reproduces the same join.
    final headersByName = <String, TargetHeaderNode>{};
    for (final h in headers) {
      headersByName[h.targetName.toLowerCase()] = h;
    }

    final carryOverPayload = <String, Map<String, double>>{};
    for (final entry in carryOvers) {
      final header = headersByName[entry.targetName.toLowerCase()];
      if (header == null) {
        // The carry-over targets something the current sequence does
        // not image. Skip; the operator can't have meant to seed it.
        continue;
      }
      final key = (sequenceId: sequence.databaseId, targetId: entry.targetId);
      final decision = _ref.read(sessionHandoffDecisionProvider(key));
      if (decision == null) {
        // No pre-flight decision recorded (dialog dismissed) — leave
        // the BudgetRegistry to its default zero-credit behaviour.
        continue;
      }
      switch (decision) {
        case SessionHandoffDecision.resume:
          // Copy the per-filter totals verbatim. The Rust side filters
          // non-finite / non-positive values defensively; we still
          // forward the operator's measurement honestly.
          carryOverPayload[header.id] = Map<String, double>.from(
            entry.perFilterIntegrationSecs,
          );
          break;
        case SessionHandoffDecision.restart:
          // Empty map → Rust zeroes any prior per-target state. This is
          // distinct from "omit", which would leave a stale checkpoint
          // entry untouched.
          carryOverPayload[header.id] = const <String, double>{};
          break;
        case SessionHandoffDecision.continueNew:
          // Acknowledged but not reused — neither seed nor zero.
          break;
      }
    }

    if (carryOverPayload.isEmpty) return;
    try {
      await backend.sequencerUpdatePendingIntegrationCarryOver(
        carryOverPayload,
      );
      _logger.info(
        'Staged integration carry-over for ${carryOverPayload.length} '
        'target${carryOverPayload.length == 1 ? '' : 's'} '
        '(handoff decisions applied)',
        source: 'SequenceExecutor',
      );
    } catch (e, st) {
      _logger.error(
        'Failed to stage integration carry-over: $e',
        source: 'SequenceExecutor',
      );
      Error.throwWithStackTrace(e, st);
    }
  }

  /// Start watching for settings changes that should be propagated to the
  /// backend executor during sequence execution (dither config, location,
  /// filter offsets).
  void _startSettingsWatchers(NightshadeBackend backend) {
    _stopSettingsWatchers();
    // Kick off the sky-brightness poll. The first
    // tick fires 10 s after start (matching the timer cadence); the
    // first user-visible adaptive-exposure decision uses whatever the
    // tracker has at TakeExposure time.
    _startSkyBrightnessPoll(backend);

    _settingsSubscriptions.add(
      // Every `listen` here is explicitly typed. `_settingsSubscriptions` is a
      // `List<ProviderSubscription>` — i.e. `<dynamic>` — so without the type
      // argument downward inference makes the callback parameters `dynamic`.
      // `AsyncValue.valueOrNull` is an EXTENSION getter, which does not exist
      // on a dynamic receiver, so the app-settings watcher below threw
      // NoSuchMethodError inside the listener on every mid-run settings change
      // and not one of its pushes ever reached the executor.
      _ref.listen<SequencerDefaults>(sequencerDefaultsProvider, (
        previous,
        next,
      ) {
        if (previous == null) return;
        if (previous.ditherPixels != next.ditherPixels ||
            previous.ditherSettlePixels != next.ditherSettlePixels ||
            previous.ditherSettleTime != next.ditherSettleTime ||
            previous.ditherSettleTimeout != next.ditherSettleTimeout ||
            previous.ditherRaOnly != next.ditherRaOnly) {
          _logger.debug(
            'Dither settings changed during execution, propagating to backend',
            source: 'SequenceExecutor',
          );
          _pushMidRun(
            'the dither settings',
            () => backend.sequencerUpdateDitherConfig(
              pixels: next.ditherPixels,
              settlePixels: next.ditherSettlePixels,
              settleTime: next.ditherSettleTime,
              settleTimeout: next.ditherSettleTimeout,
              raOnly: next.ditherRaOnly,
            ),
          );
        }
      }),
    );

    // Weather Safety's "Auto-park mount" is the other half of the weather
    // park setting (see [_pushParkPolicy]).
    _settingsSubscriptions.add(
      _ref.listen<WeatherSettings>(weatherSettingsProvider, (previous, next) {
        if (previous == null ||
            previous.autoParkEnabled == next.autoParkEnabled) {
          return;
        }
        final settings = _ref.read(appSettingsProvider).valueOrNull;
        if (settings == null) return;
        _pushMidRun(
          'the park settings',
          () => _pushParkPolicy(backend, settings),
        );
      }),
    );

    _settingsSubscriptions.add(
      _ref.listen<AsyncValue<AppSettingsState>>(appSettingsProvider, (
        previous,
        next,
      ) {
        final prevSettings = previous?.valueOrNull;
        final nextSettings = next.valueOrNull;
        if (prevSettings == null || nextSettings == null) return;
        if (prevSettings.latitude != nextSettings.latitude ||
            prevSettings.longitude != nextSettings.longitude) {
          // Same guard as the seed above: a mid-run change that CLEARS the
          // location must not be forwarded as (0, 0), which would arm the
          // altitude trigger against Null Island instead of disarming it.
          if (nextSettings.latitude != 0.0 || nextSettings.longitude != 0.0) {
            _logger.debug(
              'Location changed during execution, propagating to backend',
              source: 'SequenceExecutor',
            );
            _pushMidRun(
              'the observing location',
              () => backend.sequencerUpdateLocation(
                latitude: nextSettings.latitude,
                longitude: nextSettings.longitude,
              ),
            );
          }
        }

        if (prevSettings.parkOnUnsafeWeather !=
                nextSettings.parkOnUnsafeWeather ||
            prevSettings.parkBeforeDawn != nextSettings.parkBeforeDawn) {
          _pushMidRun(
            'the park settings',
            () => _pushParkPolicy(backend, nextSettings),
          );
        }

        if (prevSettings.cameraRetries != nextSettings.cameraRetries ||
            prevSettings.filterWheelRetries !=
                nextSettings.filterWheelRetries) {
          _pushMidRun(
            'the device retries',
            () => _pushDeviceRetries(backend, nextSettings),
          );
        }

        if (prevSettings.safetyFailMode != nextSettings.safetyFailMode) {
          _logger.debug(
            'Safety fail mode changed during execution, propagating to backend',
            source: 'SequenceExecutor',
          );
          // Same weather-safety guard as the start path: a mid-run switch to
          // failClosed on a rig with weather safety disabled would otherwise
          // arm the WeatherUnsafe trigger and abort the running sequence.
          _pushMidRun(
            'the safety fail mode',
            () => _pushEffectiveSafetyFailMode(
              backend,
              nextSettings.safetyFailMode,
            ),
          );
        }

        // Propagate image-grading changes mid-run so the next
        // exposure honours the user's new thresholds.
        final gradingChanged =
            prevSettings.enableImageGrading !=
                nextSettings.enableImageGrading ||
            prevSettings.imageGradingHfrThresholdPx !=
                nextSettings.imageGradingHfrThresholdPx ||
            prevSettings.imageGradingHfrBaselinePercent !=
                nextSettings.imageGradingHfrBaselinePercent ||
            prevSettings.imageGradingEccentricityThreshold !=
                nextSettings.imageGradingEccentricityThreshold ||
            prevSettings.imageGradingStarCountMin !=
                nextSettings.imageGradingStarCountMin ||
            prevSettings.imageGradingMaxConsecutiveRejects !=
                nextSettings.imageGradingMaxConsecutiveRejects;
        if (gradingChanged) {
          _logger.debug(
            'Image-grading settings changed during execution, propagating to backend',
            source: 'SequenceExecutor',
          );
          _pushMidRun(
            'the image-grading thresholds',
            () => backend.sequencerUpdateDefaultQualityCheck(
              hfrThreshold: nextSettings.imageGradingHfrThresholdPx,
              hfrBaselinePercent: nextSettings.imageGradingHfrBaselinePercent,
              eccentricityThreshold:
                  nextSettings.imageGradingEccentricityThreshold,
              starCountMin: nextSettings.imageGradingStarCountMin,
              maxConsecutiveRejects:
                  nextSettings.imageGradingMaxConsecutiveRejects,
              enabled: nextSettings.enableImageGrading,
            ),
          );
        }
        if (prevSettings.imageGradingRejectFolderPath !=
            nextSettings.imageGradingRejectFolderPath) {
          _logger.debug(
            'Reject folder path changed during execution, propagating to backend',
            source: 'SequenceExecutor',
          );
          _pushMidRun(
            'the reject folder',
            () => backend.sequencerUpdateRejectFolderPath(
              nextSettings.imageGradingRejectFolderPath,
            ),
          );
        }

        // Propagate observer name + elevation changes so FITS
        // headers stay in sync if the user edits Settings mid-run.
        if (prevSettings.observerName != nextSettings.observerName ||
            prevSettings.elevation != nextSettings.elevation) {
          _logger.debug(
            'Observer name / elevation changed during execution, propagating to backend',
            source: 'SequenceExecutor',
          );
          _pushMidRun(
            'the observer profile',
            () => _pushObserverProfile(backend),
          );
        }

        // Propagate global adaptive-exposure setting
        // changes so the next exposure honours the user's edit. We
        // compare all eight inputs in one pass because the executor
        // expects the full config object on every push.
        final adaptiveChanged =
            prevSettings.adaptiveExposureEnabled !=
                nextSettings.adaptiveExposureEnabled ||
            prevSettings.adaptiveExposureTargetSnr !=
                nextSettings.adaptiveExposureTargetSnr ||
            prevSettings.adaptiveExposureReferenceMag !=
                nextSettings.adaptiveExposureReferenceMag ||
            prevSettings.adaptiveExposureMinSecs !=
                nextSettings.adaptiveExposureMinSecs ||
            prevSettings.adaptiveExposureMaxSecs !=
                nextSettings.adaptiveExposureMaxSecs ||
            !mapEquals(
              prevSettings.adaptiveExposurePerFilterEnabled,
              nextSettings.adaptiveExposurePerFilterEnabled,
            ) ||
            !mapEquals(
              prevSettings.adaptiveExposurePerFilterMinSecs,
              nextSettings.adaptiveExposurePerFilterMinSecs,
            ) ||
            !mapEquals(
              prevSettings.adaptiveExposurePerFilterMaxSecs,
              nextSettings.adaptiveExposurePerFilterMaxSecs,
            );
        if (adaptiveChanged) {
          _logger.debug(
            'Adaptive-exposure settings changed during execution, propagating to backend',
            source: 'SequenceExecutor',
          );
          _pushMidRun(
            'the adaptive-exposure settings',
            () => nextSettings.adaptiveExposureEnabled
                ? backend.sequencerUpdateDefaultAdaptiveExposure(
                    enabled: nextSettings.adaptiveExposureEnabled,
                    targetSnr: nextSettings.adaptiveExposureTargetSnr,
                    referenceSkyBrightnessMag:
                        nextSettings.adaptiveExposureReferenceMag,
                    minExposureSecs: nextSettings.adaptiveExposureMinSecs,
                    maxExposureSecs: nextSettings.adaptiveExposureMaxSecs,
                    perFilterEnabled:
                        nextSettings.adaptiveExposurePerFilterEnabled,
                    perFilterMinSecs:
                        nextSettings.adaptiveExposurePerFilterMinSecs,
                    perFilterMaxSecs:
                        nextSettings.adaptiveExposurePerFilterMaxSecs,
                  )
                : backend.sequencerClearDefaultAdaptiveExposure(),
          );
        }
      }),
    );

    _settingsSubscriptions.add(
      _ref.listen<EquipmentProfileModel?>(activeEquipmentProfileProvider, (
        previous,
        next,
      ) {
        if (previous == null || next == null) return;
        // EquipmentProfileModel.filterFocusOffsets is already a
        // Map<String,int> in memory; the legacy version of this code
        // decoded it as JSON which was a runtime bug — the analyzer now
        // catches that. Use map equality directly.
        final prevOffsets = previous.filterFocusOffsets;
        final nextOffsets = next.filterFocusOffsets;
        if (!mapEquals(prevOffsets, nextOffsets)) {
          _logger.debug(
            'Filter focus offsets changed during execution, propagating to backend',
            source: 'SequenceExecutor',
          );
          _pushMidRun(
            'the filter focus offsets',
            () => backend.sequencerUpdateFilterOffsets(nextOffsets),
          );
        }

        // Propagate telescope / camera identity changes so FITS
        // headers reflect the active equipment profile mid-run (rare but
        // possible when the user swaps profiles between targets).
        if (previous.cameraName != next.cameraName ||
            previous.telescopeName != next.telescopeName ||
            previous.telescopeFocalLength != next.telescopeFocalLength ||
            previous.telescopeAperture != next.telescopeAperture ||
            previous.focalLength != next.focalLength) {
          _logger.debug(
            'Equipment profile identity changed during execution, propagating to backend',
            source: 'SequenceExecutor',
          );
          _pushMidRun(
            'the observer profile',
            () => _pushObserverProfile(backend),
          );
        }
      }),
    );
  }

  /// Derive the FITS observer profile from the current app settings + active
  /// equipment profile and push it to the executor.
  ///
  /// The observer name comes from app settings; everything else from the active
  /// equipment profile. Null / empty fields are honestly omitted from FITS
  /// rather than emitted as sentinels.
  ///
  /// ONE derivation for three callers — the run-start seed and the two mid-run
  /// watchers (observer name / elevation, and equipment identity) — because the
  /// profile is a *cross-product* of both sources.
  ///
  /// Throws on a failed push. The seed folds that into the start-aborting
  /// `firstError`; the mid-run watchers cannot abort a running sequence, so
  /// they surface it (see [_pushMidRun]).
  Future<void> _pushObserverProfile(NightshadeBackend backend) async {
    final settings = _ref.read(appSettingsProvider).valueOrNull;
    final profile = _ref.read(activeEquipmentProfileProvider);

    // Camera split: profile.cameraName is typically the user-friendly device
    // label (e.g. "ZWO ASI2600MM Pro"). We split on first space for INSTRUME
    // consumers; if there's no space the whole string becomes the model and
    // make is null.
    String? cameraMake;
    String? cameraModel;
    final rawCameraName = profile?.cameraName?.trim();
    if (rawCameraName != null && rawCameraName.isNotEmpty) {
      final spaceIdx = rawCameraName.indexOf(' ');
      if (spaceIdx > 0) {
        cameraMake = rawCameraName.substring(0, spaceIdx).trim();
        cameraModel = rawCameraName.substring(spaceIdx + 1).trim();
      } else {
        cameraModel = rawCameraName;
      }
    }

    // Telescope focal length / aperture: prefer the dedicated telescope_*
    // fields; fall back to focalLength / aperture (the legacy generic fields on
    // EquipmentProfileModel). 0.0 means "not configured" — emit null then.
    double? focalLength;
    double? aperture;
    if (profile != null) {
      final tfl = profile.telescopeFocalLength;
      final fl = profile.focalLength;
      if (tfl != null && tfl > 0) {
        focalLength = tfl;
      } else if (fl > 0) {
        focalLength = fl;
      }

      // Aperture needs the SAME legacy fallback as focal length above: a
      // profile built through the generic optics fields has
      // telescopeAperture == 0 and the real value in `aperture`, so reading
      // only telescopeAperture dropped it and every frame was written with
      // FOCALLEN but no APTDIA — an aperture the operator had configured,
      // missing from the FITS header that photometry reads.
      final ta = profile.telescopeAperture;
      final ap = profile.aperture;
      if (ta != null && ta > 0) {
        aperture = ta;
      } else if (ap > 0) {
        aperture = ap;
      }
    }

    await backend.sequencerUpdateObserverProfile(
      observerName: (settings == null || settings.observerName.isEmpty)
          ? null
          : settings.observerName,
      siteElevationM: (settings != null && settings.elevation > 0)
          ? settings.elevation
          : null,
      cameraMake: cameraMake,
      cameraModel: cameraModel,
      telescopeName: profile?.telescopeName,
      telescopeFocalLengthMm: focalLength,
      telescopeApertureMm: aperture,
    );
    _logger.debug(
      'Pushed observer_profile: observer=${settings?.observerName}, '
      'telescope=${profile?.telescopeName}, camera=$cameraMake $cameraModel, '
      'focal=${focalLength}mm, aperture=${aperture}mm',
      source: 'SequenceExecutor',
    );
  }

  /// Send a mid-run configuration change to the executor and surface a failure.
  ///
  /// The `_ref.listen` callbacks and the sky-brightness tick are synchronous,
  /// so a backend push inside them is fire-and-forget unless it goes through
  /// here: a rejected future becomes an unhandled zone error, the operator is
  /// told nothing, and the run keeps using the config the change was meant to
  /// replace. A `try`/`catch` around an un-awaited push cannot fire either.
  ///
  /// The start-up seed aborts the run on a failed push; a run already imaging
  /// cannot, so [what] is named in the log AND in the run's warnings, where it
  /// survives into `sequence_runs.stats_json` and the post-session report.
  ///
  /// The logger is read HERE, before the await: it is a provider read, and this
  /// work outlives the callback that scheduled it — reading it from inside the
  /// catch is what made a previous incarnation of the sky-brightness guard
  /// throw out of its own error handler.
  void _pushMidRun(String what, Future<void> Function() push) {
    final logger = _logger;
    unawaited(() async {
      try {
        await push();
      } catch (e, st) {
        logger.error(
          'Failed to propagate $what to the running sequence: $e\n$st',
          source: 'SequenceExecutor',
        );
        if (!_disposed) {
          _surfaceRunWarning(
            'A change to $what could not be sent to the running sequence, '
            'which is still using the previous value: $e',
          );
        }
      }
    }());
  }

  void _stopSettingsWatchers() {
    for (final sub in _settingsSubscriptions) {
      sub.close();
    }
    _settingsSubscriptions.clear();
    // Tear down the sky-brightness poll so a stopped
    // executor stops pushing readings to the (possibly torn-down)
    // backend.
    _skyBrightnessPollTimer?.cancel();
    _skyBrightnessPollTimer = null;
    _lastPushedSkyMag = null;
  }

  /// Start the periodic poll that watches the
  /// `SkyBrightnessTracker` and pushes its mag/arcsec² reading to the
  /// executor whenever it changes. Suppresses redundant pushes so the
  /// runtime config event stream stays quiet under steady conditions.
  void _startSkyBrightnessPoll(NightshadeBackend backend) {
    _skyBrightnessPollTimer?.cancel();
    // Capture the logger ONCE, here. It is a provider read, and the tick below
    // outlives the container: reading it from inside the catch block meant the
    // error handler ITSELF threw ("Tried to read a provider from a
    // ProviderContainer that was already disposed"), escaping the try and
    // surfacing as an unhandled async error every 10 seconds. A catch that can
    // throw is not a guard. Same idiom the frame-registration path already uses.
    final logger = _logger;
    _skyBrightnessPollTimer = Timer.periodic(const Duration(seconds: 10), (
      timer,
    ) {
      // Self-cancel if the executor went away between ticks, so a leaked timer
      // can never keep touching a torn-down Ref.
      if (_disposed) {
        timer.cancel();
        return;
      }
      try {
        final tracker = _ref.read(skyBrightnessTrackerProvider);
        final mag = tracker.currentMagPerArcsec2();
        // Throttle on absolute change > 0.05 mag/arcsec²; smaller
        // wobble is observational noise that the adapter doesn't need
        // to see on every tick.
        if (mag != _lastPushedSkyMag) {
          final changed =
              _lastPushedSkyMag == null ||
              mag == null ||
              (mag - (_lastPushedSkyMag ?? 0)).abs() > 0.05;
          if (changed) {
            _lastPushedSkyMag = mag;
            _pushMidRun(
              'the sky brightness',
              () => backend.sequencerUpdateSkyBrightness(mag: mag),
            );
            logger.debug(
              'Pushed sky brightness to executor: ${mag?.toStringAsFixed(2) ?? "<none>"} mag/arcsec²',
              source: 'SequenceExecutor',
            );
          }
        }
      } catch (e) {
        // Don't let a tracker read failure kill the periodic timer — log and
        // keep going. This is best-effort telemetry, not a user-visible fault:
        // a missing sky-brightness sample changes no operator decision.
        logger.debug(
          'Sky brightness poll failed: $e',
          source: 'SequenceExecutor',
        );
      }
    });
  }
}
