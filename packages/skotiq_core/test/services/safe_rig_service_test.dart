import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../mocks/mock_backend.dart';

/// Pin the backend StateNotifierProvider to a caller-supplied instance.
class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }

  void replaceBackend(SkotiqBackend backend) => state = backend;
}

/// SafeRigService variant that records (and optionally fails) the dome/cover
/// physical-close calls instead of dispatching them to the Rust bridge — the
/// real close goes through `bridge_api`, which has no native lib under test.
/// The decision logic (whether/when to call these) is exactly the production
/// path; only the leaf transport is overridden.
class _RecordingSafeRig extends SafeRigService {
  _RecordingSafeRig(
    super.ref, {
    this.failDome = false,
    Future<bool> Function()? stopSecondaryRig,
  }) : super(stopSecondaryRig: stopSecondaryRig ?? _noopSecondaryRigStop);

  final bool failDome;
  final List<String> domeClosedFor = [];
  final List<String> coverClosedFor = [];

  @override
  Future<void> closeDomeShutter(SkotiqBackend backend, String deviceId) async {
    domeClosedFor.add(deviceId);
    if (failDome) throw Exception('dome stuck');
  }

  @override
  Future<void> closeCalibratorCover(
    SkotiqBackend backend,
    String deviceId,
  ) async {
    coverClosedFor.add(deviceId);
  }
}

/// No secondary rig configured: the stop is a no-op and reports that nothing
/// was running, so the outcome must not claim "secondary rig stopped".
Future<bool> _noopSecondaryRigStop() async => false;

void main() {
  setUpAll(registerMocktailFallbackValues);

  group('SafeRigService.safeTheRig', () {
    late MockBackend backend;

    setUp(() {
      backend = MockBackend();
      when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
      when(
        () => backend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
      when(() => backend.sequencerPause()).thenAnswer((_) async {});
      when(() => backend.mountPark(any())).thenAnswer((_) async {});
      when(() => backend.cameraAbortExposure(any())).thenAnswer((_) async {});
      when(
        () => backend.cameraSetCooling(
          deviceId: any(named: 'deviceId'),
          enabled: any(named: 'enabled'),
          targetTemp: any(named: 'targetTemp'),
        ),
      ).thenAnswer((_) async {});
      when(() => backend.getCameraStatus(any())).thenAnswer(
        (_) async => CameraStatus.fromJson({
          'connected': true,
          'canCool': true,
          'coolerOn': false,
        }),
      );
    });

    ProviderContainer makeContainer({
      SequenceExecutionState executionState = SequenceExecutionState.running,
      bool mountConnected = true,
      bool mountParked = false,
      bool domeConnected = false,
      ShutterStatus domeShutter = ShutterStatus.open,
      bool coverConnected = false,
      CoverStatus coverStatus = CoverStatus.open,
      bool cameraConnected = false,
      bool cameraExposing = false,
      bool cameraCooling = false,
      double? cameraCoolerPower,
      bool domeCanSetShutter = true,
      SafeRigService Function(Ref)? safeRigBuilder,
      void Function(_TestBackendNotifier notifier)? captureBackendNotifier,
    }) {
      return ProviderContainer(
        overrides: [
          backendProvider.overrideWith((ref) {
            final notifier = _TestBackendNotifier(ref, backend);
            captureBackendNotifier?.call(notifier);
            return notifier;
          }),
          sequenceExecutionStateProvider.overrideWith((ref) => executionState),
          cameraStateProvider.overrideWith((ref) {
            final n = CameraStateNotifier(ref);
            if (cameraConnected) {
              n.setConnecting('simulator:test-camera-1', 'Test Camera');
              n.setConnected();
              n.setExposing(cameraExposing);
              n.setCooling(cameraCooling);
              if (cameraCoolerPower != null) {
                n.updateTemperature(0, cameraCoolerPower);
              }
            }
            return n;
          }),
          mountStateProvider.overrideWith((ref) {
            final n = MountStateNotifier(ref);
            if (mountConnected) {
              n.setConnecting('simulator:test-mount-1');
              n.setConnected();
              n.setParked(mountParked);
              n.setTracking(!mountParked);
            }
            return n;
          }),
          domeStateProvider.overrideWith((ref) {
            final n = DomeStateNotifier(ref);
            if (domeConnected) {
              n.setConnecting('simulator:test-dome-1');
              n.setConnected();
              n.updateShutterStatus(domeShutter);
            }
            return n;
          }),
          coverCalibratorStateProvider.overrideWith((ref) {
            final n = CoverCalibratorStateNotifier(ref);
            if (coverConnected) {
              n.setConnecting('simulator:test-cover-1');
              n.setConnected();
              n.updateCoverStatus(coverStatus);
            }
            return n;
          }),
          domeCapabilityFetcherProvider.overrideWithValue(
            (_) async => DomeCapabilities(canSetShutter: domeCanSetShutter),
          ),
          safeRigServiceProvider.overrideWith((ref) {
            final authority = ref.watch(backendProvider);
            return safeRigBuilder?.call(ref) ??
                SafeRigService(
                  ref,
                  backend: authority,
                  stopSecondaryRig: _noopSecondaryRigStop,
                );
          }),
        ],
      );
    }

    test('pauses sequence and parks an unparked connected mount', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final result = await container
          .read(safeRigServiceProvider)
          .safeTheRig(reason: 'test', park: true);

      verify(() => backend.sequencerPause()).called(1);
      verify(() => backend.mountPark('simulator:test-mount-1')).called(1);
      expect(result.sequencePaused, isTrue);
      expect(result.mountParked, isTrue);
      expect(result.hasFailures, isFalse);
      // Mount notifier state should reflect the park.
      expect(container.read(mountStateProvider).isParked, isTrue);
      expect(container.read(mountStateProvider).isTracking, isFalse);
    });

    test('quiesces the secondary rig before moving the mount', () async {
      final order = <String>[];
      when(() => backend.mountPark(any())).thenAnswer((_) async {
        order.add('park');
      });
      late _RecordingSafeRig recording;
      final container = makeContainer(
        safeRigBuilder: (ref) => recording = _RecordingSafeRig(
          ref,
          stopSecondaryRig: () async {
            order.add('secondary');
            return true;
          },
        ),
      );
      addTearDown(container.dispose);

      final result = await container
          .read(safeRigServiceProvider)
          .safeTheRig(reason: 'unsafe weather', notify: false);

      expect(recording, isNotNull);
      expect(order, ['secondary', 'park']);
      expect(result.secondaryRigQuiesced, isTrue);
    });

    test('host switch aborts safing before commands can cross rigs', () async {
      final secondaryStop = Completer<void>();
      final backendB = MockBackend();
      late _TestBackendNotifier backendNotifier;
      final container = makeContainer(
        captureBackendNotifier: (notifier) => backendNotifier = notifier,
        safeRigBuilder: (ref) => SafeRigService(
          ref,
          stopSecondaryRig: () => secondaryStop.future.then((_) => true),
        ),
      );
      addTearDown(container.dispose);

      final safing = container
          .read(safeRigServiceProvider)
          .safeTheRig(reason: 'unsafe weather', notify: false);
      await Future<void>.delayed(Duration.zero);

      backendNotifier.replaceBackend(backendB);
      secondaryStop.complete();

      await expectLater(
        safing,
        throwsA(
          isA<SafeRigException>().having(
            (error) => error.result.failures,
            'failures',
            contains('authority'),
          ),
        ),
      );
      verifyNever(() => backend.sequencerPause());
      verifyNever(() => backend.mountPark(any()));
      verifyNever(() => backendB.sequencerPause());
      verifyNever(() => backendB.mountPark(any()));
    });

    test('reports secondary stop failure but still parks', () async {
      final container = makeContainer(
        safeRigBuilder: (ref) => _RecordingSafeRig(
          ref,
          stopSecondaryRig: () async {
            throw Exception('secondary camera did not abort');
          },
        ),
      );
      addTearDown(container.dispose);

      try {
        await container
            .read(safeRigServiceProvider)
            .safeTheRig(reason: 'unsafe weather', notify: false);
        fail('expected SafeRigException');
      } on SafeRigException catch (error) {
        expect(error.result.failures, contains('secondaryRig'));
      }
      verify(() => backend.mountPark('simulator:test-mount-1')).called(1);
    });

    test(
      'skips park when mount already parked (recorded as already safe)',
      () async {
        final container = makeContainer(mountParked: true);
        addTearDown(container.dispose);

        final result = await container
            .read(safeRigServiceProvider)
            .safeTheRig(reason: 'test', park: true);

        verify(() => backend.sequencerPause()).called(1);
        verifyNever(() => backend.mountPark(any()));
        expect(result.mountParked, isFalse);
        expect(result.mountAlreadySafe, isTrue);
        expect(result.hasFailures, isFalse);
      },
    );

    test(
      'skips park when no mount connected (recorded as already safe)',
      () async {
        final container = makeContainer(mountConnected: false);
        addTearDown(container.dispose);

        final result = await container
            .read(safeRigServiceProvider)
            .safeTheRig(reason: 'test', park: true);

        verifyNever(() => backend.mountPark(any()));
        expect(result.mountAlreadySafe, isTrue);
        expect(result.hasFailures, isFalse);
      },
    );

    test('does not park when park=false', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final result = await container
          .read(safeRigServiceProvider)
          .safeTheRig(reason: 'test', park: false);

      verify(() => backend.sequencerPause()).called(1);
      verifyNever(() => backend.mountPark(any()));
      expect(result.sequencePaused, isTrue);
      expect(result.mountParked, isFalse);
    });

    test('does not pause when no sequence is running', () async {
      when(
        () => backend.sequencerPause(),
      ).thenThrow(Exception('no sequence running'));
      final container = makeContainer(
        executionState: SequenceExecutionState.idle,
      );
      addTearDown(container.dispose);

      final result = await container
          .read(safeRigServiceProvider)
          .safeTheRig(reason: 'test', park: true);

      verifyNever(() => backend.sequencerPause());
      verify(() => backend.mountPark('simulator:test-mount-1')).called(1);
      expect(result.sequencePaused, isFalse);
      expect(result.mountParked, isTrue);
      expect(result.hasFailures, isFalse);
    });

    test('closes dome and cover when requested and open', () async {
      late _RecordingSafeRig recording;
      final container = makeContainer(
        domeConnected: true,
        domeShutter: ShutterStatus.open,
        coverConnected: true,
        coverStatus: CoverStatus.open,
        safeRigBuilder: (ref) => recording = _RecordingSafeRig(ref),
      );
      addTearDown(container.dispose);

      final result = await container
          .read(safeRigServiceProvider)
          .safeTheRig(
            reason: 'test',
            park: true,
            closeDome: true,
            closeCover: true,
          );

      expect(recording.domeClosedFor, ['simulator:test-dome-1']);
      expect(recording.coverClosedFor, ['simulator:test-cover-1']);
      expect(result.domeClosed, isTrue);
      expect(result.coverClosed, isTrue);
      expect(result.hasFailures, isFalse);
    });

    test('terminal safing aborts exposure and disables cooler', () async {
      final container = makeContainer(
        cameraConnected: true,
        cameraExposing: true,
        cameraCooling: true,
      );
      addTearDown(container.dispose);

      final result = await container
          .read(safeRigServiceProvider)
          .safeTheRig(
            reason: 'daemon shutdown',
            abortExposure: true,
            disableCooling: true,
            notify: false,
          );

      verifyInOrder([
        () => backend.cameraAbortExposure('simulator:test-camera-1'),
        () => backend.sequencerPause(),
        () => backend.mountPark('simulator:test-mount-1'),
        () => backend.cameraSetCooling(
          deviceId: 'simulator:test-camera-1',
          enabled: false,
        ),
      ]);
      expect(result.exposureAborted, isTrue);
      expect(result.coolerDisabled, isTrue);
      expect(container.read(cameraStateProvider).isExposing, isFalse);
      expect(container.read(cameraStateProvider).isCooling, isFalse);
      expect(result.hasFailures, isFalse);
    });

    test(
      'fresh camera status disables a cooler hidden by stale local state',
      () async {
        when(() => backend.getCameraStatus(any())).thenAnswer(
          (_) async => CameraStatus.fromJson({
            'connected': true,
            'canCool': true,
            'coolerOn': true,
            'coolerPower': 42.0,
          }),
        );
        final container = makeContainer(
          executionState: SequenceExecutionState.idle,
          mountConnected: false,
          cameraConnected: true,
          cameraCooling: false,
          cameraCoolerPower: 17,
        );
        addTearDown(container.dispose);

        final result = await container
            .read(safeRigServiceProvider)
            .safeTheRig(
              reason: 'daemon shutdown',
              park: false,
              disableCooling: true,
              notify: false,
            );

        verify(
          () => backend.cameraSetCooling(
            deviceId: 'simulator:test-camera-1',
            enabled: false,
          ),
        ).called(1);
        expect(result.coolerDisabled, isTrue);
        expect(container.read(cameraStateProvider).isCooling, isFalse);
        expect(container.read(cameraStateProvider).isWarming, isFalse);
        expect(container.read(cameraStateProvider).coolerPower, isNull);
      },
    );

    test(
      'fails closed when requested dome shutter control is unsupported',
      () async {
        late _RecordingSafeRig recording;
        final container = makeContainer(
          domeConnected: true,
          domeShutter: ShutterStatus.open,
          domeCanSetShutter: false,
          safeRigBuilder: (ref) => recording = _RecordingSafeRig(ref),
        );
        addTearDown(container.dispose);

        try {
          await container
              .read(safeRigServiceProvider)
              .safeTheRig(
                reason: 'unsafe weather',
                closeDome: true,
                notify: false,
              );
          fail('expected SafeRigException');
        } on SafeRigException catch (error) {
          expect(error.result.failures, contains('dome'));
        }
        expect(recording.domeClosedFor, isEmpty);
        verify(() => backend.mountPark('simulator:test-mount-1')).called(1);
      },
    );

    test('does not re-close an already-closed dome', () async {
      late _RecordingSafeRig recording;
      final container = makeContainer(
        domeConnected: true,
        domeShutter: ShutterStatus.closed,
        safeRigBuilder: (ref) => recording = _RecordingSafeRig(ref),
      );
      addTearDown(container.dispose);

      final result = await container
          .read(safeRigServiceProvider)
          .safeTheRig(reason: 'test', park: true, closeDome: true);

      expect(recording.domeClosedFor, isEmpty);
      expect(result.domeClosed, isFalse);
      expect(result.hasFailures, isFalse);
    });

    test('attempts every step then throws when park fails', () async {
      when(
        () => backend.mountPark(any()),
      ).thenThrow(Exception('park motor fault'));
      late _RecordingSafeRig recording;
      final container = makeContainer(
        domeConnected: true,
        domeShutter: ShutterStatus.open,
        safeRigBuilder: (ref) => recording = _RecordingSafeRig(ref),
      );
      addTearDown(container.dispose);

      await expectLater(
        () => container
            .read(safeRigServiceProvider)
            .safeTheRig(reason: 'test', park: true, closeDome: true),
        throwsA(isA<SafeRigException>()),
      );

      // Pause still happened, and the dome was STILL closed despite the park
      // failure — safing must not short-circuit.
      verify(() => backend.sequencerPause()).called(1);
      expect(recording.domeClosedFor, ['simulator:test-dome-1']);
    });

    test('aggregates multiple failures into the thrown exception', () async {
      when(
        () => backend.sequencerPause(),
      ).thenThrow(Exception('no sequence running'));
      when(() => backend.mountPark(any())).thenThrow(Exception('park fault'));
      final container = makeContainer(
        safeRigBuilder: (ref) => _RecordingSafeRig(ref, failDome: true),
        domeConnected: true,
        domeShutter: ShutterStatus.open,
      );
      addTearDown(container.dispose);

      try {
        await container
            .read(safeRigServiceProvider)
            .safeTheRig(reason: 'test', park: true, closeDome: true);
        fail('expected SafeRigException');
      } on SafeRigException catch (e) {
        expect(
          e.result.failures.keys,
          containsAll(<String>['pause', 'park', 'dome']),
        );
      }
    });

    test('emits a critical (error-level) notification on success', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      await container
          .read(safeRigServiceProvider)
          .safeTheRig(reason: 'Weather turned unsafe', park: true);

      final notes = container.read(uiNotificationProvider);
      expect(notes, isNotEmpty);
      expect(notes.last.level, UiNotificationLevel.error);
      expect(notes.last.message, contains('Weather turned unsafe'));
    });

    test('notify=false suppresses the notification', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      await container
          .read(safeRigServiceProvider)
          .safeTheRig(reason: 'test', park: true, notify: false);

      expect(container.read(uiNotificationProvider), isEmpty);
    });

    // Audit 2026-07-29: with only a simulated weather station connected, the
    // safing toast read "Rig safed: secondary rig stopped, mount already safe"
    // while the status bar said Mount Disconnected and no secondary rig had ever
    // been configured. Both clauses described work that never happened.
    group('reports only what it actually did', () {
      test('an absent mount is recorded as absent, not as already safe', () {
        final container = makeContainer(mountConnected: false);
        addTearDown(container.dispose);

        return container
            .read(safeRigServiceProvider)
            .safeTheRig(reason: 'test', park: true, notify: false)
            .then((result) {
              expect(result.mountAbsent, isTrue);
              expect(result.mountAlreadyParked, isFalse);
              expect(result.mountParked, isFalse);
            });
      });

      test('an already-parked mount is recorded as already parked', () async {
        final container = makeContainer(mountParked: true);
        addTearDown(container.dispose);

        final result = await container
            .read(safeRigServiceProvider)
            .safeTheRig(reason: 'test', park: true, notify: false);

        expect(result.mountAlreadyParked, isTrue);
        expect(result.mountAbsent, isFalse);
      });

      test(
        'notification says the mount was NOT parked when none is connected',
        () async {
          final container = makeContainer(mountConnected: false);
          addTearDown(container.dispose);

          await container
              .read(safeRigServiceProvider)
              .safeTheRig(reason: 'Weather turned unsafe', park: true);

          final message = container.read(uiNotificationProvider).last.message;
          expect(message, contains('NO MOUNT CONNECTED'));
          expect(message, isNot(contains('mount already safe')));
          expect(message, isNot(contains('already parked')));
        },
      );

      test(
        'notification does not claim the secondary rig was stopped when none '
        'was running',
        () async {
          final container = makeContainer();
          addTearDown(container.dispose);

          await container
              .read(safeRigServiceProvider)
              .safeTheRig(reason: 'Weather turned unsafe', park: true);

          final message = container.read(uiNotificationProvider).last.message;
          expect(message, isNot(contains('secondary rig stopped')));
          expect(message, contains('mount parked'));
        },
      );

      // Audit 2026-08-03: enabling weather safety with no weather source
      // resolves fail-closed to unsafe, and the safing pass ran on an idle,
      // fully disconnected app. Nothing was commanded, yet the operator got a
      // red CRITICAL asserting both that the rig had been safed AND that
      // nothing had been possible.
      test(
        'a pass that commanded nothing is a warning, not a CRITICAL',
        () async {
          final container = makeContainer(
            executionState: SequenceExecutionState.idle,
            mountConnected: false,
          );
          addTearDown(container.dispose);

          await container
              .read(safeRigServiceProvider)
              .safeTheRig(reason: 'Weather turned unsafe', park: true);

          final note = container.read(uiNotificationProvider).last;
          expect(note.level, UiNotificationLevel.warning);
          expect(note.message, contains('Nothing to safe'));
          expect(note.message, isNot(contains('CRITICAL')));
          expect(note.message, isNot(contains('Rig safed')));
          expect(note.message, isNot(contains('no action was possible')));
          // The mount-absent warning is the operative sentence and must survive.
          expect(note.message, contains('NO MOUNT CONNECTED'));
        },
      );

      test('a pass that did command something stays CRITICAL', () async {
        final container = makeContainer();
        addTearDown(container.dispose);

        await container
            .read(safeRigServiceProvider)
            .safeTheRig(reason: 'Weather turned unsafe', park: true);

        final note = container.read(uiNotificationProvider).last;
        expect(note.level, UiNotificationLevel.error);
        expect(note.message, contains('CRITICAL'));
        expect(note.message, contains('Rig safed: '));
      });

      test('a secondary rig that was running is reported as stopped', () async {
        final container = makeContainer(
          safeRigBuilder: (ref) =>
              _RecordingSafeRig(ref, stopSecondaryRig: () async => true),
        );
        addTearDown(container.dispose);

        await container
            .read(safeRigServiceProvider)
            .safeTheRig(reason: 'Weather turned unsafe', park: true);

        expect(
          container.read(uiNotificationProvider).last.message,
          contains('secondary rig stopped'),
        );
      });
    });
  });
}
