import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:mocktail/mocktail.dart';

import 'package:nightshade_core/nightshade_core.dart';
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

/// hydrateRemoteSessionState invalidates the host-mirrored planner/scheduler
/// data providers on connect (projects, integration goals, target constraints,
/// scheduler preview, sequence runs, observing lists) so the slave shows the
/// host's rows immediately. In NetworkBackend mode those providers re-fetch via
/// these endpoints, so a mock must answer them or the (eager) StreamProvider
/// rebuild throws a null-future and aborts hydration before PHD2/device state
/// is asserted. These stubs are intentionally empty payloads — the test only
/// cares that hydration completes, not what the planner data contains.
void _stubHydrationParityEndpoints(_MockNetworkBackend backend) {
  when(() => backend.getIntegrationGoals()).thenAnswer((_) async => const []);
  when(
    () => backend.getIntegrationGoals(targetId: any(named: 'targetId')),
  ).thenAnswer((_) async => const []);
  when(() => backend.getTargetConstraints()).thenAnswer((_) async => const []);
  when(
    () => backend.getTargetConstraints(targetId: any(named: 'targetId')),
  ).thenAnswer((_) async => const []);
  when(() => backend.getProjects()).thenAnswer((_) async => const []);
  when(() => backend.getObservingLists()).thenAnswer((_) async => const []);
  when(
    () => backend.getListedCatalogIds(listId: any(named: 'listId')),
  ).thenAnswer((_) async => const <String>{});
  when(() => backend.getListedCatalogIds()).thenAnswer((_) async => const {});
  when(() => backend.getSchedulerPreview()).thenAnswer(
    (_) async => SchedulerDecision(
      score: 0,
      reasoning: const [],
      scoredCandidates: const [],
      evaluatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    ),
  );
  when(() => backend.getProfiles()).thenAnswer((_) async => const []);
  when(() => backend.getActiveProfile()).thenAnswer((_) async => null);
  when(
    () => backend.fetchSequenceRuns(
      sequenceId: any(named: 'sequenceId'),
      limit: any(named: 'limit'),
      offset: any(named: 'offset'),
    ),
  ).thenAnswer(
    (_) async => const RemotePage<RemoteSequenceRun>(items: [], total: 0),
  );
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, NightshadeBackend backend) : super() {
    state = backend;
  }

  void switchTo(NightshadeBackend backend) {
    state = backend;
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<NightshadeEvent>.empty());
  });

  group('remoteSessionSyncProvider', () {
    test(
      'late hydration from an old host cannot overwrite the new host',
      () async {
        final hostA = _MockNetworkBackend();
        final hostB = _MockNetworkBackend();
        final delayedStatus = Completer<SequencerStatus>();
        when(hostA.sequencerGetStatus).thenAnswer((_) => delayedStatus.future);
        when(
          () => hostA.eventStream,
        ).thenAnswer((_) => const Stream<NightshadeEvent>.empty());
        when(
          () => hostA.connectionState,
        ).thenReturn(BackendConnectionState.connected);

        when(hostB.sequencerGetStatus).thenAnswer(
          (_) async => const SequencerStatus(state: 'Idle', progress: 0),
        );
        when(hostB.getConnectedDevices).thenAnswer(
          (_) async => const [
            DeviceInfo(
              id: 'host-b-mount',
              name: 'Host B Mount',
              deviceType: DeviceType.mount,
              driverType: DriverType.simulator,
              description: '',
              driverVersion: '1',
            ),
          ],
        );
        when(() => hostB.getMountStatus('host-b-mount')).thenAnswer(
          (_) async => const MountStatus(
            connected: true,
            tracking: true,
            slewing: false,
            parked: false,
            atHome: false,
            sideOfPier: PierSide.east,
            rightAscension: 7,
            declination: 8,
            altitude: 45,
            azimuth: 180,
            siderealTime: 10,
            trackingRate: TrackingRate.sidereal,
            canPark: true,
            canSlew: true,
            canSync: true,
            canPulseGuide: true,
            canSetTrackingRate: true,
          ),
        );
        when(hostB.getOpenEditorSequence).thenAnswer((_) async => null);
        when(hostB.phd2GetStatus).thenAnswer(
          (_) async => const Phd2Status(
            state: 'Stopped',
            connected: false,
            rmsRa: 0,
            rmsDec: 0,
            rmsTotal: 0,
            snr: 0,
            starMass: 0,
            avgDistance: 0,
          ),
        );
        when(
          () => hostB.eventStream,
        ).thenAnswer((_) => const Stream<NightshadeEvent>.empty());
        when(
          () => hostB.connectionState,
        ).thenReturn(BackendConnectionState.connected);
        _stubHydrationParityEndpoints(hostB);

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, hostA),
            ),
            loggingServiceProvider.overrideWithValue(LoggingService()),
          ],
        );
        addTearDown(container.dispose);
        container.read(remoteSessionSyncProvider);
        await pumpEventQueue();
        verify(hostA.sequencerGetStatus).called(1);

        final notifier =
            container.read(backendProvider.notifier) as _FixedBackendNotifier;
        notifier.switchTo(hostB);
        await pumpEventQueue(times: 20);
        delayedStatus.complete(
          const SequencerStatus(state: 'Running', progress: 0.5),
        );
        await pumpEventQueue(times: 20);

        final mount = container.read(mountStateProvider);
        expect(mount.deviceId, 'host-b-mount');
        expect(mount.ra, 7);
        expect(
          container.read(sequenceExecutionStateProvider),
          isNot(SequenceExecutionState.running),
        );
        verifyNever(hostA.getConnectedDevices);
      },
    );

    test('hydrates mount state from host connected devices', () async {
      final backend = _MockNetworkBackend();

      when(() => backend.sequencerGetStatus()).thenAnswer(
        (_) async => const SequencerStatus(state: 'Idle', progress: 0),
      );

      when(() => backend.getConnectedDevices()).thenAnswer(
        (_) async => const [
          DeviceInfo(
            id: 'ascom:mount:0',

            name: 'Host Mount',

            deviceType: DeviceType.mount,

            driverType: DriverType.ascom,

            description: '',

            driverVersion: '1.0',
          ),
        ],
      );

      when(() => backend.phd2GetStatus()).thenAnswer(
        (_) async => const Phd2Status(
          state: 'Stopped',

          connected: false,

          rmsRa: 0,

          rmsDec: 0,

          rmsTotal: 0,

          snr: 0,

          starMass: 0,

          avgDistance: 0,
        ),
      );

      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<NightshadeEvent>.empty());
      when(
        () => backend.connectionState,
      ).thenReturn(BackendConnectionState.connected);

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),

          loggingServiceProvider.overrideWithValue(LoggingService()),
        ],
      );

      addTearDown(container.dispose);

      container.read(remoteSessionSyncProvider);

      await pumpEventQueue();

      final mount = container.read(mountStateProvider);

      expect(mount.connectionState, DeviceConnectionState.connected);

      expect(mount.deviceId, 'ascom:mount:0');

      expect(mount.deviceName, 'Host Mount');
    });

    test('hydrates PHD2 guider when host reports connected', () async {
      final backend = _MockNetworkBackend();

      when(() => backend.sequencerGetStatus()).thenAnswer(
        (_) async => const SequencerStatus(state: 'Idle', progress: 0),
      );

      when(
        () => backend.getConnectedDevices(),
      ).thenAnswer((_) async => const []);

      when(() => backend.phd2GetStatus()).thenAnswer(
        (_) async => const Phd2Status(
          state: 'Guiding',

          connected: true,

          rmsRa: 0.5,

          rmsDec: 0.4,

          rmsTotal: 0.6,

          snr: 100,

          starMass: 500,

          avgDistance: 0,
        ),
      );

      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<NightshadeEvent>.empty());
      when(
        () => backend.connectionState,
      ).thenReturn(BackendConnectionState.connected);

      _stubHydrationParityEndpoints(backend);

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),

          loggingServiceProvider.overrideWithValue(LoggingService()),
        ],
      );

      addTearDown(container.dispose);

      container.read(remoteSessionSyncProvider);

      await pumpEventQueue();

      final guider = container.read(guiderStateProvider);

      expect(guider.connectionState, DeviceConnectionState.connected);

      expect(guider.deviceId, 'phd2_guider');
    });

    test('hydrates focuser capability flags from host status', () async {
      final backend = _MockNetworkBackend();

      when(() => backend.sequencerGetStatus()).thenAnswer(
        (_) async => const SequencerStatus(state: 'Idle', progress: 0),
      );
      when(() => backend.getConnectedDevices()).thenAnswer(
        (_) async => const [
          DeviceInfo(
            id: 'native:zwo_eaf',
            name: 'ZWO EAF',
            deviceType: DeviceType.focuser,
            driverType: DriverType.native,
            description: '',
            driverVersion: '1.0',
          ),
        ],
      );
      when(() => backend.getFocuserStatus('native:zwo_eaf')).thenAnswer(
        (_) async => const FocuserStatus(
          connected: true,
          position: 12000,
          moving: false,
          temperature: 12.5,
          maxPosition: 31000,
          stepSize: 1.0,
          isAbsolute: true,
          hasTemperature: true,
        ),
      );
      when(() => backend.getOpenEditorSequence()).thenAnswer((_) async => null);
      when(() => backend.phd2GetStatus()).thenAnswer(
        (_) async => const Phd2Status(
          state: 'Stopped',
          connected: false,
          rmsRa: 0,
          rmsDec: 0,
          rmsTotal: 0,
          snr: 0,
          starMass: 0,
          avgDistance: 0,
        ),
      );
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<NightshadeEvent>.empty());
      when(
        () => backend.connectionState,
      ).thenReturn(BackendConnectionState.connected);
      _stubHydrationParityEndpoints(backend);

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          loggingServiceProvider.overrideWithValue(LoggingService()),
        ],
      );
      addTearDown(container.dispose);

      container.read(remoteSessionSyncProvider);
      await pumpEventQueue();

      final focuser = container.read(focuserStateProvider);
      expect(focuser.connectionState, DeviceConnectionState.connected);
      // The capability flags ride the status payload; without them the slave
      // card claims "absolute positioning is not supported" and disables
      // Go To Position.
      expect(focuser.isAbsolute, isTrue);
      expect(focuser.maxPosition, 31000);
      expect(focuser.stepSize, 1.0);
      expect(focuser.hasTemperature, isTrue);
      expect(focuser.position, 12000);
    });

    // Hydration fetches every device's status in parallel and applies them
    // afterwards. A focuser the host disconnects while its status GET is in
    // flight must stay disconnected: the late status must not resurrect it.
    test(
      'a focuser disconnected during hydration stays disconnected',
      () async {
        final backend = _MockNetworkBackend();
        final events = StreamController<NightshadeEvent>.broadcast();
        addTearDown(events.close);
        final focuserStatus = Completer<FocuserStatus>();

        when(() => backend.sequencerGetStatus()).thenAnswer(
          (_) async => const SequencerStatus(state: 'Idle', progress: 0),
        );
        when(() => backend.getConnectedDevices()).thenAnswer(
          (_) async => const [
            DeviceInfo(
              id: 'native:zwo_eaf',
              name: 'ZWO EAF',
              deviceType: DeviceType.focuser,
              driverType: DriverType.native,
              description: '',
              driverVersion: '1.0',
            ),
          ],
        );
        when(
          () => backend.getFocuserStatus('native:zwo_eaf'),
        ).thenAnswer((_) => focuserStatus.future);
        when(
          () => backend.getOpenEditorSequence(),
        ).thenAnswer((_) async => null);
        when(() => backend.phd2GetStatus()).thenAnswer(
          (_) async => const Phd2Status(
            state: 'Stopped',
            connected: false,
            rmsRa: 0,
            rmsDec: 0,
            rmsTotal: 0,
            snr: 0,
            starMass: 0,
            avgDistance: 0,
          ),
        );
        when(() => backend.eventStream).thenAnswer((_) => events.stream);
        when(
          () => backend.connectionState,
        ).thenReturn(BackendConnectionState.connected);
        _stubHydrationParityEndpoints(backend);

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            loggingServiceProvider.overrideWithValue(LoggingService()),
          ],
        );
        addTearDown(container.dispose);

        container.read(remoteSessionSyncProvider);
        await pumpEventQueue();
        verify(() => backend.getFocuserStatus('native:zwo_eaf')).called(1);

        events.add(
          NightshadeEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.equipment,
            eventType: 'Disconnected',
            data: const {
              'device_type': 'focuser',
              'device_id': 'native:zwo_eaf',
            },
          ),
        );
        await pumpEventQueue();
        expect(
          container.read(focuserStateProvider).connectionState,
          DeviceConnectionState.disconnected,
        );

        focuserStatus.complete(
          const FocuserStatus(
            connected: true,
            position: 12000,
            moving: false,
            maxPosition: 31000,
            stepSize: 1.0,
            isAbsolute: true,
            hasTemperature: false,
          ),
        );
        await pumpEventQueue();

        expect(
          container.read(focuserStateProvider).connectionState,
          DeviceConnectionState.disconnected,
          reason:
              'a status fetched before the disconnect is not evidence the '
              'focuser is connected now',
        );
      },
    );

    test(
      'a filter wheel disconnected during hydration stays disconnected',
      () async {
        final backend = _MockNetworkBackend();
        final events = StreamController<NightshadeEvent>.broadcast();
        addTearDown(events.close);
        final wheelStatus = Completer<FilterWheelStatus>();

        when(() => backend.sequencerGetStatus()).thenAnswer(
          (_) async => const SequencerStatus(state: 'Idle', progress: 0),
        );
        when(() => backend.getConnectedDevices()).thenAnswer(
          (_) async => const [
            DeviceInfo(
              id: 'native:zwo_efw',
              name: 'ZWO EFW',
              deviceType: DeviceType.filterWheel,
              driverType: DriverType.native,
              description: '',
              driverVersion: '1.0',
            ),
          ],
        );
        when(
          () => backend.getFilterWheelStatus('native:zwo_efw'),
        ).thenAnswer((_) => wheelStatus.future);
        when(
          () => backend.getOpenEditorSequence(),
        ).thenAnswer((_) async => null);
        when(() => backend.phd2GetStatus()).thenAnswer(
          (_) async => const Phd2Status(
            state: 'Stopped',
            connected: false,
            rmsRa: 0,
            rmsDec: 0,
            rmsTotal: 0,
            snr: 0,
            starMass: 0,
            avgDistance: 0,
          ),
        );
        when(() => backend.eventStream).thenAnswer((_) => events.stream);
        when(
          () => backend.connectionState,
        ).thenReturn(BackendConnectionState.connected);
        _stubHydrationParityEndpoints(backend);

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            loggingServiceProvider.overrideWithValue(LoggingService()),
          ],
        );
        addTearDown(container.dispose);

        container.read(remoteSessionSyncProvider);
        await pumpEventQueue();
        verify(() => backend.getFilterWheelStatus('native:zwo_efw')).called(1);

        events.add(
          NightshadeEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.equipment,
            eventType: 'Disconnected',
            data: const {
              'device_type': 'filterwheel',
              'device_id': 'native:zwo_efw',
            },
          ),
        );
        await pumpEventQueue();
        expect(
          container.read(filterWheelStateProvider).connectionState,
          DeviceConnectionState.disconnected,
        );

        wheelStatus.complete(
          const FilterWheelStatus(
            connected: true,
            position: 2,
            moving: false,
            filterCount: 3,
            filterNames: ['Ha', 'SII', 'OIII'],
          ),
        );
        await pumpEventQueue();

        expect(
          container.read(filterWheelStateProvider).connectionState,
          DeviceConnectionState.disconnected,
          reason:
              'a status fetched before the disconnect is not evidence the '
              'wheel is connected now',
        );
      },
    );

    // The camera and mount cards take the same late apply. A camera the host
    // disconnected mid-exposure must not come back on the phone as a
    // disconnected card that is still exposing and cooling, and a mount must
    // not keep the tracking state of a session that has ended.
    test(
      'a camera and mount disconnected during hydration keep no stale state',
      () async {
        final backend = _MockNetworkBackend();
        final events = StreamController<NightshadeEvent>.broadcast();
        addTearDown(events.close);
        final cameraStatus = Completer<CameraStatus>();
        final mountStatus = Completer<MountStatus>();

        when(() => backend.sequencerGetStatus()).thenAnswer(
          (_) async => const SequencerStatus(state: 'Idle', progress: 0),
        );
        when(() => backend.getConnectedDevices()).thenAnswer(
          (_) async => const [
            DeviceInfo(
              id: 'native:zwo_asi2600',
              name: 'ZWO ASI2600MM',
              deviceType: DeviceType.camera,
              driverType: DriverType.native,
              description: '',
              driverVersion: '1.0',
            ),
            DeviceInfo(
              id: 'native:am5',
              name: 'ZWO AM5',
              deviceType: DeviceType.mount,
              driverType: DriverType.native,
              description: '',
              driverVersion: '1.0',
            ),
          ],
        );
        when(
          () => backend.getCameraStatus('native:zwo_asi2600'),
        ).thenAnswer((_) => cameraStatus.future);
        when(
          () => backend.getMountStatus('native:am5'),
        ).thenAnswer((_) => mountStatus.future);
        when(
          () => backend.getOpenEditorSequence(),
        ).thenAnswer((_) async => null);
        when(() => backend.phd2GetStatus()).thenAnswer(
          (_) async => const Phd2Status(
            state: 'Stopped',
            connected: false,
            rmsRa: 0,
            rmsDec: 0,
            rmsTotal: 0,
            snr: 0,
            starMass: 0,
            avgDistance: 0,
          ),
        );
        when(() => backend.eventStream).thenAnswer((_) => events.stream);
        when(
          () => backend.connectionState,
        ).thenReturn(BackendConnectionState.connected);
        _stubHydrationParityEndpoints(backend);

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            loggingServiceProvider.overrideWithValue(LoggingService()),
          ],
        );
        addTearDown(container.dispose);

        container.read(remoteSessionSyncProvider);
        await pumpEventQueue();
        verify(() => backend.getCameraStatus('native:zwo_asi2600')).called(1);
        verify(() => backend.getMountStatus('native:am5')).called(1);

        for (final (type, id) in [
          ('camera', 'native:zwo_asi2600'),
          ('mount', 'native:am5'),
        ]) {
          events.add(
            NightshadeEvent(
              timestamp: DateTime.now().millisecondsSinceEpoch,
              severity: EventSeverity.info,
              category: EventCategory.equipment,
              eventType: 'Disconnected',
              data: {'device_type': type, 'device_id': id},
            ),
          );
        }
        await pumpEventQueue();
        expect(
          container.read(cameraStateProvider).connectionState,
          DeviceConnectionState.disconnected,
        );
        expect(
          container.read(mountStateProvider).connectionState,
          DeviceConnectionState.disconnected,
        );

        cameraStatus.complete(
          const CameraStatus(
            connected: true,
            state: CameraState.exposing,
            sensorTemp: -10,
            coolerPower: 40,
            targetTemp: -10,
            coolerOn: true,
            gain: 100,
            offset: 50,
            binX: 1,
            binY: 1,
            sensorWidth: 6248,
            sensorHeight: 4176,
            pixelSizeX: 3.76,
            pixelSizeY: 3.76,
            maxAdu: 65535,
            canCool: true,
            canSetGain: true,
            canSetOffset: true,
          ),
        );
        mountStatus.complete(
          const MountStatus(
            connected: true,
            rightAscension: 0.71,
            declination: 41.27,
            altitude: 60,
            azimuth: 45,
            tracking: true,
            slewing: false,
            parked: false,
            atHome: false,
            sideOfPier: PierSide.east,
            trackingRate: TrackingRate.sidereal,
            canPark: true,
            canSlew: true,
            canSync: true,
            canPulseGuide: true,
            canSetTrackingRate: true,
          ),
        );
        await pumpEventQueue();

        final camera = container.read(cameraStateProvider);
        expect(
          camera.isExposing,
          isFalse,
          reason: 'a disconnected camera card claimed an exposure in progress',
        );
        expect(
          camera.isCooling,
          isFalse,
          reason: 'a disconnected camera card claimed its cooler was on',
        );
        expect(
          container.read(mountStateProvider).isTracking,
          isFalse,
          reason: 'a disconnected mount card claimed it was tracking',
        );
      },
    );

    // While the host's sequence runs, the slave's mirrored
    // sequenceExecutionState locks the editor — the open-editor mirror apply
    // must SKIP rather than throw SequenceLockedException out of hydration
    // (which used to abort PHD2 / profile / settings refreshes every 30 s).
    test(
      'editor mirror skips while a sequence runs; hydration continues',
      () async {
        final backend = _MockNetworkBackend();
        when(() => backend.sequencerGetStatus()).thenAnswer(
          (_) async => const SequencerStatus(state: 'Running', progress: 0.4),
        );
        when(
          () => backend.getConnectedDevices(),
        ).thenAnswer((_) async => const []);
        when(() => backend.getOpenEditorSequence()).thenAnswer(
          (_) async => const {
            'sequence': <String, dynamic>{'name': 'Host Seq', 'nodes': {}},
            'isDirty': false,
          },
        );
        when(() => backend.phd2GetStatus()).thenAnswer(
          (_) async => const Phd2Status(
            state: 'Guiding',
            connected: true,
            rmsRa: 0.5,
            rmsDec: 0.4,
            rmsTotal: 0.6,
            snr: 100,
            starMass: 500,
            avgDistance: 0,
          ),
        );
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<NightshadeEvent>.empty());
        when(
          () => backend.connectionState,
        ).thenReturn(BackendConnectionState.connected);
        _stubHydrationParityEndpoints(backend);

        final localSequence = Sequence.create(name: 'Local Seq');
        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            loggingServiceProvider.overrideWithValue(LoggingService()),
            currentSequenceProvider.overrideWith((ref) {
              final notifier = CurrentSequenceNotifier(ref: ref);
              // ignore: invalid_use_of_protected_member
              notifier.state = localSequence;
              return notifier;
            }),
          ],
        );
        addTearDown(container.dispose);

        container.read(remoteSessionSyncProvider);
        await pumpEventQueue();

        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.running,
        );
        // The host's editor canvas must NOT clobber the slave's while a run
        // owns the tree.
        expect(container.read(currentSequenceProvider)?.name, 'Local Seq');
        // Hydration continued past the editor step: PHD2 was still fetched
        // and applied.
        verify(() => backend.phd2GetStatus()).called(greaterThan(0));
        expect(
          container.read(guiderStateProvider).connectionState,
          DeviceConnectionState.connected,
        );
      },
    );

    // A dead token used to drive an endless hydration loop: the 30 s
    // pollTimer + every BackendReconnected event fanned out requests that
    // could only 403, each one feeding the server's auth-failure limiter
    // into a rolling 429. Terminal backend state must suppress hydration
    // entirely until an explicit reconnect clears it.
    test('no hydration fan-out while backend is in terminal error', () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<NightshadeEvent>.empty());
      when(
        () => backend.connectionState,
      ).thenReturn(BackendConnectionState.error);
      // Deliberately no hydration stubs: ANY fan-out call would hit an
      // unstubbed method — the verifyNevers below prove none was made.

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          loggingServiceProvider.overrideWithValue(LoggingService()),
        ],
      );
      addTearDown(container.dispose);

      container.read(remoteSessionSyncProvider);
      await pumpEventQueue(times: 10);

      verifyNever(() => backend.sequencerGetStatus());
      verifyNever(() => backend.getConnectedDevices());
      verifyNever(() => backend.phd2GetStatus());
    });
  });
}
