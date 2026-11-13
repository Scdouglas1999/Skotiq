import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../services/imaging_service_test.dart' show makeCapturedImageResult;
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

/// A mock host that is connected, with live credentials.
///
/// The sync provider reads `connectionState` before every hydration fan-out so
/// a host in a terminal auth state stays quiet instead of feeding the server's
/// auth-failure limiter. Both that getter and `isAuthTokenRejected` are
/// non-nullable, and mocktail raises a TypeError rather than returning null for
/// an unstubbed non-nullable getter — so a bare mock throws before a test
/// reaches its own assertions. A test that wants the terminal path re-stubs
/// `connectionState` itself.
_MockNetworkBackend _connectedBackend() {
  final backend = _MockNetworkBackend();
  when(
    () => backend.connectionState,
  ).thenReturn(BackendConnectionState.connected);
  when(() => backend.isAuthTokenRejected).thenReturn(false);
  return backend;
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
  });

  group('applyRemoteSyncEvent', () {
    // A linked client's Disconnect all let go of the guide camera first; the
    // host's notice of that emptied the client's camera slot, so the client
    // never asked for the imaging camera and the host kept it connected.
    test('the host letting go of the guide camera leaves the imaging camera '
        'in its slot', () async {
      final backend = _connectedBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          activeEquipmentProfileProvider.overrideWithValue(
            const EquipmentProfileModel(
              id: 1,
              name: 'Sim Rig',
              cameraId: 'sim_camera_1',
              guideCameraId: 'sim_camera_2',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(cameraStateProvider.notifier)
        ..setConnecting('sim_camera_1', 'Simulated Camera')
        ..setConnected();

      SkotiqEvent hostSays(String action, String deviceId) => SkotiqEvent(
        timestamp: 1,
        severity: EventSeverity.info,
        category: EventCategory.system,
        eventType: hostStateChangedEventType,
        data: {
          'entityType': HostMutationEntity.equipment,
          'action': action,
          'entityId': deviceId,
          'deviceType': 'camera',
          'deviceId': deviceId,
        },
      );

      await applyRemoteSyncEvent(
        container,
        hostSays(HostMutationAction.disconnected, 'sim_camera_2'),
      );
      expect(container.read(cameraStateProvider).deviceId, 'sim_camera_1');
      expect(
        container.read(cameraStateProvider).connectionState,
        DeviceConnectionState.connected,
      );

      // Another camera's disconnect, guide camera or not, is not this one's.
      await applyRemoteSyncEvent(
        container,
        hostSays(HostMutationAction.disconnected, 'sim_camera_9'),
      );
      expect(container.read(cameraStateProvider).deviceId, 'sim_camera_1');

      await applyRemoteSyncEvent(
        container,
        hostSays(HostMutationAction.connected, 'sim_camera_2'),
      );
      expect(container.read(cameraStateProvider).deviceId, 'sim_camera_1');

      await applyRemoteSyncEvent(
        container,
        hostSays(HostMutationAction.disconnected, 'sim_camera_1'),
      );
      expect(
        container.read(cameraStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });

    test('a slot showing a failed connect keeps showing it through the '
        'host\'s Disconnected', () async {
      final backend = _connectedBackend();
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
      addTearDown(container.dispose);
      container.read(focuserStateProvider.notifier)
        ..setConnecting('sim_focuser_1', 'Simulated Focuser')
        ..connectFailed(StateError('unplugged'));

      await applyRemoteSyncEvent(
        container,
        const SkotiqEvent(
          timestamp: 1,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'Disconnected',
          data: {'device_type': 'focuser', 'device_id': 'sim_focuser_1'},
        ),
      );

      final slot = container.read(focuserStateProvider);
      expect(slot.connectionState, DeviceConnectionState.error);
      expect(slot.retryDeviceId, 'sim_focuser_1');
    });

    // The host's refusal can reach a client ahead of the host's own
    // announcement of the connect. The late Connecting then put the failed
    // slot back to connecting, where nothing ever ended it, and the next
    // re-read of the host removed the card.
    test('a host Connecting that arrives behind the refusal of this '
        'client\'s connect leaves the slot failed', () async {
      final backend = _connectedBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(
        () => backend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
      when(
        () => backend.getConnectedDevices(),
      ).thenAnswer((_) async => const []);
      when(
        () => backend.connectDevice(DeviceType.focuser, 'sim_focuser_1'),
      ).thenThrow(StateError('unplugged'));
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(deviceServiceProvider)
            .connect(DeviceType.focuser, 'sim_focuser_1'),
        throwsA(isA<StateError>()),
      );
      await applyRemoteSyncEvent(
        container,
        const SkotiqEvent(
          timestamp: 1,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'Connecting',
          data: {
            'device_type': 'focuser',
            'device_id': 'sim_focuser_1',
            'device_name': 'Simulated Focuser',
          },
        ),
      );

      final slot = container.read(focuserStateProvider);
      expect(slot.connectionState, DeviceConnectionState.error);
      expect(slot.retryDeviceId, 'sim_focuser_1');
    });

    test('a device connected through the server shows on the host window', () async {
      final backend = _connectedBackend();
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
      addTearDown(container.dispose);

      await applyRemoteSyncEvent(
        container,
        const SkotiqEvent(
          timestamp: 1,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'Connected',
          data: {'device_type': 'mount', 'device_id': 'ascom:mount:0'},
        ),
      );

      final mount = container.read(mountStateProvider);
      expect(mount.connectionState, DeviceConnectionState.connected);
      expect(mount.deviceId, 'ascom:mount:0');
    });

    test('HostStateChanged profile mutation invalidates profiles', () async {
      final backend = _connectedBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());

      var loadCount = 0;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          equipmentProfilesProvider.overrideWith(() {
            return _TestProfilesNotifier(onLoad: () => loadCount++);
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(equipmentProfilesProvider.future);

      await applyRemoteSyncEvent(
        container,
        buildHostMutationEvent(
          entityType: HostMutationEntity.profile,
          action: HostMutationAction.updated,
          entityId: '1',
        ),
      );

      await container.read(equipmentProfilesProvider.future);
      expect(loadCount, greaterThanOrEqualTo(2));
    });

    test(
      'HostStateChanged target mutation invalidates target catalog',
      () async {
        final backend = _connectedBackend();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(() => backend.getAllTargets()).thenAnswer((_) async => []);

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(allDbTargetsProvider.future);

        await applyRemoteSyncEvent(
          container,
          buildHostMutationEvent(
            entityType: HostMutationEntity.target,
            action: HostMutationAction.updated,
            entityId: '3',
          ),
        );

        await container.read(allDbTargetsProvider.future);
        verify(() => backend.getAllTargets()).called(greaterThanOrEqualTo(2));
      },
    );

    test('ImageCaptured invalidates target progress providers', () async {
      final backend = _connectedBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());

      var progressReads = 0;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          allTargetProgressProvider.overrideWith((ref) async {
            progressReads++;
            return {};
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(allTargetProgressProvider.future);
      final readsBefore = progressReads;

      await applyRemoteSyncEvent(
        container,
        const SkotiqEvent(
          timestamp: 4,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'ImageCaptured',
          data: {'targetId': 1},
        ),
      );

      await container.read(allTargetProgressProvider.future);
      expect(progressReads, greaterThan(readsBefore));
    });

    test('ImageReady on remote populates currentImageProvider', () async {
      final backend = _connectedBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(() => backend.cameraGetLastImage('asi:0', maxWidth: any(named: 'maxWidth'))).thenAnswer(
        (_) async => makeCapturedImageResult(
          width: 4,
          height: 2,
          exposureTime: 12.0,
          timestamp: '2026-06-02T03:00:00Z',
        ),
      );
      // Publisher schedules a background raw-pixel load on NetworkBackend;
      // stub it so the coalesced fetch completes cleanly.
      when(
        () => backend.getLastRawImageData('asi:0'),
      ).thenAnswer((_) async => List<int>.filled(4 * 2 * 2, 0));

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      // The frame fetch resolves the camera device id from local equipment
      // state (mirrored from the host); simulate a connected camera.
      container.read(cameraStateProvider.notifier)
        ..setConnecting('asi:0', 'ASI Camera')
        ..setConnected();

      expect(container.read(currentImageProvider), isNull);

      await applyRemoteSyncEvent(
        container,
        const SkotiqEvent(
          timestamp: 5,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'ImageReady',
          data: {'width': 4, 'height': 2},
        ),
        networkBackend: backend,
      );

      // Let the unawaited fetch + publish microtasks run.
      await pumpEventQueue();

      final frame = container.read(currentImageProvider);
      expect(frame, isNotNull);
      expect(frame!.width, 4);
      expect(frame.height, 2);
      expect(frame.settings.exposureTime, 12.0);
      expect(frame.previewSource, CapturePreviewSource.remote);
      verify(() => backend.cameraGetLastImage('asi:0', maxWidth: any(named: 'maxWidth'))).called(1);
    });

    test('late current-frame response from an old host is discarded', () async {
      final hostA = _connectedBackend();
      final hostB = _connectedBackend();
      final delayedFrame = Completer<CapturedImageResult?>();
      when(
        () => hostA.cameraGetLastImage('asi:0', maxWidth: any(named: 'maxWidth')),
      ).thenAnswer((_) => delayedFrame.future);

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, hostA),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(cameraStateProvider.notifier)
        ..setConnecting('asi:0', 'ASI Camera')
        ..setConnected();

      await applyRemoteSyncEvent(
        container,
        const SkotiqEvent(
          timestamp: 6,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'ImageReady',
          data: {'width': 4, 'height': 2},
        ),
        networkBackend: hostA,
      );
      await pumpEventQueue();
      verify(() => hostA.cameraGetLastImage('asi:0', maxWidth: any(named: 'maxWidth'))).called(1);

      final notifier =
          container.read(backendProvider.notifier) as _FixedBackendNotifier;
      notifier.switchTo(hostB);
      delayedFrame.complete(
        makeCapturedImageResult(
          width: 4,
          height: 2,
          exposureTime: 12,
          timestamp: '2026-06-02T03:00:00Z',
        ),
      );
      await pumpEventQueue(times: 20);

      expect(container.read(currentImageProvider), isNull);
      verifyNever(() => hostB.cameraGetLastImage(any(), maxWidth: any(named: 'maxWidth')));
    });

    test(
      'ImageReady without networkBackend leaves currentImageProvider blank',
      () async {
        final backend = _connectedBackend();
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
        addTearDown(container.dispose);

        container.read(cameraStateProvider.notifier)
          ..setConnecting('asi:0', 'ASI Camera')
          ..setConnected();

        // No networkBackend passed → desktop/host-local path: the host-local
        // publisher owns currentImageProvider, so the remote fetch must NOT run.
        await applyRemoteSyncEvent(
          container,
          const SkotiqEvent(
            timestamp: 6,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: 'ImageReady',
            data: {'width': 4, 'height': 2},
          ),
        );
        await pumpEventQueue();

        expect(container.read(currentImageProvider), isNull);
        verifyNever(() => backend.cameraGetLastImage(any(), maxWidth: any(named: 'maxWidth')));
      },
    );

    test(
      'SequenceUpdated over WS invalidates savedSequencesProvider',
      () async {
        final backend = _connectedBackend();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(() => backend.listFullSequences()).thenAnswer((_) async => []);

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
          ],
        );
        addTearDown(container.dispose);

        container.listen(savedSequencesProvider, (_, __) {});
        await container.read(savedSequencesProvider.future);

        await applyRemoteSyncEvent(
          container,
          SkotiqEvent.fromWireJson({
            'type': 'event',
            'timestamp': 2,
            'severity': 'info',
            'category': 'sequencer',
            'eventType': sequenceUpdatedEventType,
            'data': {'sequenceId': 4, 'action': 'saved'},
          }),
        );

        await container.read(savedSequencesProvider.future);
        verify(
          () => backend.listFullSequences(),
        ).called(greaterThanOrEqualTo(2));
      },
    );

    test('HostStateChanged sequence mutation invalidates library', () async {
      final backend = _connectedBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(() => backend.listFullSequences()).thenAnswer((_) async => []);

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(savedSequencesProvider.future);

      await applyRemoteSyncEvent(
        container,
        SkotiqEvent.fromWireJson({
          'type': 'event',
          'timestamp': 3,
          'severity': 'info',
          'category': 'system',
          'eventType': hostStateChangedEventType,
          'data': {
            'entityType': HostMutationEntity.sequence,
            'action': HostMutationAction.updated,
            'entityId': '9',
          },
        }),
      );

      await container.read(savedSequencesProvider.future);
      verify(() => backend.listFullSequences()).called(greaterThanOrEqualTo(2));
    });

    test('remoteSessionSyncProvider shows a device the host connects while '
        'linked', () async {
      final eventController = StreamController<SkotiqEvent>.broadcast();
      final backend = _connectedBackend();
      when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
      when(() => backend.sequencerGetStatus()).thenAnswer(
        (_) async => const SequencerStatus(state: 'Idle', progress: 0),
      );
      when(
        () => backend.getHostRuntimeState(),
      ).thenAnswer((_) async => const []);

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          loggingServiceProvider.overrideWithValue(LoggingService()),
        ],
      );
      addTearDown(() async {
        await eventController.close();
        container.dispose();
      });

      container.read(remoteSessionSyncProvider);
      await pumpEventQueue();

      // The native event says a camera connected; the host's device channel
      // says which one the camera slot holds.
      eventController.add(
        const SkotiqEvent(
          timestamp: 2,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'Connected',
          data: {'device_type': 'camera', 'device_id': 'guide:0'},
        ),
      );
      eventController.add(
        const HostRuntimeUpdate(
          channel: 'device.camera',
          revision: 7,
          value: {
            'state': 'connected',
            'deviceId': 'asi:0',
            'deviceName': 'ASI',
            'readings': {'temperature': -10.0},
          },
        ).toEvent(),
      );
      await pumpEventQueue();

      final camera = container.read(cameraStateProvider);
      expect(camera.connectionState, DeviceConnectionState.connected);
      expect(camera.deviceId, 'asi:0');
      expect(camera.temperature, -10.0);
      expect(camera.coolerPower, isNull);
    });
  });
}

class _TestProfilesNotifier extends EquipmentProfilesNotifier {
  _TestProfilesNotifier({required this.onLoad});

  final void Function() onLoad;

  @override
  Future<EquipmentProfilesState> build() async {
    onLoad();
    return const EquipmentProfilesState(profiles: [], activeProfile: null);
  }
}
