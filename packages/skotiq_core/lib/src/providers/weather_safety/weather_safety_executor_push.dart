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

  /// Compute the verdict sent to the sequencer's `WeatherUnsafe` trigger.
  ///
  /// `unsafe`:
  ///   * `null` (abstain) when the operator has opted out of weather acting on
  ///     the run — safety disabled, the clear-sky override in force, or a
  ///     permissive fail mode with no data — and when only a forecast says
  ///     cloudy and forecasts only warn. Abstaining never suppresses a
  ///     hardware safety monitor, which the sequencer polls itself.
  ///   * `true` when a weather device at the site is outside its limits,
  ///     dawn is near, the fail-closed no-data path is active, or the forecast
  ///     says cloudy and the operator chose to have forecasts hold the run.
  ///   * `false` otherwise.
  ///
  /// `advisory` is true when the UNSAFE verdict rests only on the forecast:
  /// the sequencer then holds the run and never parks it or ends it.
  ({bool? unsafe, bool advisory}) _computePushedVerdict({
    required WeatherSettings weatherSettings,
    required WeatherSafetyStatus finalStatus,
    required SafetyFailMode failMode,
    required bool useFailMode,
    required bool hardwareWeatherSafe,
    required bool forecastActs,
    required bool forecastHoldsRun,
    required bool dawnParkDue,
  }) {
    if (!weatherSettings.weatherSafetyEnabled ||
        finalStatus == WeatherSafetyStatus.snoozed) {
      return (unsafe: null, advisory: false);
    }

    // No-data fail mode, resolved through the single cross-language truth
    // table. The permissive resolutions abstain rather than assert SAFE.
    if (useFailMode) {
      switch (noDataFailModeResolution(failMode)) {
        case NoDataResolution.unsafe:
          return (unsafe: true, advisory: false);
        case NoDataResolution.safe:
        case NoDataResolution.preserve:
          return (unsafe: null, advisory: false);
      }
    }

    // The safety monitor is left out: the sequencer polls it itself.
    if (!hardwareWeatherSafe || dawnParkDue) {
      return (unsafe: true, advisory: false);
    }
    if (forecastActs) {
      return forecastHoldsRun
          ? (unsafe: true, advisory: true)
          : (unsafe: null, advisory: false);
    }
    return (unsafe: false, advisory: false);
  }

  /// Send the weather verdict to the sequencer's `WeatherUnsafe` trigger.
  ///
  /// Sent on every evaluation and re-sent on every heartbeat. Best-effort: with
  /// no live executor (a disconnected backend throws) there is nothing to
  /// inform, and the next send carries the verdict.
  Future<void> _pushWeatherVerdict(
    bool? verdict, {
    bool advisory = false,
  }) async {
    if (!mounted) return;
    _lastVerdict = (unsafe: verdict, advisory: advisory);
    try {
      final backend = _ref.read(backendProvider);
      await backend.sequencerUpdateWeatherVerdict(
        unsafeOverride: verdict,
        advisory: advisory,
      );
    } catch (_) {
      // No live executor to inform; the next send carries the verdict.
    }
  }

  /// Every minute: re-send the last verdict and the safe period to the
  /// sequencer, and refresh a forecast that has gone quiet. The sequencer
  /// treats a verdict nobody refreshes as missing data, so the app keeps it
  /// fresh whether or not anything changed.
  void _startVerdictHeartbeat() {
    _verdictHeartbeatTimer?.cancel();
    _verdictHeartbeatTimer = Timer.periodic(
      WeatherSafetyNotifier._verdictHeartbeatInterval,
      (_) {
        if (!mounted) return;
        unawaited(_verdictHeartbeat());
      },
    );
  }

  Future<void> _verdictHeartbeat() async {
    _watchDecisionPolicy();
    final last = _lastVerdict;
    if (last != null) {
      await _pushWeatherVerdict(last.unsafe, advisory: last.advisory);
    }
    final resumeAfter = _lastResumeAfterSecs;
    if (resumeAfter != null && mounted) {
      try {
        await _ref
            .read(backendProvider)
            .sequencerSetWeatherResumeAfterSafeSecs(resumeAfter);
      } catch (_) {
        // No live executor; sent again next minute.
      }
    }
    if (!mounted) return;
    final settings = _ref.read(weatherSettingsDataProvider).valueOrNull;
    final alert = _ref.read(weatherAlertServiceProvider).currentAlert;
    if (settings == null || !settings.weatherSafetyEnabled) return;
    final refreshAfter = Duration(seconds: settings.refreshIntervalSeconds);
    if (alert == null ||
        _clock().difference(alert.generatedAt) > refreshAfter) {
      _requestForecastRefresh();
    }
  }

  /// Fetch the forecast again and re-evaluate. The forecast alert is only
  /// produced while something listens to the evaluation provider, which is a
  /// weather widget on screen; without this, a forecast taken under a passing
  /// cloud stayed the verdict for the rest of the night.
  ///
  /// At most one attempt a minute: a forecast that cannot be fetched must not
  /// turn every evaluation into another fetch.
  void _requestForecastRefresh() {
    if (_forecastRefreshInFlight || !mounted) return;
    final last = _lastForecastRefreshAt;
    final now = _clock();
    if (last != null &&
        now.difference(last) <
            WeatherSafetyNotifier._verdictHeartbeatInterval) {
      return;
    }
    _lastForecastRefreshAt = now;
    _forecastRefreshInFlight = true;
    unawaited(() async {
      ProviderSubscription<AsyncValue<WeatherAlert>>? subscription;
      try {
        _ref.invalidate(cloudCoverPercentageProvider);
        _cloudCoverFetchedAt = _clock();
        subscription = _ref.listen<AsyncValue<WeatherAlert>>(
          evaluateWeatherConditionsProvider,
          (_, __) {},
        );
        _ref.invalidate(evaluateWeatherConditionsProvider);
        await _ref
            .read(evaluateWeatherConditionsProvider.future)
            .timeout(const Duration(seconds: 60));
      } catch (error) {
        developer.log(
          'weather: forecast refresh failed: $error',
          name: 'WeatherSafety',
          level: 800,
        );
      } finally {
        subscription?.close();
        _forecastRefreshInFlight = false;
        if (mounted) _evaluateAllSources();
      }
    }());
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
    // No site, no dawn. The unset site reads as 0°, 0°, and measuring dawn
    // there parked (or announced "Astronomical dawn is approaching") half an
    // hour before sunrise on Null Island: 00:20 on a US east-coast night.
    if (!appSettings.hasObserverLocation) return false;
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
