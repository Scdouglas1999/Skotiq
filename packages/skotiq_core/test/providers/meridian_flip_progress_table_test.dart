// What a mount card shows of a meridian flip, on the host and on a linked
// client, after each thing that moves a flip along: the native flip steps,
// the flip monitor's own start and outcome, and a mount that disconnects.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../harness/in_memory_database.dart';
import 'runtime_mirror/mirror_link.dart';

class _Backend extends BackendNotifier {
  _Backend(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _Mount extends MountStateNotifier {
  _Mount(super.ref);

  void put(MountState next) => state = next;
}

const _tracking = MountState(
  connectionState: DeviceConnectionState.connected,
  deviceId: 'mount-1',
  isTracking: true,
  isParked: false,
  ra: 7.5,
  dec: -20,
);

String _shown(ProviderContainer c) => [
  c.read(flipExecutionStateProvider).name,
  c.read(flipCurrentAttemptProvider),
  c.read(flipCurrentStepProvider)?.name,
  c.read(flipProgressProvider),
  c.read(flipLastErrorProvider),
].join(' | ');

void main() {
  late MockHostBackend backend;
  late StreamController<SkotiqEvent> events;
  late ProviderContainer host;
  late _Mount mount;
  late Completer<void> flipRun;

  setUp(() {
    backend = MockHostBackend();
    events = StreamController<SkotiqEvent>.broadcast();
    addTearDown(events.close);
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => backend.performMeridianFlip(
        mountId: any(named: 'mountId'),
        cameraId: any(named: 'cameraId'),
        focuserId: any(named: 'focuserId'),
        coverCalibratorId: any(named: 'coverCalibratorId'),
        targetName: any(named: 'targetName'),
        targetRaHours: any(named: 'targetRaHours'),
        targetDecDegrees: any(named: 'targetDecDegrees'),
        pauseGuiding: any(named: 'pauseGuiding'),
        autoCenter: any(named: 'autoCenter'),
        refocusAfter: any(named: 'refocusAfter'),
        resumeGuiding: any(named: 'resumeGuiding'),
        settleTimeSecs: any(named: 'settleTimeSecs'),
      ),
    ).thenAnswer((_) => flipRun.future);
    host = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _Backend(ref, backend)),
        mountStateProvider.overrideWith((ref) => mount = _Mount(ref)),
      ],
    );
    addTearDown(host.dispose);
    host.read(hostRuntimeMirrorProvider);
    host.read(meridianFlipDisconnectGuardProvider);
    mount.put(_tracking);
  });

  /// Feed [steps] in order; after each, what the host shows and what a
  /// client linked to it then shows.
  Future<List<String>> run(List<Object> steps) async {
    final rows = <String>[];
    final client = mirrorClient(host);
    for (final step in steps) {
      switch (step) {
        case final String detail:
          events.add(
            SkotiqEvent(
              timestamp: 0,
              severity: EventSeverity.info,
              category: EventCategory.sequencer,
              eventType: 'InstructionProgress',
              data: {'detail_kind': 'MeridianFlip', 'detail_json': detail},
            ),
          );
          await Future<void>.delayed(Duration.zero);
        case final Future<void> Function() action:
          await action();
      }
      // The channel publishes at most every 500 ms.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await hydrateHostRuntimeState(client.container, client.backend);
      rows.add('${_shown(host)}  ->  ${_shown(client.container)}');
    }
    return rows;
  }

  final monitor = meridianFlipStandaloneMonitorProvider.notifier;

  const starting =
      '{"Starting":{"target_name":"M31","from_pier_side":"East","hour_angle":0.25}}';
  const slewing =
      '{"StepStarted":{"step":"SlewingToTarget","step_index":2,"total_steps":9}}';
  const progress40 = '{"Progress":{"percent":40}}';

  test('a full flip with one retry', () async {
    expect(
      await run([
        starting,
        slewing,
        progress40,
        '{"StepCompleted":{"step":"SlewingToTarget"}}',
        '{"RetryScheduled":{"attempt":1,"delay_secs":5,"reason":"pier side"}}',
        '{"StepStarted":{"step":"VerifyingPierSide","step_index":3,"total_steps":9}}',
        '{"Progress":{"percent":140}}',
        '{"Completed":{"new_pier_side":"West","duration_secs":185.0}}',
      ]),
      [
        'executing | 1 | null | 0 | null  ->  executing | 1 | null | 0 | null',
        'executing | 1 | slewingToTarget | 0 | null  ->  executing | 1 | slewingToTarget | 0 | null',
        'executing | 1 | slewingToTarget | 40 | null  ->  executing | 1 | slewingToTarget | 40 | null',
        'executing | 1 | slewingToTarget | 40 | null  ->  executing | 1 | slewingToTarget | 40 | null',
        'retrying | 2 | slewingToTarget | 0 | null  ->  retrying | 2 | slewingToTarget | 0 | null',
        'executing | 2 | verifyingPierSide | 0 | null  ->  executing | 2 | verifyingPierSide | 0 | null',
        'executing | 2 | verifyingPierSide | 100 | null  ->  executing | 2 | verifyingPierSide | 100 | null',
        'completed | 2 | null | 100 | null  ->  completed | 2 | null | 100 | null',
      ],
    );
  });

  test('a flip that fails before it starts', () async {
    expect(
      await run([
        starting,
        progress40,
        '{"Completed":{"new_pier_side":"West","duration_secs":185.0}}',
        '{"Failed":{"error":"retry delays missing","action_taken":"parked"}}',
        '{"Aborted":{"reason":"a sequence owns the mount"}}',
      ]),
      [
        'executing | 1 | null | 0 | null  ->  executing | 1 | null | 0 | null',
        'executing | 1 | null | 40 | null  ->  executing | 1 | null | 40 | null',
        'completed | 1 | null | 100 | null  ->  completed | 1 | null | 100 | null',
        'failed | 0 | null | 0 | retry delays missing  ->  failed | 0 | null | 0 | retry delays missing',
        'aborted | 0 | null | 0 | a sequence owns the mount  ->  aborted | 0 | null | 0 | a sequence owns the mount',
      ],
    );
  });

  test('a flip that fails mid-way', () async {
    expect(
      await run([
        starting,
        slewing,
        progress40,
        '{"StepFailed":{"step":"SlewingToTarget","error":"slew timed out"}}',
        '{"Failed":{"error":"pier side did not change","action_taken":"parked"}}',
      ]),
      [
        'executing | 1 | null | 0 | null  ->  executing | 1 | null | 0 | null',
        'executing | 1 | slewingToTarget | 0 | null  ->  executing | 1 | slewingToTarget | 0 | null',
        'executing | 1 | slewingToTarget | 40 | null  ->  executing | 1 | slewingToTarget | 40 | null',
        'executing | 1 | slewingToTarget | 40 | slew timed out  ->  executing | 1 | slewingToTarget | 40 | slew timed out',
        'failed | 1 | slewingToTarget | 40 | pier side did not change  ->  failed | 1 | slewingToTarget | 40 | pier side did not change',
      ],
    );
  });

  test('the mount disconnects mid-flip', () async {
    expect(
      await run([
        starting,
        slewing,
        progress40,
        () async => mount.put(const MountState()),
      ]),
      [
        'executing | 1 | null | 0 | null  ->  executing | 1 | null | 0 | null',
        'executing | 1 | slewingToTarget | 0 | null  ->  executing | 1 | slewingToTarget | 0 | null',
        'executing | 1 | slewingToTarget | 40 | null  ->  executing | 1 | slewingToTarget | 40 | null',
        'aborted | 1 | slewingToTarget | 40 | Meridian flip aborted: mount disconnected  ->  aborted | 1 | slewingToTarget | 40 | Meridian flip aborted: mount disconnected',
      ],
    );
  });

  test('a manual flip from the monitor: refused, run, failed', () async {
    await host.read(globalMeridianFlipSettingsProvider.notifier).ensureLoaded();
    await host
        .read(globalMeridianFlipSettingsProvider.notifier)
        .setPushNotificationOnFlip(false);
    late Future<bool> flip;
    expect(
      await run([
        starting,
        slewing,
        progress40,
        // Refused while one is under way: only the error changes.
        () => host.read(monitor).executeNow(),
        '{"Completed":{"new_pier_side":"West","duration_secs":185.0}}',
        () async => mount.put(_tracking.copyWith(isParked: true)),
        () => host.read(monitor).executeNow(),
        () async => mount.put(_tracking),
        () async {
          flipRun = Completer<void>();
          flip = host.read(monitor).executeNow();
        },
        slewing,
        progress40,
        () async {
          flipRun.complete();
          await flip;
        },
        () async {
          flipRun = Completer<void>();
          flip = host.read(monitor).executeNow();
        },
        slewing,
        () async {
          flipRun.completeError(StateError('mount refused the slew'));
          await flip;
        },
      ]),
      [
        'executing | 1 | null | 0 | null  ->  executing | 1 | null | 0 | null',
        'executing | 1 | slewingToTarget | 0 | null  ->  executing | 1 | slewingToTarget | 0 | null',
        'executing | 1 | slewingToTarget | 40 | null  ->  executing | 1 | slewingToTarget | 40 | null',
        'executing | 1 | slewingToTarget | 40 | A meridian flip is already in progress  ->  executing | 1 | slewingToTarget | 40 | A meridian flip is already in progress',
        'completed | 1 | null | 100 | null  ->  completed | 1 | null | 100 | null',
        'completed | 1 | null | 100 | null  ->  completed | 1 | null | 100 | null',
        'completed | 1 | null | 100 | Unpark the mount before flipping manually  ->  completed | 1 | null | 100 | Unpark the mount before flipping manually',
        'completed | 1 | null | 100 | Unpark the mount before flipping manually  ->  completed | 1 | null | 100 | Unpark the mount before flipping manually',
        'executing | 1 | null | 0 | null  ->  executing | 1 | null | 0 | null',
        'executing | 1 | slewingToTarget | 0 | null  ->  executing | 1 | slewingToTarget | 0 | null',
        'executing | 1 | slewingToTarget | 40 | null  ->  executing | 1 | slewingToTarget | 40 | null',
        'completed | 1 | slewingToTarget | 100 | null  ->  completed | 1 | slewingToTarget | 100 | null',
        'executing | 1 | null | 0 | null  ->  executing | 1 | null | 0 | null',
        'executing | 1 | slewingToTarget | 0 | null  ->  executing | 1 | slewingToTarget | 0 | null',
        'failed | 1 | slewingToTarget | 0 | Bad state: mount refused the slew  ->  failed | 1 | slewingToTarget | 0 | Bad state: mount refused the slew',
      ],
    );
  });
}
