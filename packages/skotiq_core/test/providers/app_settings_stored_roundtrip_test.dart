// Property test for the stored-snapshot serialiser pair.
//
// `_storedMapFromState` (added for the headless settings DB-persistence fix,
// B16) MUST be a true inverse of `_settingsFromStoredMap`:
//
//     _settingsFromStoredMap(_storedMapFromState(s)) == s   for all s
//
// This is what lets the headless `POST /api/settings` persist a full
// `AppSettings` through the same DB path the desktop uses, instead of the lossy
// 7-field Rust-bridge round-trip that silently dropped most settings.
//
// The state below sets EVERY field to a distinct non-default value, so a wrong
// DB key, a missing field, or a mismatched encoding in the inverse is caught:
// any such bug round-trips that field back to its default, breaking equality.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart'
    as models;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  setUpAll(() => registerFallbackValue(const models.AppSettings()));

  test('_storedMapFromState is a true inverse of _settingsFromStoredMap', () async {
    final controller = StreamController<SkotiqEvent>.broadcast();
    addTearDown(controller.close);
    final backend = _MockNetworkBackend();
    when(() => backend.eventStream).thenAnswer((_) => controller.stream);
    when(
      () => backend.getSettings(),
    ).thenAnswer((_) async => const models.AppSettings());

    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    // Every field set to a value distinct from its loader default.
    const populated = AppSettingsState(
      // General
      startMinimized: true,
      autoConnectEquipment: false,
      confirmBeforeClosing: false,
      autoDiscoverOnLaunch: false,
      // Appearance
      theme: 'light',
      language: 'es',
      accentColor: '#abcdef',
      fontSize: 'Large',
      uiScale: '1.5x',
      sidebarCollapsed: true,
      // Location
      latitude: 39.98,
      longitude: -75.35,
      elevation: 123.4,
      timezone: 'America/New_York',
      useSystemTime: false,
      // Imaging
      imageFormat: kCaptureImageFormat,
      fileNamingPattern: r'$SEQ_$FILTER',
      bitDepth: kCaptureBitDepth,
      // Sequencer
      parkOnUnsafeWeather: false,
      parkBeforeDawn: false,
      meridianFlipMinutes: 7,
      autoFocusOnFilterChange: false,
      useFilterFocusOffsets: false,
      autoFocusEveryMinutes: 99,
      ditherEnabled: false,
      ditherEveryFrames: 9,
      cameraRetries: 7,
      filterWheelRetries: 0,
      safetyFailMode: models.SafetyFailMode.failOpen,
      // Plate Solving
      plateSolver: 'Astrometry',
      astapPath: r'C:\astap',
      astrometryPath: '/usr/bin/solve',
      plateSolveTimeout: 123,
      plateSolveSearchRadius: 12.5,
      blindSolve: true,
      // PHD2
      phd2Path: r'C:\phd2',
      phd2Host: '10.0.0.5',
      phd2Port: 4401,
      // Notifications
      notificationsEnabled: false,
      discordWebhook: 'https://discord/x',
      pushoverKey: 'pk',
      pushoverUser: 'pu',
      notifyOnSequenceComplete: false,
      notifyOnError: false,
      notifyOnMeridianFlip: true,
      soundEnabled: false,
      // File Paths
      imageOutputPath: '/out',
      sequencesPath: '/seq',
      databasePath: '/db',
      logsPath: '/logs',
      // Protocol
      indiServerHost: 'indi.local',
      indiServerPort: 7625,
      indiAutoConnect: true,
      alpacaServerHost: 'alp.local',
      alpacaServerPort: 11112,
      alpacaAutoDiscover: true,
      // Web Server
      webServerEnabled: true,
      webServerPort: 9090,
      // Camera
      defaultGain: 139,
      defaultOffset: 64,
      // Mount
      enableMeridianFlip: false,
      // Focuser
      tempCompensation: false,
      tempCoefficient: -7.5,
      backlashCompensation: 25,
      // Guider
      ditherScale: 'Large',
      settleThreshold: 1.5,
      settleTimeout: 45,
      settleTime: 30,
      ditherRaOnly: true,
      // Environment
      bortleClass: 8,
      horizonProfileJson:
          '{"N":10,"NE":10,"E":10,"SE":10,"S":10,"SW":10,"W":10,"NW":10}',
      effectiveHorizonDeg: 20.0,
      audibleAlertsOnCritical: true,
      criticalAlertSound: 'none',
      pushCriticalAlerts: false,
      // Recovery
      recoveryDefaultRetryIntervalMins: 15.0,
      recoveryDefaultMaxDurationMins: 120.0,
      recoveryStopTrackingDuringRecovery: false,
      recoveryAbortOnMeridian: false,
      recoveryAudibleAlertWhenEntered: false,
      // Autofocus
      afMethod: 'Curvature',
      afCurveFitting: 'Parabolic',
      afStepSize: 75,
      afExposureTime: 6.0,
      afInitialOffsetSteps: 5,
      afNumberOfAttempts: 2,
      afUseBrightestNStars: 12,
      afOuterCropRatio: 0.9,
      afInnerCropRatio: 0.1,
      afBinning: 2,
      afRSquaredThreshold: 0.85,
      afDisableGuidingDuringAf: true,
      afFocuserSettleTimeMs: 750,
      afExposuresPerPoint: 3,
      afBacklashCompMethod: 'Absolute',
      afBacklashIn: 400,
      afBacklashOut: 100,
      focuserBacklashOfferMode: 'never',
      afAutofocusFilterName: 'L',
      afFilterSettingsJson: '{"L":{"offset":0}}',
      // Observer
      observerName: 'Tester',
      // Image grading (optionals: mix of non-null and null)
      enableImageGrading: true,
      imageGradingHfrThresholdPx: 4.2,
      imageGradingHfrBaselinePercent: null,
      imageGradingEccentricityThreshold: 0.8,
      imageGradingStarCountMin: null,
      imageGradingMaxConsecutiveRejects: 5,
      imageGradingRejectFolderPath: '/reject',
      // Adaptive exposure
      adaptiveExposureEnabled: true,
      adaptiveExposureTargetSnr: 25.0,
      adaptiveExposureReferenceMag: 20.0,
      adaptiveExposureMinSecs: 10.0,
      adaptiveExposureMaxSecs: 500.0,
      adaptiveExposurePerFilterEnabled: {'Ha': true, 'OIII': false},
      adaptiveExposurePerFilterMinSecs: {'Ha': 30.0},
      adaptiveExposurePerFilterMaxSecs: {'Ha': 300.0},
      // Pre-flight
      preflightStrictness: PreflightStrictness.strict,
      polarAlignmentMaxAgeDays: 14,
      darkLibraryMinCoverage: 20,
      opticalTrainDriftThreshold: 12.0,
      // Smart Night
      smartNightMaxSessionHours: 6.0,
      smartNightDefaultAfCadenceFrames: 30,
      smartNightDefaultIntegrationBudgetMinsPerTarget: 180,
      smartNightIncludeFlatsAtEnd: false,
      smartNightUseSchedulerForMultiTarget: false,
      smartNightSchedulerTargetThreshold: 5,
      smartNightDefaultStrategy: 'narrowband',
      smartNightPolarAlignmentStaleAfterDays: 14,
      smartNightSubExposureFloorSecs: 45.0,
      smartNightSubExposureCeilingSecs: 240.0,
      smartNightTargetSnr: 40.0,
      smartNightAutoPromptEnabled: false,
      promptForNotesAfterRun: false,
      // Session lifecycle
      sessionHandoffAutoPrompt: false,
      campaignRollupSurfaceTargetsTab: false,
      campaignRollupGroupingMode: 'by_target_id',
      // Adaptive sky-conditions
      adaptiveSwapEnabledByDefault: true,
      adaptiveSwapDefaultThreshold: 60.0,
      adaptiveSwapDefaultHysteresisSecs: 240.0,
      conditionsScoreWeights: {
        'transparency': 0.5,
        'seeing': 0.2,
        'cloud': 0.2,
        'wind': 0.1,
      },
    );

    // AppSettingsState has no value `==`, so we assert the property at the
    // stored-map layer instead: serialise -> load -> serialise must reproduce
    // the IDENTICAL map. Because every field above is non-default and every DB
    // key the loader reads is present in `_storedMapFromState`, a stable map
    // proves each field survives the round-trip with the correct key + encoding
    // — any wrong key or mismatched encoding would flip that field back to its
    // default on load and show up as a changed map entry below.
    final roundTripped = notifier.debugRoundTripThroughStoredMap(populated);
    final before = notifier.debugStoredMapFromState(populated);
    final after = notifier.debugStoredMapFromState(roundTripped);
    final broken = <String>[
      for (final k in before.keys)
        if (before[k] != after[k]) '$k: "${before[k]}" -> "${after[k]}"',
    ];
    expect(
      broken,
      isEmpty,
      reason: 'Fields that did not round-trip:\n${broken.join('\n')}',
    );
    // Sanity: the snapshot is comprehensive (every persisted field present).
    expect(before.length, greaterThanOrEqualTo(139));
  });
}
