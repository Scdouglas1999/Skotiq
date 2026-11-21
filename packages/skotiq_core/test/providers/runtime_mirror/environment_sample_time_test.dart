import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/in_memory_database.dart';

class _Backend extends Mock implements FfiBackend {}

class _Fixed extends BackendNotifier {
  _Fixed(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('safety and weather keep the host sample time', () {
    final host = _container();
    final viewer = _container();
    const safetyId = 'safety-1';
    const weatherId = 'weather-1';
    for (final container in [host, viewer]) {
      container.read(safetyMonitorStateProvider.notifier)
        ..setConnecting(safetyId, 'Roof')
        ..setConnected();
      container.read(weatherStateProvider.notifier)
        ..setConnecting(weatherId, 'Sky')
        ..setConnected();
    }

    const channel = EnvironmentChannel();
    final unsampled = channel.encode(_readings(host))!;
    expect(unsampled.containsKey('safety'), isFalse);
    expect(unsampled.containsKey('weather'), isFalse);
    channel.apply(RuntimeApplyContext(viewer), unsampled);
    expect(viewer.read(safetyMonitorStateProvider).lastChecked, isNull);
    expect(viewer.read(weatherStateProvider).lastUpdated, isNull);

    final t = DateTime.utc(2026, 11, 21, 4, 30);
    final t2 = DateTime.utc(2026, 11, 21, 4, 32);
    host
        .read(safetyMonitorStateProvider.notifier)
        .updateSafetyStatus(true, checkedAt: t);
    host
        .read(weatherStateProvider.notifier)
        .updateConditions(temperature: 8.5, sampledAt: t);

    final first = channel.encode(_readings(host))!;
    channel.apply(RuntimeApplyContext(viewer), first);

    expect(viewer.read(safetyMonitorStateProvider).isSafe, isTrue);
    expect(viewer.read(safetyMonitorStateProvider).lastChecked, t);
    expect(viewer.read(weatherStateProvider).lastUpdated, t);

    host
        .read(safetyMonitorStateProvider.notifier)
        .updateSafetyStatus(true, checkedAt: t2);
    final second = channel.encode(_readings(host))!;
    expect(first['safety']['checkedAt'], isNot(second['safety']['checkedAt']));
    channel.apply(RuntimeApplyContext(viewer), second);
    expect(viewer.read(safetyMonitorStateProvider).isSafe, isTrue);
    expect(viewer.read(safetyMonitorStateProvider).lastChecked, t2);

    // An older host that sends no timestamp does not throw.
    channel.apply(RuntimeApplyContext(viewer), {
      'safety': {'deviceId': safetyId, 'safe': true},
    });
    expect(viewer.read(safetyMonitorStateProvider).lastChecked, isNotNull);
  });
}

EnvironmentReadings _readings(ProviderContainer container) => (
  weather: container.read(weatherStateProvider),
  dome: container.read(domeStateProvider),
  safety: container.read(safetyMonitorStateProvider),
);

ProviderContainer _container() {
  final backend = _Backend();
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith((ref) => _Fixed(ref, backend)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}
