import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/models/command_action_result.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/night_control/actions/armed_start_provider.dart';
import 'package:skotiq_app/screens/night_control/actions/manual_action_gating.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'night_action_test_support.dart';

void main() {
  const running = SequenceExecutionState.running;
  const paused = SequenceExecutionState.paused;

  group('RunPauseGuard through the controller', () {
    test('a run this controller paused is resumed afterwards', () async {
      final h = actionHarness(runState: running);
      addTearDown(h.container.dispose);

      await h.container.read(nightActionApiProvider).autofocus();

      expect(h.ops.calls, ['pause', 'autofocus', 'resume']);
      expect(h.container.read(sequenceExecutionStateProvider), running);
      final state = h.container.read(nightActionStateProvider);
      expect(state.phase, ManualActionPhase.idle);
      expect(state.error, isNull);
      expect(state.runLeftPaused, isFalse);
    });

    test('a run the operator paused is left paused', () async {
      final h = actionHarness(runState: paused);
      addTearDown(h.container.dispose);

      await h.container.read(nightActionApiProvider).autofocus();

      expect(h.ops.calls, ['autofocus']);
      expect(h.container.read(sequenceExecutionStateProvider), paused);
    });

    test('a failed resume leaves the run paused and never stops it', () async {
      final h = actionHarness(runState: running);
      addTearDown(h.container.dispose);
      h.ops.resumeResult =
          const CommandActionResult.failure('executor refused');

      await h.container.read(nightActionApiProvider).dither();

      expect(h.ops.calls, ['pause', 'dither', 'resume']);
      expect(h.container.read(sequenceExecutionStateProvider), paused);
      final state = h.container.read(nightActionStateProvider);
      expect(state.runLeftPaused, isTrue);
      expect(state.error?.key, 'nightActErrResume');
      expect(state.error?.params['detail'], 'executor refused');
      expect(h.log.lines.where((l) => l.startsWith('E ')), isNotEmpty);
    });

    test('a failed action still resumes the run it paused', () async {
      final h = actionHarness(runState: running);
      addTearDown(h.container.dispose);
      h.ops.actionError = StateError('star lost');

      await h.container.read(nightActionApiProvider).autofocus();

      expect(h.ops.calls, ['pause', 'autofocus', 'resume']);
      expect(h.container.read(sequenceExecutionStateProvider), running);
      final state = h.container.read(nightActionStateProvider);
      expect(state.error?.key, 'nightActErrAutofocus');
      expect(state.error?.params['detail'], contains('star lost'));
      expect(state.runLeftPaused, isFalse);
    });

    test('waits for the camera to go idle before acting', () async {
      final h = actionHarness(runState: running);
      addTearDown(h.container.dispose);
      final c = h.container;
      final camera = c.read(cameraStateProvider.notifier) as TestCameraNotifier;
      camera.setExposing(true);
      final progress = c.read(exposureProgressProvider.notifier);
      progress.startExposure(180, 44, 60);
      progress.updateProgress(72, 108, 40);

      final done = c.read(nightActionApiProvider).autofocus();
      await settle();

      expect(h.ops.calls, ['pause']);
      var state = c.read(nightActionStateProvider);
      expect(state.phase, ManualActionPhase.waitingForFrame);
      expect(state.startedRunPause, isTrue);
      expect(state.waitingForFrame, 44);
      expect(state.exposureRemaining, const Duration(seconds: 108));
      expect(state.message?.key, 'nightActPausingAfter');

      // The exposure ends but the camera still reports exposing.
      progress.reset();
      await settle();
      expect(h.ops.calls, ['pause']);

      camera.setExposing(false);
      await done;
      expect(h.ops.calls, ['pause', 'autofocus', 'resume']);
      state = c.read(nightActionStateProvider);
      expect(state.phase, ManualActionPhase.idle);
    });

    test('waits for a slew the run started to finish', () async {
      final h = actionHarness(runState: running);
      addTearDown(h.container.dispose);
      final mount =
          h.container.read(mountStateProvider.notifier) as TestMountNotifier;
      final steady = h.container.read(mountStateProvider);
      mount.put(steady.copyWith(isSlewing: true));

      final done = h.container.read(nightActionApiProvider).dither();
      await settle();
      expect(h.ops.calls, ['pause']);

      mount.put(steady);
      await done;
      expect(h.ops.calls, ['pause', 'dither', 'resume']);
    });

    test('a run resumed elsewhere while waiting is not acted on', () async {
      final h = actionHarness(runState: running);
      addTearDown(h.container.dispose);
      final c = h.container;
      (c.read(cameraStateProvider.notifier) as TestCameraNotifier)
          .setExposing(true);

      final done = c.read(nightActionApiProvider).snapshot();
      await settle();
      c.read(sequenceExecutionStateProvider.notifier).state = running;
      await done;

      expect(h.ops.calls, ['pause']);
      expect(
          c.read(nightActionStateProvider).error?.key, 'nightActErrRunMoved');
    });

    test('cancel while waiting for the frame resumes the run', () async {
      final h = actionHarness(runState: running);
      addTearDown(h.container.dispose);
      final c = h.container;
      (c.read(cameraStateProvider.notifier) as TestCameraNotifier)
          .setExposing(true);

      final done = c.read(nightActionApiProvider).autofocus();
      await settle();
      await c.read(nightActionApiProvider).cancel();
      await done;

      expect(h.ops.calls, ['pause', 'cancelAutofocus', 'resume']);
      expect(c.read(sequenceExecutionStateProvider), running);
      expect(c.read(nightActionStateProvider).error, isNull);
    });
  });

  group('single flight', () {
    test('a double tap joins the action in flight', () async {
      final h = actionHarness();
      addTearDown(h.container.dispose);
      h.ops.actionGate = Completer<void>();
      final api = h.container.read(nightActionApiProvider);

      final first = api.autofocus();
      final second = api.run(ManualActionId.autofocus);
      expect(identical(first, second), isTrue);

      h.ops.actionGate!.complete();
      await Future.wait([first, second]);
      expect(h.ops.calls.where((c) => c == 'autofocus'), hasLength(1));
    });

    test('a different action while busy changes nothing', () async {
      final h = actionHarness();
      addTearDown(h.container.dispose);
      h.ops.actionGate = Completer<void>();
      final api = h.container.read(nightActionApiProvider);

      final first = api.autofocus();
      await settle();
      final before = h.container.read(nightActionStateProvider);
      await api.snapshot();
      await api.dither();

      expect(h.ops.calls, ['autofocus']);
      expect(h.container.read(nightActionStateProvider), before);
      final vms = h.container.read(nightManualActionsProvider);
      final snapshot = vms.firstWhere((a) => a.id == ManualActionId.snapshot);
      expect(snapshot.enabled, isFalse);
      expect(snapshot.disabledReason?.key, 'nightActBusyAutofocus');
      final autofocus = vms.firstWhere((a) => a.id == ManualActionId.autofocus);
      expect(autofocus.running, isTrue);
      expect(autofocus.sub?.key, 'nightActSubRunning');

      h.ops.actionGate!.complete();
      await first;
    });
  });

  test('every per-action busy and failure key has a translation', () {
    final en = SkotiqLocalizations.debugLocalizedValues['en']!;
    for (final id in ManualActionId.values) {
      expect(en, contains(manualActionKey('nightActBusy', id)));
      expect(en, contains(manualActionKey('nightActErr', id)));
    }
  });

  group('gating', () {
    test('a remote viewer that cannot command sees every action disabled',
        () async {
      final h = actionHarness(canCommand: false, runState: running);
      addTearDown(h.container.dispose);

      final vms = h.container.read(nightManualActionsProvider);
      expect(vms, isNotEmpty);
      for (final vm in vms) {
        expect(vm.enabled, isFalse, reason: vm.id.name);
        expect(vm.disabledReason?.key, 'nightActWhyNoHost');
      }

      final api = h.container.read(nightActionApiProvider);
      for (final id in ManualActionId.values) {
        await api.run(id);
      }
      await api.armStartAtDark();
      expect(h.ops.calls, isEmpty);
      expect(api.armedStartAt, isNull);
    });

    test('flip is disabled while a run is loaded, with the reason', () async {
      for (final runState in [running, paused]) {
        final h = actionHarness(runState: runState);
        addTearDown(h.container.dispose);

        final flip = h.container
            .read(nightManualActionsProvider)
            .firstWhere((a) => a.id == ManualActionId.flip);
        expect(flip.enabled, isFalse);
        expect(flip.disabledReason?.key, 'nightActWhyFlipRun');

        await h.container.read(nightActionApiProvider).flipNow();
        expect(h.ops.calls, isEmpty);
      }
    });

    test(
        'the ready board shows tracking and cooler, a run shows dither and '
        'flip', () {
      final ready = actionHarness();
      addTearDown(ready.container.dispose);
      expect(
        ready.container.read(nightManualActionsProvider).map((a) => a.id),
        [
          ManualActionId.snapshot,
          ManualActionId.loop,
          ManualActionId.autofocus,
          ManualActionId.solveSync,
          ManualActionId.center,
          ManualActionId.tracking,
          ManualActionId.cooler,
        ],
      );
      final run = actionHarness(runState: running);
      addTearDown(run.container.dispose);
      final vms = run.container.read(nightManualActionsProvider);
      expect(vms.map((a) => a.id), [
        ManualActionId.snapshot,
        ManualActionId.loop,
        ManualActionId.autofocus,
        ManualActionId.solveSync,
        ManualActionId.center,
        ManualActionId.dither,
        ManualActionId.flip,
      ]);
      final center = vms.firstWhere((a) => a.id == ManualActionId.center);
      expect(center.sub, const NightText.literal('M74'));
    });

    test('a stopping run disables every action', () {
      final h = actionHarness(runState: SequenceExecutionState.stopping);
      addTearDown(h.container.dispose);
      for (final vm in h.container.read(nightManualActionsProvider)) {
        expect(vm.enabled, isFalse);
      }
    });

    test('a disconnected camera disables the camera actions only', () {
      final h = actionHarness();
      addTearDown(h.container.dispose);
      (h.container.read(cameraStateProvider.notifier) as TestCameraNotifier)
          .put(const CameraStateSnapshot());
      final vms = {
        for (final vm in h.container.read(nightManualActionsProvider))
          vm.id: vm,
      };
      expect(vms[ManualActionId.snapshot]!.disabledReason?.key,
          'nightActWhyNoCamera');
      expect(vms[ManualActionId.tracking]!.enabled, isTrue);
    });
  });

  group('per action', () {
    test(
        'center stops guiding before the slew and settles it before the '
        'resume', () async {
      final h = actionHarness(runState: running);
      addTearDown(h.container.dispose);

      await h.container.read(nightActionApiProvider).center();

      expect(h.ops.calls, [
        'pause',
        'stopGuiding',
        'center M74',
        'startGuidingAndSettle',
        'resume',
      ]);
    });

    test('center leaves guiding off when it was off', () async {
      final h = actionHarness();
      addTearDown(h.container.dispose);
      h.ops.guiding = false;

      await h.container.read(nightActionApiProvider).center();

      expect(h.ops.calls, ['center M74']);
    });

    test('loop during a run holds the run until the loop stops', () async {
      final h = actionHarness(runState: running);
      addTearDown(h.container.dispose);
      final api = h.container.read(nightActionApiProvider);

      final looping = api.toggleLoop();
      await settle();
      final state = h.container.read(nightActionStateProvider);
      expect(state.active, ManualActionId.loop);
      expect(state.message?.key, 'nightActLoopHoldsRun');
      expect(h.container.read(sequenceExecutionStateProvider), paused);
      final loopVm = h.container
          .read(nightManualActionsProvider)
          .firstWhere((a) => a.id == ManualActionId.loop);
      expect(loopVm.label.key, 'nightActStopLoop');
      expect(loopVm.enabled, isTrue);

      final stopped = api.toggleLoop();
      expect(identical(stopped, looping), isTrue);
      await looping;
      expect(h.ops.calls, ['pause', 'loop', 'stopCapture', 'resume']);
      expect(h.container.read(sequenceExecutionStateProvider), running);
      expect(h.container.read(nightActionStateProvider).error, isNull);
    });

    test('solve & sync records how long the solve took', () async {
      final h = actionHarness();
      addTearDown(h.container.dispose);

      await h.container.read(nightActionApiProvider).solveAndSync();

      expect(h.container.read(nightActionStateProvider).lastSolveDuration,
          const Duration(milliseconds: 4200));
    });

    test('cooler turns on at the profile setpoint', () async {
      final h = actionHarness(coolerSetpoint: -15);
      addTearDown(h.container.dispose);

      await h.container.read(nightActionApiProvider).toggleCooler();

      expect(h.ops.calls, ['setCooler true -15.0']);
    });

    test('tracking toggles off when the mount tracks', () async {
      final h = actionHarness();
      addTearDown(h.container.dispose);

      await h.container.read(nightActionApiProvider).toggleTracking();

      expect(h.ops.calls, ['setTracking false']);
    });
  });

  group('start at dark', () {
    test('fires start once at dark, and cancel clears it', () {
      fakeAsync((async) {
        final dark = DateTime.now().toUtc().add(const Duration(hours: 2));
        final h = actionHarness(astroDark: dark, extra: [
          currentSequenceProvider.overrideWith(
            (ref) => _LoadedSequence(ref),
          ),
        ]);
        final api = h.container.read(nightActionApiProvider);

        api.armStartAtDark();
        async.flushMicrotasks();
        expect(api.armedStartAt, dark);
        expect(h.container.read(nightArmedStartProvider), dark);

        async.elapse(const Duration(hours: 1, minutes: 59));
        expect(h.ops.calls, isEmpty);
        async.elapse(const Duration(minutes: 2));
        expect(h.ops.calls, ['validate', 'start']);
        expect(api.armedStartAt, isNull);
        async.elapse(const Duration(hours: 6));
        expect(h.ops.calls, ['validate', 'start']);
        h.container.dispose();
      });
    });

    test('cancel before dark means start never fires', () {
      fakeAsync((async) {
        final dark = DateTime.now().toUtc().add(const Duration(hours: 1));
        final h = actionHarness(astroDark: dark, extra: [
          currentSequenceProvider.overrideWith(
            (ref) => _LoadedSequence(ref),
          ),
        ]);
        final api = h.container.read(nightActionApiProvider);

        api.armStartAtDark();
        async.flushMicrotasks();
        expect(api.armedStartAt, dark);
        api.cancelArmedStart();
        expect(api.armedStartAt, isNull);
        async.elapse(const Duration(hours: 3));
        expect(h.ops.calls, isEmpty);
        h.container.dispose();
      });
    });

    test('arming after dark is refused with the reason', () async {
      final h = actionHarness(
        astroDark: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
        extra: [
          currentSequenceProvider.overrideWith((ref) => _LoadedSequence(ref)),
        ],
      );
      addTearDown(h.container.dispose);
      final api = h.container.read(nightActionApiProvider);

      await api.armStartAtDark();

      expect(api.armedStartAt, isNull);
      expect(h.container.read(nightActionStateProvider).error?.key,
          'nightActErrArmAlreadyDark');
    });

    test('a plan is required', () async {
      final h = actionHarness(
        astroDark: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      addTearDown(h.container.dispose);
      final api = h.container.read(nightActionApiProvider);

      await api.armStartAtDark();

      expect(api.armedStartAt, isNull);
      expect(h.container.read(nightActionStateProvider).error?.key,
          'nightActErrArmNoPlan');
    });
  });
}

class _LoadedSequence extends CurrentSequenceNotifier {
  _LoadedSequence(Ref ref) : super(ref: ref) {
    state = Sequence.create(name: 'Tonight');
  }
}
