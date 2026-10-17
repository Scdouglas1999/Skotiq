// Remote/mobile settings coverage + fail-loud.
//
//   * Settings the remote wire model CAN carry (Image Grading, Adaptive
//     exposure) round-trip through `_toRemoteSettings` instead of being
//     silently dropped when saved over a NetworkBackend.
//   * Settings the wire model CANNOT carry (e.g. park-on-unsafe-weather)
//     FAIL LOUD on a remote save instead of silently no-op'ing.
//   * Inbound `settings.changed` events for the newly-mapped keys are
//     applied in-place.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart'
    as models;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }

  void replace(SkotiqBackend backend) => state = backend;
}

void main() {
  setUpAll(() {
    registerFallbackValue(const models.AppSettings());
  });

  /// Wire a mock NetworkBackend that records the last `updateSettings*`
  /// payload so a test can assert what actually crossed the wire.
  ({
    _MockNetworkBackend backend,
    StreamController<SkotiqEvent> events,
    List<models.AppSettings> writes,
  })
  buildBackend(
    models.AppSettings initial, {
    Completer<void>? firstWriteGate,
    Object? firstWriteError,
    Object? fetchError,
  }) {
    final controller = StreamController<SkotiqEvent>.broadcast();
    final backend = _MockNetworkBackend();
    final writes = <models.AppSettings>[];
    when(() => backend.eventStream).thenAnswer((_) => controller.stream);
    when(() => backend.getSettings()).thenAnswer((_) async {
      if (fetchError != null) throw fetchError;
      return initial;
    });
    when(
      () => backend.updateSettingsWithCommandId(
        any(),
        commandId: any(named: 'commandId'),
      ),
    ).thenAnswer((invocation) async {
      writes.add(invocation.positionalArguments.first as models.AppSettings);
      if (writes.length == 1 && firstWriteGate != null) {
        await firstWriteGate.future;
      }
      if (writes.length == 1 && firstWriteError != null) {
        throw firstWriteError;
      }
    });
    when(() => backend.updateSettings(any())).thenAnswer((invocation) async {
      writes.add(invocation.positionalArguments.first as models.AppSettings);
    });
    return (backend: backend, events: controller, writes: writes);
  }

  ProviderContainer containerFor(_MockNetworkBackend backend) {
    return ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
  }

  test(
    'failed remote fetch remains visibly unavailable, not defaults',
    () async {
      final h = buildBackend(
        const models.AppSettings(),
        fetchError: StateError('host settings unavailable'),
      );
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      await expectLater(
        container.read(appSettingsProvider.future),
        throwsA(isA<StateError>()),
      );

      expect(container.read(appSettingsProvider).hasError, isTrue);
      expect(container.read(appSettingsProvider).valueOrNull, isNull);
    },
  );

  test('failed setter futures also publish a visible write failure', () async {
    final h = buildBackend(
      const models.AppSettings(),
      firstWriteError: StateError('host rejected write'),
    );
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    final write = container
        .read(appSettingsProvider.notifier)
        .setDefaultGain(321);
    await expectLater(write, throwsA(isA<StateError>()));

    final failure = container.read(appSettingsWriteFailureProvider);
    expect(failure, isNotNull);
    expect(failure!.setting, 'default_gain');
  });

  test('queued writes cannot jump from an old host to a new host', () async {
    final gate = Completer<void>();
    final first = buildBackend(
      const models.AppSettings(defaultGain: 100),
      firstWriteGate: gate,
    );
    final second = buildBackend(const models.AppSettings(defaultGain: 200));
    addTearDown(first.events.close);
    addTearDown(second.events.close);
    late _FixedBackendNotifier backendNotifier;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => backendNotifier = _FixedBackendNotifier(ref, first.backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);

    final inFlight = container
        .read(appSettingsProvider.notifier)
        .setDefaultGain(150);
    while (first.writes.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final queued = container
        .read(appSettingsProvider.notifier)
        .setDefaultOffset(42);
    final inFlightFailed = expectLater(inFlight, throwsA(isA<StateError>()));
    final queuedFailed = expectLater(queued, throwsA(isA<StateError>()));

    backendNotifier.replace(second.backend);
    await container.read(appSettingsProvider.future);
    gate.complete();

    await inFlightFailed;
    await queuedFailed;
    expect(second.writes, isEmpty);
  });

  test(
    'image grading enable round-trips through the remote wire model',
    () async {
      final h = buildBackend(const models.AppSettings());
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);

      await container
          .read(appSettingsProvider.notifier)
          .setEnableImageGrading(true);

      expect(
        h.writes,
        isNotEmpty,
        reason: 'a remote save must forward the change to the host',
      );
      expect(
        h.writes.last.enableImageGrading,
        isTrue,
        reason: 'grading flag must be carried by the wire model, not dropped',
      );
    },
  );

  test(
    'adaptive-exposure enable round-trips through the remote wire model',
    () async {
      final h = buildBackend(const models.AppSettings());
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);

      await container
          .read(appSettingsProvider.notifier)
          .setAdaptiveExposureEnabled(true);

      expect(h.writes.last.adaptiveExposureEnabled, isTrue);
    },
  );

  test('non-remotable setting FAILS LOUD on a remote save', () async {
    final h = buildBackend(const models.AppSettings());
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);

    // start_minimized is a desktop-shell window pref that is NOT carried by
    // models.AppSettings (genuinely host-local, not an imaging knob), so a
    // remote save of it would silently vanish on the host. The guard must
    // throw. (This is part of the true residual deny-set: window/shell UI
    // prefs, host-filesystem infra paths, the horizon-mask JSON blob, and the
    // adaptive-swap scheduler-seed cluster.)
    await expectLater(
      container.read(appSettingsProvider.notifier).setStartMinimized(true),
      throwsA(isA<UnsupportedError>()),
    );

    expect(
      h.writes,
      isEmpty,
      reason: 'a non-remotable key must never reach the host',
    );
  });

  // sidebar_collapsed is a per-device chrome pref (like ui_scale): on a
  // remote client it must persist to the LOCAL store — `POST /api/settings`
  // is admin-scoped, so a control-token client used to throw before the
  // state patch and the rail never toggled.
  test('sidebar collapse is device-local on a remote client', () async {
    final h = buildBackend(const models.AppSettings());
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    expect(
      container.read(appSettingsProvider).valueOrNull?.sidebarCollapsed,
      isTrue,
      reason: 'the rail defaults to collapsed',
    );
    await container
        .read(appSettingsProvider.notifier)
        .setSidebarCollapsed(false);

    expect(
      container.read(appSettingsProvider).valueOrNull?.sidebarCollapsed,
      isFalse,
    );
    expect(
      await container.read(settingsDaoProvider).getSetting('sidebar_collapsed'),
      'false',
    );
    verifyNever(() => h.backend.updateSettings(any()));
    verifyNever(
      () => h.backend.updateSettingsWithCommandId(
        any(),
        commandId: any(named: 'commandId'),
      ),
    );
    expect(container.read(appSettingsWriteFailureProvider), isNull);
  });

  // Full remote-settings parity 2026-06-05 — the remaining setter-reachable
  // unattended-night knobs (equipment defaults / web-server / PHD2 connection /
  // notification toggles / session-lifecycle + campaign-rollup / detailed
  // autofocus sweep) are now carried by models.AppSettings, so a remote save
  // round-trips instead of failing loud.
  test('equipment defaults (gain/offset/cooling) round-trip', () async {
    final h = buildBackend(const models.AppSettings());
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    await container.read(appSettingsProvider.notifier).setDefaultGain(120);
    await container.read(appSettingsProvider.notifier).setDefaultOffset(64);

    expect(h.writes.last.defaultGain, 120);
    expect(h.writes.last.defaultOffset, 64);
  });

  test('web-server enable + port round-trip', () async {
    final h = buildBackend(const models.AppSettings());
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    await container
        .read(appSettingsProvider.notifier)
        .setWebServerEnabled(true);
    await container.read(appSettingsProvider.notifier).setWebServerPort(9090);

    expect(h.writes.last.webServerEnabled, isTrue);
    expect(h.writes.last.webServerPort, 9090);
  });

  test('PHD2 connection (host/port/path) round-trips', () async {
    final h = buildBackend(const models.AppSettings());
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    await container.read(appSettingsProvider.notifier).setPhd2Host('10.0.0.5');
    await container.read(appSettingsProvider.notifier).setPhd2Port(4401);
    await container
        .read(appSettingsProvider.notifier)
        .setPhd2Path(r'C:\PHD2\phd2.exe');

    expect(h.writes.last.phd2Host, '10.0.0.5');
    expect(h.writes.last.phd2Port, 4401);
    expect(h.writes.last.phd2Path, r'C:\PHD2\phd2.exe');
  });

  test('overlapping remote writes cannot revert each other', () async {
    final firstWriteGate = Completer<void>();
    final h = buildBackend(
      const models.AppSettings(),
      firstWriteGate: firstWriteGate,
    );
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);
    final hostWrite = notifier.setPhd2Host('10.0.0.5');
    await Future<void>.delayed(Duration.zero);
    final portWrite = notifier.setPhd2Port(4401);
    await Future<void>.delayed(Duration.zero);

    expect(
      h.writes,
      hasLength(1),
      reason: 'the second full-snapshot POST must wait for the first',
    );
    firstWriteGate.complete();
    await Future.wait([hostWrite, portWrite]);

    expect(h.writes, hasLength(2));
    expect(h.writes.last.phd2Host, '10.0.0.5');
    expect(h.writes.last.phd2Port, 4401);
  });

  test('one failed settings write does not poison later writes', () async {
    final h = buildBackend(
      const models.AppSettings(),
      firstWriteError: StateError('host temporarily unavailable'),
    );
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);
    await expectLater(
      notifier.setPhd2Host('10.0.0.5'),
      throwsA(isA<StateError>()),
    );
    await notifier.setPhd2Port(4401);

    expect(h.writes, hasLength(2));
    expect(h.writes.last.phd2Host, isNot('10.0.0.5'));
    expect(h.writes.last.phd2Port, 4401);
  });

  test('notification toggles round-trip', () async {
    final h = buildBackend(const models.AppSettings());
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    await container
        .read(appSettingsProvider.notifier)
        .setNotificationsEnabled(false);
    await container.read(appSettingsProvider.notifier).setNotifyOnError(false);

    expect(h.writes.last.notificationsEnabled, isFalse);
    expect(h.writes.last.notifyOnError, isFalse);
  });

  test('detailed autofocus sweep params round-trip', () async {
    final h = buildBackend(const models.AppSettings());
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    await container.read(appSettingsProvider.notifier).setAfStepSize(75);
    await container.read(appSettingsProvider.notifier).setAfExposureTime(6.5);
    await container
        .read(appSettingsProvider.notifier)
        .setAfCurveFitting('Parabolic');

    expect(h.writes.last.afStepSize, 75);
    expect(h.writes.last.afExposureTime, 6.5);
    expect(h.writes.last.afCurveFitting, 'Parabolic');
  });

  test('session-lifecycle + campaign-rollup prefs round-trip', () async {
    final h = buildBackend(const models.AppSettings());
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    await container
        .read(appSettingsProvider.notifier)
        .setSessionHandoffAutoPrompt(false);
    await container
        .read(appSettingsProvider.notifier)
        .setCampaignRollupGroupingMode('by_target_id');

    expect(h.writes.last.sessionHandoffAutoPrompt, isFalse);
    expect(h.writes.last.campaignRollupGroupingMode, 'by_target_id');
  });

  test(
    'inbound settings.changed for defaultGain is applied in-place',
    () async {
      final h = buildBackend(const models.AppSettings(defaultGain: 100));
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      final initial = await container.read(appSettingsProvider.future);
      expect(initial.defaultGain, 100);

      h.events.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.system,
          eventType: settingsChangedEventType,
          data: const {'key': 'defaultGain', 'value': 200},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final after = container.read(appSettingsProvider).valueOrNull;
      expect(after!.defaultGain, 200);
    },
  );

  // Full-night audit 2026-06-04 follow-up (long tail) — the remaining
  // high-value unattended-night knobs (calibration / dark-library / pre-flight
  // / smart-night defaults / site / meridian-flip detail) are now carried by
  // models.AppSettings, so a remote save round-trips instead of failing loud.
  test(
    'dark-library min coverage round-trips through the remote wire model',
    () async {
      final h = buildBackend(const models.AppSettings());
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      await container
          .read(appSettingsProvider.notifier)
          .setDarkLibraryMinCoverage(25);

      expect(h.writes.last.darkLibraryMinCoverage, 25);
    },
  );

  test(
    'pre-flight strictness round-trips (enum carried as its name)',
    () async {
      final h = buildBackend(const models.AppSettings());
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      await container
          .read(appSettingsProvider.notifier)
          .setPreflightStrictness(PreflightStrictness.strict);

      expect(
        h.writes.last.preflightStrictness,
        'strict',
        reason: 'the enum must cross the wire as its .name',
      );
    },
  );

  test('smart-night target SNR + max session hours round-trip', () async {
    final h = buildBackend(const models.AppSettings());
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    await container
        .read(appSettingsProvider.notifier)
        .setSmartNightTargetSnr(42.0);
    await container
        .read(appSettingsProvider.notifier)
        .setSmartNightMaxSessionHours(6.5);

    expect(h.writes.last.smartNightTargetSnr, 42.0);
    expect(h.writes.last.smartNightMaxSessionHours, 6.5);
  });

  test('smart-night wizard defaults use one complete remote write', () async {
    final h = buildBackend(const models.AppSettings());
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    await container
        .read(appSettingsProvider.notifier)
        .updateSmartNightWizardDefaults(
          maxSessionHours: 7.5,
          afCadenceFrames: 18,
          integrationBudgetMinsPerTarget: 95,
          includeFlatsAtEnd: true,
          useSchedulerForMultiTarget: true,
          schedulerTargetThreshold: 4,
          polarAlignmentStaleAfterDays: 21,
          subExposureFloorSecs: 20,
          subExposureCeilingSecs: 420,
          targetSnr: 35,
          strategy: 'narrowband_hoo',
          autoSelect: true,
          autoSelectCount: 3,
        );

    expect(h.writes, hasLength(1));
    final saved = h.writes.single;
    expect(saved.smartNightMaxSessionHours, 7.5);
    expect(saved.smartNightDefaultAfCadenceFrames, 18);
    expect(saved.smartNightDefaultIntegrationBudgetMinsPerTarget, 95);
    expect(saved.smartNightDefaultStrategy, 'narrowband_hoo');
    expect(saved.smartNightAutoSelect, isTrue);
    expect(saved.smartNightAutoSelectCount, 3);
  });

  test(
    'calibration (settle threshold) + meridian-flip enable round-trip',
    () async {
      final h = buildBackend(const models.AppSettings());
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      await container
          .read(appSettingsProvider.notifier)
          .setSettleThreshold(1.25);
      await container
          .read(appSettingsProvider.notifier)
          .setEnableMeridianFlip(false);

      expect(h.writes.last.settleThreshold, 1.25);
      expect(h.writes.last.enableMeridianFlip, isFalse);
    },
  );

  test(
    'site (bortle class) round-trips through the remote wire model',
    () async {
      final h = buildBackend(const models.AppSettings());
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      await container.read(appSettingsProvider.notifier).setBortleClass(3);

      expect(h.writes.last.bortleClass, 3);
    },
  );

  test(
    'inbound settings.changed for smartNightTargetSnr is applied in-place',
    () async {
      final h = buildBackend(
        const models.AppSettings(smartNightTargetSnr: 30.0),
      );
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      final initial = await container.read(appSettingsProvider.future);
      expect(initial.smartNightTargetSnr, 30.0);

      h.events.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.system,
          eventType: settingsChangedEventType,
          data: const {'key': 'smartNightTargetSnr', 'value': 55.0},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final after = container.read(appSettingsProvider).valueOrNull;
      expect(after!.smartNightTargetSnr, 55.0);
    },
  );

  // Full-night audit 2026-06-04 follow-up — the high-value unattended-night
  // knobs (autofocus / dither / weather-safety / recovery) are now carried by
  // models.AppSettings, so a remote save round-trips instead of failing loud.
  test(
    'park-on-unsafe-weather round-trips through the remote wire model',
    () async {
      final h = buildBackend(const models.AppSettings());
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);

      await container
          .read(appSettingsProvider.notifier)
          .setParkOnUnsafeWeather(false);

      expect(
        h.writes,
        isNotEmpty,
        reason: 'a remote save must forward the change to the host',
      );
      expect(
        h.writes.last.parkOnUnsafeWeather,
        isFalse,
        reason: 'park-on-unsafe-weather must be carried, not dropped',
      );
    },
  );

  test(
    'dither enable + scale round-trip through the remote wire model',
    () async {
      final h = buildBackend(const models.AppSettings());
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);

      await container
          .read(appSettingsProvider.notifier)
          .setDitherEnabled(false);
      await container
          .read(appSettingsProvider.notifier)
          .setDitherScale('Large');

      expect(h.writes.last.ditherEnabled, isFalse);
      expect(h.writes.last.ditherScale, 'Large');
    },
  );

  test(
    'autofocus disable-guiding round-trips through the remote wire model',
    () async {
      final h = buildBackend(const models.AppSettings());
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);

      await container
          .read(appSettingsProvider.notifier)
          .setAfDisableGuidingDuringAf(true);

      expect(h.writes.last.afDisableGuidingDuringAf, isTrue);
    },
  );

  test(
    'recovery max-duration round-trips through the remote wire model',
    () async {
      final h = buildBackend(const models.AppSettings());
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);

      await container
          .read(appSettingsProvider.notifier)
          .setRecoveryDefaultMaxDurationMins(120.0);

      expect(h.writes.last.recoveryDefaultMaxDurationMins, 120.0);
    },
  );

  test(
    'inbound settings.changed for ditherScale is applied in-place',
    () async {
      final h = buildBackend(const models.AppSettings(ditherScale: 'Medium'));
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      final initial = await container.read(appSettingsProvider.future);
      expect(initial.ditherScale, 'Medium');

      h.events.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.system,
          eventType: settingsChangedEventType,
          data: const {'key': 'ditherScale', 'value': 'Large'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final after = container.read(appSettingsProvider).valueOrNull;
      expect(after!.ditherScale, 'Large');
    },
  );

  test(
    'inbound settings.changed for enableImageGrading is applied in-place',
    () async {
      final h = buildBackend(
        const models.AppSettings(enableImageGrading: false),
      );
      addTearDown(h.events.close);
      final container = containerFor(h.backend);
      addTearDown(container.dispose);

      final initial = await container.read(appSettingsProvider.future);
      expect(initial.enableImageGrading, isFalse);

      h.events.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.system,
          eventType: settingsChangedEventType,
          data: const {'key': 'enableImageGrading', 'value': true},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final after = container.read(appSettingsProvider).valueOrNull;
      expect(after!.enableImageGrading, isTrue);
    },
  );
}
