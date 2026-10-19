import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart';
import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment/mount_state_provider.dart';
import 'package:skotiq_core/src/providers/secondary_rig_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/providers/ui_notification_provider.dart';
import 'package:skotiq_core/src/providers/weather_providers.dart';
import 'package:skotiq_core/src/services/safe_rig_service.dart';

import '../mocks/mock_backend.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// Records whether the safing workflow was actually executed.
class _RecordingSafeRigService extends SafeRigService {
  _RecordingSafeRigService(super.ref, this._calls)
    : super(stopSecondaryRig: _noSecondary);

  static Future<bool> _noSecondary() async => false;

  /// Reasons passed to every executed safing, shared with the test body so an
  /// unexecuted (never even constructed) service still reads as zero calls.
  final List<String> _calls;

  /// What each executed safing was told to do with an idle mount.
  static final idleMountPolicies = <IdleMountPolicy>[];

  @override
  Future<SafeRigResult> safeTheRig({
    required String reason,
    bool park = true,
    bool closeDome = false,
    bool closeCover = false,
    bool abortExposure = false,
    bool disableCooling = false,
    bool quiesceSecondaryRig = true,
    IdleMountPolicy idleMount = IdleMountPolicy.leave,
    bool notify = true,
  }) async {
    _calls.add(reason);
    idleMountPolicies.add(idleMount);
    return const SafeRigResult();
  }
}

class _FakeSecondaryRig extends SecondaryRigController {
  _FakeSecondaryRig(super.ref, this._armed);
  final bool _armed;

  @override
  Future<bool> isArmed() async => _armed;
}

void main() {
  // Coverage campaign 2026-08: turning "Enable weather safety" on with no
  // weather source, on an idle app with nothing connected, executed the
  // safe-the-rig workflow and announced a rig-safing event. Nothing was — or
  // could be — commanded.
  group('weather safety with nothing to safe', () {
    late MockBackend backend;
    late List<String> safeRigCalls;

    setUp(() {
      backend = MockBackend();
      safeRigCalls = <String>[];
      when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
      when(
        () => backend.sequencerUpdateWeatherVerdict(
          unsafeOverride: any(named: 'unsafeOverride'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => backend.sequencerUpdateCloudMotion(
          currentCoverPercent: any(named: 'currentCoverPercent'),
          predictedArrivalMinutes: any(named: 'predictedArrivalMinutes'),
          predictedOpeningMinutes: any(named: 'predictedOpeningMinutes'),
          predictedOpeningDurationSecs: any(
            named: 'predictedOpeningDurationSecs',
          ),
          predictedClearSkyAlt: any(named: 'predictedClearSkyAlt'),
          predictedClearSkyAz: any(named: 'predictedClearSkyAz'),
        ),
      ).thenAnswer((_) async {});
    });

    ProviderContainer buildContainer({bool secondaryRigArmed = false}) {
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(
              const AppSettingsState(safetyFailMode: SafetyFailMode.failClosed),
            ),
          ),
          weatherSettingsDataProvider.overrideWith(
            (ref) =>
                Stream.value(const WeatherSettings(weatherSafetyEnabled: true)),
          ),
          safeRigServiceProvider.overrideWith(
            (ref) => _RecordingSafeRigService(ref, safeRigCalls),
          ),
          secondaryRigControllerProvider.overrideWith(
            (ref) => _FakeSecondaryRig(ref, secondaryRigArmed),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<void> settle(ProviderContainer container) async {
      await container.read(appSettingsProvider.future);
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test(
      'an idle, disconnected rig is not "safed" and is not alarmed',
      () async {
        final container = buildContainer();
        container.read(weatherSafetyProvider.notifier);
        await settle(container);

        expect(
          container.read(weatherSafetyProvider).status,
          WeatherSafetyStatus.unsafe,
          reason: 'fail-closed with no source still resolves unsafe',
        );
        expect(safeRigCalls, isEmpty, reason: 'nothing could be commanded');

        final notifications = container.read(uiNotificationProvider);
        expect(notifications, isNotEmpty);
        final posted = notifications.last;
        expect(posted.level, UiNotificationLevel.warning);
        expect(posted.title, 'Weather Safety');
        expect(posted.message, contains('nothing was commanded'));
        expect(posted.message, isNot(contains('Rig safed')));
      },
    );

    test('the disclosure is not repeated on every re-evaluation', () async {
      final container = buildContainer();
      final safety = container.read(weatherSafetyProvider.notifier);
      await settle(container);
      final first = container.read(uiNotificationProvider).length;

      safety.forceEvaluation();
      await settle(container);
      safety.forceEvaluation();
      await settle(container);

      expect(container.read(uiNotificationProvider).length, first);
      expect(safeRigCalls, isEmpty);
    });

    test('a tracking mount is still safed, without being parked', () async {
      _RecordingSafeRigService.idleMountPolicies.clear();
      final container = buildContainer();
      final mount = container.read(mountStateProvider.notifier);
      mount.setConnecting('mount-1');
      mount.setConnected();
      mount.setParked(false);
      mount.setTracking(true);

      container.read(weatherSafetyProvider.notifier);
      await settle(container);

      expect(
        safeRigCalls,
        hasLength(1),
        reason: 'the gate must never suppress a real safing',
      );
      expect(_RecordingSafeRigService.idleMountPolicies, [
        IdleMountPolicy.stopTracking,
      ]);
    });

    // The owner found the mount driven into the ground two mornings running:
    // the dawn park sent an idle, not-tracking mount a park command at 05:15
    // with nothing running. There is nothing to protect on such a mount.
    test('an idle mount that is not tracking is left alone', () async {
      final container = buildContainer();
      final mount = container.read(mountStateProvider.notifier);
      mount.setConnecting('mount-1');
      mount.setConnected();
      mount.setParked(false);
      mount.setTracking(false);

      container.read(weatherSafetyProvider.notifier);
      await settle(container);

      expect(safeRigCalls, isEmpty);
    });

    test('an armed secondary rig is still safed', () async {
      final container = buildContainer(secondaryRigArmed: true);
      container.read(weatherSafetyProvider.notifier);
      await settle(container);

      expect(safeRigCalls, hasLength(1));
    });
  });
}
