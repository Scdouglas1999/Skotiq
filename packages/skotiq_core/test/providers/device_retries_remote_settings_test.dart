// "Camera retries" and "Filter wheel retries" travel with the remote settings
// document, so a phone or a second desktop sees and edits the host's values.

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
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  setUpAll(() => registerFallbackValue(const models.AppSettings()));

  late StreamController<SkotiqEvent> controller;
  late ProviderContainer container;

  Future<void> connect(models.AppSettings hostSettings) async {
    controller = StreamController<SkotiqEvent>.broadcast();
    addTearDown(controller.close);
    final backend = _MockNetworkBackend();
    when(() => backend.eventStream).thenAnswer((_) => controller.stream);
    when(() => backend.getSettings()).thenAnswer((_) async => hostSettings);
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
  }

  test('the host\'s values load and export unchanged', () async {
    await connect(
      const models.AppSettings(cameraRetries: 5, filterWheelRetries: 0),
    );

    final state = container.read(appSettingsProvider).requireValue;
    expect(state.cameraRetries, 5);
    expect(state.filterWheelRetries, 0);
    final exported = container
        .read(appSettingsProvider.notifier)
        .exportRemoteSettings();
    expect(exported.cameraRetries, 5);
    expect(exported.filterWheelRetries, 0);
  });

  test('a document without them reads the default, 3', () async {
    await connect(models.AppSettings.fromJson(const {}));

    final state = container.read(appSettingsProvider).requireValue;
    expect(state.cameraRetries, kDefaultDeviceRetries);
    expect(state.filterWheelRetries, kDefaultDeviceRetries);
  });

  test('a settings.changed push applies, held to the maximum', () async {
    await connect(const models.AppSettings());

    controller.add(
      SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: EventCategory.system,
        eventType: settingsChangedEventType,
        data: const {'key': 'cameraRetries', 'value': 50},
      ),
    );
    controller.add(
      SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: EventCategory.system,
        eventType: settingsChangedEventType,
        data: const {'key': 'filterWheelRetries', 'value': 1},
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final state = container.read(appSettingsProvider).requireValue;
    expect(state.cameraRetries, kMaxDeviceRetries);
    expect(state.filterWheelRetries, 1);
  });
}
