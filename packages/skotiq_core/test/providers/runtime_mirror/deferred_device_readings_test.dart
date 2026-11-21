import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/in_memory_database.dart';
import 'mirror_link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cover and switch readings apply when the device id arrives', () async {
    final backend = MockLinkBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    final client = _client(backend);
    client.read(deferredSlotReadingsProvider);

    const switchId = 'switch-1';
    const coverId = 'cover-1';
    const SwitchChannelsChannel().apply(RuntimeApplyContext(client), {
      'deviceId': switchId,
      'count': 1,
      'names': ['Lamp'],
      'states': [true],
      'descriptions': ['panel'],
      'isBoolean': [false],
      'values': [35],
      'minValues': [0],
      'maxValues': [100],
      'steps': [1],
      'canWrite': [true],
    });
    const CoverCalibratorChannel().apply(RuntimeApplyContext(client), {
      'devices': {
        coverId: {
          'coverPresent': true,
          'calibratorPresent': true,
          'brightness': 85,
          'maxBrightness': 100,
        },
      },
    });

    expect(client.read(switchStateProvider).deviceId, isNull);
    expect(client.read(switchStateProvider).channelValues, isEmpty);

    client.read(switchStateProvider.notifier)
      ..setConnecting(switchId, 'Power')
      ..setConnected();
    client.read(coverCalibratorStateProvider.notifier)
      ..setConnecting(coverId, 'Flat panel')
      ..setConnected();

    expect(client.read(switchStateProvider).channelValues, [35]);
    final cover = await client.read(
      equipmentCoverCalibratorCapabilitiesProvider(coverId).future,
    );
    expect(cover?.brightness, 85);
  });
}

ProviderContainer _client(MockLinkBackend backend) {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith((ref) => _Fixed(ref, backend)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

class _Fixed extends BackendNotifier {
  _Fixed(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}
