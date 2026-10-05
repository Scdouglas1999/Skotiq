// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

part of '../weather_safety_provider.dart';

/// Periodic pushes from [WeatherSafetyNotifier] into the Rust executor.
extension _WeatherSafetyExecutorPush on WeatherSafetyNotifier {
  // Cloud-motion forwarding to the Rust executor.
  //
  // The Rust cloud-aware triggers (`CloudArrivingIn`, `CloudOpeningIn`,
  // `CloudCoverThreshold`) cannot run radar analysis themselves; we push
  // the live `cloudMotionAnalyzerProvider` output every 60s and call
  // `backend.sequencerUpdateCloudMotion(...)`. The first push runs
  // immediately so a sequence that starts right after app launch has
  // current data on its first evaluator tick.

  void _startCloudMotionPush() {
    _cloudMotionPushTimer?.cancel();
    _cloudMotionPushTimer = Timer.periodic(
      WeatherSafetyNotifier._cloudMotionPushInterval,
      (_) {
        if (!mounted) return;
        unawaited(_pushCloudMotion());
      },
    );
    // Run the first push on the next microtask so any sequence already
    // running gets initial data without waiting a full minute.
    Future<void>.microtask(() {
      if (!mounted) return;
      unawaited(_pushCloudMotion());
    });
  }

  void _startAdaptiveConditionsPush() {
    _adaptiveConditionsPushTimer?.cancel();
    _adaptiveConditionsPushTimer = Timer.periodic(
      WeatherSafetyNotifier._adaptiveConditionsPushInterval,
      (_) {
        if (!mounted) return;
        unawaited(_pushAdaptiveConditions());
      },
    );
    Future<void>.microtask(() {
      if (!mounted) return;
      unawaited(_pushAdaptiveConditions());
    });
  }

  /// Compute the verdict pushed to the Rust executor's `WeatherUnsafe` trigger.
  ///
  /// Returns:
  ///   * `null` (ABSTAIN) when the operator has effectively opted out of
  ///     weather-driven aborts — safety disabled, currently snoozed, or the
  ///     no-data fail-mode is permissive (failOpen / warnOnly). Abstaining
  ///     leaves the Rust trigger to rely solely on its own hardware poll; it
  ///     can never suppress a hardware-unsafe abort.
  ///   * `Some(true)` (UNSAFE) when the NON-HARDWARE Dart sources — API alert,
  ///     hardware-weather thresholds (humidity/wind/rain/cloud), or
  ///     park-before-dawn — say unsafe, OR the fail-closed no-data path is
  ///     active. The hardware **safety-monitor** component is deliberately
  ///     EXCLUDED: Rust already polls `safety_is_safe` and ORs it in, so folding
  ///     it here too would double-count the same device.
  ///   * `Some(false)` (SAFE) when none of the above non-hardware sources are
  ///     unsafe and the operator has NOT opted out.
  ///
  /// This is strictly safety-monotone: it only ever ADDS an unsafe assertion or
  /// ABSTAINS — it never asserts SAFE while a non-hardware source says
  /// UNSAFE.
  bool? _computePushedVerdict({
    required WeatherSettings weatherSettings,
    required WeatherSafetyStatus finalStatus,
    required SafetyFailMode failMode,
    required bool useFailMode,
    required bool apiWeatherSafe,
    required bool hardwareWeatherSafe,
    required bool dawnParkDue,
  }) {
    // Opt-out cases ABSTAIN. `finalStatus == snoozed` covers an active snooze;
    // we also abstain for an explicit just-issued snooze that has not yet been
    // re-evaluated (the snooze() setter pushes status to snoozed directly).
    if (!weatherSettings.weatherSafetyEnabled ||
        finalStatus == WeatherSafetyStatus.snoozed) {
      return null;
    }

    // No-data fail-mode: resolved through the SINGLE cross-language truth table
    // ([noDataFailModeResolution], mirrored by the Rust
    // `safety_fail_mode_no_data_resolution`). `unsafe` asserts UNSAFE (matches
    // finalStatus); the permissive resolutions (`safe` / `preserve`) ABSTAIN
    // rather than assert SAFE, so a permissive fail-mode can never suppress a
    // hardware-unsafe abort.
    if (useFailMode) {
      switch (noDataFailModeResolution(failMode)) {
        case NoDataResolution.unsafe:
          return true;
        case NoDataResolution.safe:
        case NoDataResolution.preserve:
          return null;
      }
    }

    // Normal path: fold the non-hardware sources. The safety monitor is
    // intentionally absent (Rust evaluates it once). `dawnParkDue` is folded so
    // the park-before-dawn abort also reaches the in-sequencer trigger.
    final nonHardwareUnsafe =
        !apiWeatherSafe || !hardwareWeatherSafe || dawnParkDue;
    return nonHardwareUnsafe;
  }

  /// Defense-in-depth (full-night audit 2026-06-04): forward the
  /// weather-safety verdict to the Rust executor's `WeatherUnsafe` trigger.
  ///
  /// Pushed on every evaluation so the in-sequencer trigger has a current
  /// verdict on its next tick, regardless of whether a hardware safety device
  /// is connected. Best-effort like the cloud-motion push: the backend may be
  /// disconnected (DisconnectedBackend throws), in which case there is no live
  /// executor to inform and we swallow the error.
  ///
  /// `verdict` is `null` (abstain), `true` (unsafe) or `false` (safe) — see
  /// [_computePushedVerdict]. The Rust side ORs `Some(true)` as an additional
  /// unsafe source and treats `Some(false)` / `None` as non-asserting, so this
  /// channel can only ever add-unsafe or abstain — it never weakens the
  /// hardware gate.
  Future<void> _pushWeatherVerdict(bool? verdict) async {
    if (!mounted) return;
    try {
      final backend = _ref.read(backendProvider);
      await backend.sequencerUpdateWeatherVerdict(unsafeOverride: verdict);
    } catch (_) {
      // No live executor to inform (e.g. backend disconnected). The verdict is
      // re-pushed on the next evaluation; the Dart SafeRig path remains the
      // primary enforcement layer.
    }
  }

  /// Read the current cloud cover, re-fetching when the cached sample is
  /// older than its TTL (shorter when the last fetch failed). The first call
  /// stamps the clock without invalidating so it shares whatever fetch the UI
  /// already triggered.
  Future<double?> _freshCloudCover() async {
    final now = DateTime.now();
    final fetchedAt = _cloudCoverFetchedAt;
    if (fetchedAt == null) {
      _cloudCoverFetchedAt = now;
    } else {
      final hasValue =
          _ref.read(cloudCoverPercentageProvider).valueOrNull != null;
      final ttl = hasValue
          ? WeatherSafetyNotifier._cloudCoverTtl
          : WeatherSafetyNotifier._cloudCoverErrorRetryTtl;
      if (now.difference(fetchedAt) > ttl) {
        _ref.invalidate(cloudCoverPercentageProvider);
        _cloudCoverFetchedAt = now;
      }
    }
    return _ref.read(cloudCoverPercentageProvider.future);
  }

  Future<void> _pushCloudMotion() async {
    if (!mounted) return;
    try {
      // Read the latest analyzer output. The provider auto-fetches the
      // most recent radar frames; we deliberately use a fresh `.future`
      // grab rather than caching so a manual weather refresh in the UI
      // shows up here immediately.
      final motion = await _ref.read(analyzeCloudMotionProvider.future);
      final cover = await _freshCloudCover();
      if (!mounted) return;
      // Cloud arrival prediction: present only when the analyzer reports
      // a finite eta (cloudMotion.etaToLocation). If the analyzer has no
      // motion / no nearby clouds, push None so the Rust trigger stays
      // quiescent: a sentinel here would arrive as a real arrival time.
      final arrivalMinutes = motion?.etaToLocation?.inSeconds != null
          ? motion!.etaToLocation!.inSeconds / 60.0
          : null;

      // The analyzer does not yet model future openings. Preserve that honest
      // absence instead of manufacturing "opening now for 30 minutes" from a
      // single low-cover sample: doing so can fire CloudOpeningIn and resume a
      // paused sequence without any forecast evidence. Current cover still
      // drives CloudCoverThreshold independently.

      // Clear-sky direction: the analyzer does not yet report a single
      // (alt, az) target. Until that lands we leave the direction
      // unspecified — `SlewToGapAndContinue` falls back to
      // `PauseAndWaitForClear` when no direction is reported, which is
      // the documented behaviour.
      final backend = _ref.read(backendProvider);
      await backend.sequencerUpdateCloudMotion(
        currentCoverPercent: cover,
        predictedArrivalMinutes: arrivalMinutes,
        predictedOpeningMinutes: null,
        predictedOpeningDurationSecs: null,
        predictedClearSkyAlt: null,
        predictedClearSkyAz: null,
      );
    } catch (e, stack) {
      // Cloud-motion push is opportunistic forecast telemetry layered on top
      // of the authoritative SafeRig (Dart) and WeatherUnsafe (Rust) gates, so
      // a failure here must never propagate and block the safety path. It is
      // still a diagnosable condition (analyzer not ready yet, radar fetch
      // in-flight, or backend disconnected), so record it at a low severity
      // instead of silently dropping it.
      developer.log(
        'weather: cloud-motion push failed: $e',
        name: 'WeatherSafety',
        level: 700,
        error: e,
        stackTrace: stack,
      );
    }
  }

  Future<void> _pushAdaptiveConditions() async {
    if (!mounted) return;
    try {
      final appSettings = _ref.read(appSettingsProvider).valueOrNull;
      final weather = _ref.read(weatherStateProvider);
      final cloudCover = await _freshCloudCover();
      if (!mounted) return;

      final (_, transparency) = _ref.read(currentScienceSnapshotProvider);
      final hfrValues = _currentHfrValues();
      final inputs = AdaptiveSwapInputComposer.fromTelemetry(
        transparencyPercent: transparency?.transparencyPercent,
        recentHfr: hfrValues,
        hardwareCloudCoverPercent: weather.cloudCover,
        apiCloudCoverPercent: cloudCover,
        windKph: weather.windSpeedKph,
      );
      final weights = _conditionsScoreWeights(appSettings);
      final driver = AdaptiveSwapDriver(
        composer: AdaptiveSwapService(weights: weights),
        backend: _ref.read(backendProvider),
      );
      await driver.tick(inputs);
    } catch (_) {
      // Periodic telemetry forwarding is opportunistic: disconnected remote
      // clients, missing weather APIs, or an unopened database should not spam
      // the operator. The executor receives a real null score when telemetry
      // is merely absent; this catch is for transport/provider failures.
    }
  }

  List<double?> _currentHfrValues() {
    return _ref
        .read(sessionImagesProvider)
        .map((image) => image.stats?.hfr)
        .toList(growable: false);
  }

  ConditionsScoreWeights _conditionsScoreWeights(AppSettingsState? settings) {
    final weights =
        settings?.conditionsScoreWeights ?? const <String, double>{};
    return ConditionsScoreWeights(
      transparencyWeight: weights['transparency'] ?? 0.40,
      seeingWeight: weights['seeing'] ?? 0.25,
      cloudWeight: weights['cloud'] ?? 0.25,
      windWeight: weights['wind'] ?? 0.10,
    );
  }

  bool _isParkBeforeDawnDue(AppSettingsState? appSettings) {
    if (appSettings == null || !appSettings.parkBeforeDawn) return false;
    final now = _clock();
    // The next dawn, not the dawn after today's noon. Dawn comes after
    // midnight, and from midnight on, "today's night" is the one that starts
    // this evening, so asking only for it measured the lead time to TOMORROW's
    // dawn and the park never fired. Yesterday's night comes first because its
    // dawn, when still ahead, is the one about to happen.
    for (final day in [now.subtract(const Duration(days: 1)), now]) {
      final dawn = SkyCalculations.computeTwilight(
        noonLocal: DateTime(day.year, day.month, day.day, 12),
        latitudeDegrees: appSettings.latitude,
        longitudeDegrees: appSettings.longitude,
        kind: TwilightKind.astronomical,
      ).morningStart?.toLocal();
      if (dawn == null || now.isAfter(dawn)) continue;
      return dawn.difference(now) <=
          WeatherSafetyNotifier._parkBeforeDawnLeadTime;
    }
    return false;
  }
}
