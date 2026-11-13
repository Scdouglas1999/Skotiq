import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../harness/in_memory_database.dart';

// UI state shared between a host and its linked clients through runtime
// channels: framing rotation and mosaic, the pre-start unpark countdown, the
// host's manual loop, cover/calibrator and switch readings, and the host
// following an exposure it did not start.

class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

({ProviderContainer container, List<SkotiqEvent> sent}) _host() {
  final backend = _MockFfiBackend();
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );
  final sent = <SkotiqEvent>[];
  container.read(hostMutationEventHubProvider).wsBroadcast = sent.add;
  container.read(hostRuntimeMirrorProvider);
  return (container: container, sent: sent);
}

_MockNetworkBackend _clientBackend() {
  final backend = _MockNetworkBackend();
  when(
    () => backend.connectionState,
  ).thenReturn(BackendConnectionState.connected);
  when(() => backend.isAuthTokenRejected).thenReturn(false);
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  when(
    () => backend.reportRuntimeState(
      channel: any(named: 'channel'),
      value: any(named: 'value'),
      origin: any(named: 'origin'),
    ),
  ).thenAnswer((_) async {});
  return backend;
}

ProviderContainer _client(_MockNetworkBackend backend) => ProviderContainer(
  overrides: [
    inMemoryDatabaseOverride(),
    backendProvider.overrideWith((ref) => _FixedBackendNotifier(ref, backend)),
  ],
);

List<HostRuntimeUpdate> _updates(List<SkotiqEvent> sent, String channel) => sent
    .where((e) => e.eventType == hostRuntimeStateEventType)
    .map((e) => HostRuntimeUpdate.fromJson(e.data)!)
    .where((u) => u.channel == channel)
    .toList();

/// Through JSON, as a client receives it.
HostRuntimeUpdate _overWire(HostRuntimeUpdate update) =>
    HostRuntimeUpdate.fromJson(
      jsonDecode(jsonEncode(update.toEvent().data)) as Map<String, dynamic>,
    )!;

List<Object?> _reported(_MockNetworkBackend backend, String channel) {
  try {
    return verify(
      () => backend.reportRuntimeState(
        channel: channel,
        value: captureAny(named: 'value'),
        origin: any(named: 'origin'),
      ),
    ).captured;
  } on TestFailure {
    return const [];
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
  });

  group('framing rotation and mosaic', () {
    test('a change on the client reaches the host, whose broadcast is not '
        'applied back on the client', () async {
      final backend = _clientBackend();
      final client = _client(backend);
      addTearDown(client.dispose);
      client.read(clientRuntimeReporterProvider);

      final framing = client.read(framingProvider.notifier);
      framing.setRotation(90);
      framing.setMosaicColumns(3);
      framing.setMosaicEnabled(true);
      // The channel coalesces a drag to one report per 150 ms.
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final sent = _reported(backend, 'framingGeometry');
      expect(sent, isNotEmpty);
      final value = sent.last as Map<String, dynamic>;
      expect(value['rotation'], 90.0);
      expect(value['columns'], 3);
      expect(value['mosaicEnabled'], isTrue);

      final host = _host();
      addTearDown(host.container.dispose);
      expect(
        applyClientRuntimeReport(
          host.container,
          channel: 'framingGeometry',
          value: value,
          origin: runtimeMirrorOrigin,
        ),
        isTrue,
      );
      final hostFraming = host.container.read(framingProvider);
      expect(hostFraming.rotation, 90.0);
      expect(hostFraming.mosaicEnabled, isTrue);
      expect(hostFraming.mosaicConfig.columns, 3);

      // The host's broadcast names the client, which does not apply it.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final echo = _updates(host.sent, 'framingGeometry').last;
      expect(echo.origin, runtimeMirrorOrigin);
      framing.setRotation(-45);
      applyHostRuntimeUpdate(client, _overWire(echo), networkBackend: backend);
      expect(client.read(framingProvider).rotation, -45.0);
    });

    test('a change on the host reaches the client, which does not report it '
        'back', () async {
      final host = _host();
      addTearDown(host.container.dispose);
      host.container.read(framingProvider.notifier).setRotation(-1);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final backend = _clientBackend();
      final client = _client(backend);
      addTearDown(client.dispose);
      client.read(clientRuntimeReporterProvider);
      for (final update in _updates(host.sent, 'framingGeometry')) {
        applyHostRuntimeUpdate(
          client,
          _overWire(update),
          networkBackend: backend,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(client.read(framingProvider).rotation, -1.0);
      expect(_reported(backend, 'framingGeometry'), isEmpty);
    });
  });

  group('manual loop', () {
    test(
      'the host loop reaches the client, and a client cannot report one',
      () {
        final host = _host();
        addTearDown(host.container.dispose);
        host.container.read(manualLoopStatusProvider.notifier).state =
            const ManualLoopStatus(looping: true, frames: 3);

        final backend = _clientBackend();
        final client = _client(backend);
        addTearDown(client.dispose);
        for (final update in _updates(host.sent, 'manualLoop')) {
          applyHostRuntimeUpdate(
            client,
            _overWire(update),
            networkBackend: backend,
          );
        }
        expect(
          client.read(manualLoopStatusProvider),
          const ManualLoopStatus(looping: true, frames: 3),
        );
        expect(
          applyClientRuntimeReport(
            host.container,
            channel: 'manualLoop',
            value: const {'looping': false},
            origin: 'client',
          ),
          isFalse,
        );
      },
    );

    test('a loop request carries the client operator settings', () {
      const settings = ExposureSettings(
        exposureTime: 7.5,
        gain: 222,
        offset: 30,
        binningX: 2,
        binningY: 2,
        filter: 'G',
        readoutModeIndex: 1,
      );
      final json =
          jsonDecode(
                jsonEncode(
                  manualLoopRequestJson(
                    settings: settings,
                    saveFrames: true,
                    targetName: 'M31',
                  ),
                ),
              )
              as Map<String, dynamic>;
      expect(manualLoopSettingsFromJson(json), settings);
      expect(json['saveFrames'], isTrue);
      expect(json['targetName'], 'M31');
      expect(() => manualLoopSettingsFromJson(const {}), throwsFormatException);
    });
  });

  group('cover/calibrator and switch', () {
    test('the host reading of the cover replaces the one a client fetched '
        'when its card opened', () async {
      final host = _host();
      addTearDown(host.container.dispose);
      const open = CoverCalibratorCapabilitySnapshot(
        coverPresent: true,
        calibratorPresent: true,
        maxBrightness: 255,
        coverStatus: CoverStatus.open,
        calibratorStatus: CalibratorStatus.ready,
        brightness: 100,
      );
      host.container.read(liveCoverCalibratorSnapshotsProvider.notifier).state =
          {'cover-1': open};

      final backend = _clientBackend();
      var fetches = 0;
      when(() => backend.getCoverStatus('cover-1')).thenAnswer((_) async {
        fetches++;
        return {
          'hasCover': true,
          'hasCalibrator': true,
          'coverState': 'closed',
          'calibratorState': 'off',
          'maxBrightness': 255,
        };
      });
      final client = _client(backend);
      addTearDown(client.dispose);
      final sub = client.listen(
        equipmentCoverCalibratorCapabilitiesProvider('cover-1'),
        (_, __) {},
      );
      addTearDown(sub.close);
      expect(
        (await client.read(
          equipmentCoverCalibratorCapabilitiesProvider('cover-1').future,
        ))?.coverStatus,
        CoverStatus.closed,
      );

      for (final update in _updates(host.sent, 'coverCalibrator')) {
        applyHostRuntimeUpdate(
          client,
          _overWire(update),
          networkBackend: backend,
        );
      }
      final now = await client.read(
        equipmentCoverCalibratorCapabilitiesProvider('cover-1').future,
      );
      expect(now, open);
      expect(fetches, 1);
    });

    test(
      'host switch channels reach a client showing the same switch only',
      () {
        final host = _host();
        addTearDown(host.container.dispose);
        final hostSwitch = host.container.read(switchStateProvider.notifier);
        hostSwitch.setConnecting('sw-1', 'Power box');
        hostSwitch.setConnected();
        hostSwitch.setChannels(
          count: 2,
          names: const ['Port 1', 'Dew'],
          states: const [false, true],
          isBoolean: const [true, false],
          values: const [0, 40],
          minValues: const [0, 0],
          maxValues: const [1, 100],
          steps: const [1, 1],
          canWrite: const [true, true],
          descriptions: const ['', ''],
        );
        final updates = _updates(host.sent, 'switchChannels');
        expect(updates.last.value?['states'], [false, true]);

        final backend = _clientBackend();
        final other = _client(backend);
        addTearDown(other.dispose);
        other.read(switchStateProvider.notifier).setConnecting('sw-2');
        applyHostRuntimeUpdate(
          other,
          _overWire(updates.last),
          networkBackend: backend,
        );
        expect(other.read(switchStateProvider).channelCount, 0);

        final client = _client(backend);
        addTearDown(client.dispose);
        client.read(switchStateProvider.notifier)
          ..setConnecting('sw-1')
          ..setConnected();
        applyHostRuntimeUpdate(
          client,
          _overWire(updates.last),
          networkBackend: backend,
        );
        final mirrored = client.read(switchStateProvider);
        expect(mirrored.channelNames, ['Port 1', 'Dew']);
        expect(mirrored.channelStates, [false, true]);
        expect(mirrored.channelValues, [0.0, 40.0]);
        expect(mirrored.channelIsBoolean, [true, false]);
      },
    );
  });

  group('the host follows exposures it did not start', () {
    SkotiqEvent imaging(String type, Map<String, dynamic> data) => SkotiqEvent(
      timestamp: 0,
      category: EventCategory.imaging,
      eventType: type,
      severity: EventSeverity.info,
      data: data,
    );

    test(
      'a client snapshot shows Exposing and a countdown on the host',
      () async {
        final host = _host();
        addTearDown(host.container.dispose);
        applyHostLocalSyncEvent(host.container, imaging('ExposureStarted', {'duration_secs': 8.0, 'frame_type': 'light'}));
        expect(host.container.read(cameraStateProvider).isExposing, isTrue);
        expect(host.container.read(exposureProgressProvider).remaining, 8.0);

        applyHostLocalSyncEvent(host.container, imaging('ExposureProgress', {'progress': 0.5, 'remainingSecs': 4.0}));
        expect(host.container.read(exposureProgressProvider).remaining, 4.0);

        applyHostLocalSyncEvent(host.container, imaging('ExposureComplete', const {}));
        expect(host.container.read(cameraStateProvider).isExposing, isFalse);
        expect(
          host.container.read(exposureProgressProvider),
          ExposureProgress.idle(),
        );
      },
    );

    test("the host's own capture keeps control of its countdown", () async {
      final host = _host();
      addTearDown(host.container.dispose);
      // The host's capture marks the camera exposing before it starts.
      host.container.read(cameraStateProvider.notifier).setExposing(true);
      host.container
          .read(exposureProgressProvider.notifier)
          .startExposure(30, 4, null);

      applyHostLocalSyncEvent(host.container, imaging('ExposureStarted', {'duration_secs': 1.0, 'frame_type': 'light'}));
      applyHostLocalSyncEvent(host.container, imaging('ExposureComplete', const {}));

      expect(host.container.read(cameraStateProvider).isExposing, isTrue);
      expect(host.container.read(exposureProgressProvider).remaining, 30.0);
    });
  });
}
