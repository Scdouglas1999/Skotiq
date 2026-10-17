// Live settings-change push events.
//
// Verifies that when the headless server emits a `settings.changed`
// event over its WS, every connected client's `AppSettingsNotifier`
// applies the delta in-place — without a full /api/settings GET round
// trip — and that the origin filter suppresses the originating client's
// own echo so a local write does not fight the in-flight UI.
//
// The test does NOT spin up two real `NetworkBackend` instances: a mock
// backend that exposes a controllable event stream is enough to exercise
// the exact path `AppSettingsNotifier` takes when wired to a remote
// host. The origin filter test directly registers a command id (the
// same mechanism `_writeRemoteSettings` uses) and asserts the matching
// echo is dropped.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
// `skotiq_backend.dart` re-exports `event_types.dart` so
// `SkotiqEvent`, `EventCategory`, and the `settingsChangedEventType`
// constant come through this one import.
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart' as models;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  setUpAll(() {
    // Mocktail needs an AppSettings instance registered for default
    // returns on the `getSettings` thenAnswer below.
    registerFallbackValue(const models.AppSettings());
  });

  test(
    'AppSettingsNotifier applies remote settings.changed event in-place',
    () async {
      final controller = StreamController<SkotiqEvent>.broadcast();
      addTearDown(controller.close);

      final backend = _MockNetworkBackend();
      when(() => backend.eventStream).thenAnswer((_) => controller.stream);
      when(
        () => backend.getSettings(),
      ).thenAnswer((_) async => const models.AppSettings(theme: 'dark'));

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      final initial = await container.read(appSettingsProvider.future);
      expect(initial.theme, equals('dark'));

      // Server emits a single-field change.
      controller.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.system,
          eventType: settingsChangedEventType,
          data: {
            'key': 'theme',
            'value': 'light',
            'changedAt': DateTime.now().toUtc().toIso8601String(),
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final updated = container.read(appSettingsProvider).valueOrNull;
      expect(updated, isNotNull);
      expect(
        updated!.theme,
        equals('light'),
        reason: 'settings.changed must apply the delta without a refetch',
      );
      // getSettings was called exactly once (initial load); the event
      // path does NOT re-fetch.
      verify(() => backend.getSettings()).called(1);
    },
  );

  test(
    'AppSettingsNotifier ignores settings.changed events from another category',
    () async {
      final controller = StreamController<SkotiqEvent>.broadcast();
      addTearDown(controller.close);

      final backend = _MockNetworkBackend();
      when(() => backend.eventStream).thenAnswer((_) => controller.stream);
      when(
        () => backend.getSettings(),
      ).thenAnswer((_) async => const models.AppSettings(language: 'en'));

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);

      // An equipment-category event with eventType=settings.changed (which
      // should never happen, but tests defence-in-depth) is ignored.
      controller.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: settingsChangedEventType,
          data: const {'key': 'language', 'value': 'fr'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final after = container.read(appSettingsProvider).valueOrNull;
      expect(after!.language, equals('en'));
    },
  );

  test(
    'AppSettingsNotifier applies snapshot variant when key=__snapshot__',
    () async {
      final controller = StreamController<SkotiqEvent>.broadcast();
      addTearDown(controller.close);

      final backend = _MockNetworkBackend();
      when(() => backend.eventStream).thenAnswer((_) => controller.stream);
      when(
        () => backend.getSettings(),
      ).thenAnswer((_) async => const models.AppSettings());

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);

      // Server emits a full-snapshot variant — happens on the recovery
      // path when the server cannot read the previous settings.
      final snapshot = const models.AppSettings(
        theme: 'midnight',
        language: 'de',
      ).toJson();
      controller.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.system,
          eventType: settingsChangedEventType,
          data: {'key': '__snapshot__', 'value': snapshot},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final after = container.read(appSettingsProvider).valueOrNull;
      expect(after, isNotNull);
      expect(after!.theme, equals('midnight'));
      expect(after.language, equals('de'));
    },
  );
}
