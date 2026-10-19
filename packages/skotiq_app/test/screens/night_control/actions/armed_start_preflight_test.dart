// Start at dark checks the run again when it fires: the checks the Start
// dialog makes that need nobody at the keyboard. A failed check leaves the
// run unstarted and says why on the action bar, in the log and in a toast;
// it never stops, parks or retries anything.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/models/command_action_result.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../data/plan/plan_test_support.dart' show TwoTargetPlan;
import 'night_action_test_support.dart';

/// A plan that images the sky: two targets of light frames.
class _SkyPlan extends CurrentSequenceNotifier {
  _SkyPlan(Ref ref) : super(ref: ref) {
    state = TwoTargetPlan().sequence;
  }
}

typedef _Harness = ({
  ProviderContainer container,
  FakeRigOps ops,
  RecordingLog log,
});

const _blocking = ValidationIssue(
  severity: ValidationSeverity.error,
  category: ValidationCategory.equipment,
  title: 'No camera in the profile',
  description: 'The plan captures frames but no camera is set.',
);

/// Arms, runs the clock past dark and hands back the harness.
_Harness _fire(
  FakeAsync async, {
  void Function(FakeRigOps ops)? script,
  bool parked = false,
}) {
  final dark = DateTime.now().toUtc().add(const Duration(minutes: 30));
  final h = actionHarness(astroDark: dark, extra: [
    currentSequenceProvider.overrideWith((ref) => _SkyPlan(ref)),
  ]);
  script?.call(h.ops);
  if (parked) {
    (h.container.read(mountStateProvider.notifier) as TestMountNotifier).put(
      const MountState(
        connectionState: connected,
        deviceId: 'mount-1',
        isParked: true,
      ),
    );
  }
  h.container.read(nightActionApiProvider).armStartAtDark();
  async.flushMicrotasks();
  async.elapse(const Duration(minutes: 31));
  return h;
}

void main() {
  test('a clean run starts at dark', () {
    fakeAsync((async) {
      final h = _fire(async);
      expect(h.ops.calls, ['validate', 'start']);
      expect(h.container.read(nightActionStateProvider).error, isNull);
      h.container.dispose();
    });
  });

  test('a pre-flight error at dark keeps the run from starting', () {
    fakeAsync((async) {
      final h = _fire(
        async,
        script: (ops) => ops.validationIssues = const [_blocking],
      );
      expect(h.ops.calls, ['validate'], reason: 'no start');
      final error = h.container.read(nightActionStateProvider).error;
      expect(error?.key, 'nightScrArmBlocked');
      expect(error?.params, {'count': '1', 'issue': _blocking.title});
      final toasts = h.container.read(uiNotificationProvider);
      expect(toasts, isNotEmpty, reason: 'nobody may be watching the bar');
      expect(toasts.last.title, 'Start at dark did not start the run');
      expect(
          h.log.lines.any((l) => l.contains('did not start the run')), isTrue);
      h.container.dispose();
    });
  });

  test('warnings alone do not hold the run back', () {
    fakeAsync((async) {
      final h = _fire(
        async,
        script: (ops) => ops.validationIssues = const [
          ValidationIssue(
            severity: ValidationSeverity.warning,
            category: ValidationCategory.timing,
            title: 'Runs past dawn',
            description: 'The last target ends after dawn.',
          ),
        ],
      );
      expect(h.ops.calls, ['validate', 'start']);
      h.container.dispose();
    });
  });

  test('a parked mount is unparked for a sky run, then the run starts', () {
    fakeAsync((async) {
      final h = _fire(async, parked: true);
      expect(h.ops.calls, ['validate', 'unpark', 'start']);
      h.container.dispose();
    });
  });

  test('a mount that does not unpark keeps the run from starting', () {
    fakeAsync((async) {
      final h = _fire(
        async,
        parked: true,
        script: (ops) => ops.unparkResult =
            const CommandActionResult.failure('Driver refused'),
      );
      expect(h.ops.calls, ['validate', 'unpark']);
      expect(h.container.read(nightActionStateProvider).error?.key,
          'nightScrArmUnparkFailed');
      h.container.dispose();
    });
  });

  test('a host that went away at dark is not commanded', () {
    fakeAsync((async) {
      final dark = DateTime.now().toUtc().add(const Duration(minutes: 30));
      final canCommand = StateProvider<bool>((ref) => true);
      final h = actionHarness(astroDark: dark, extra: [
        currentSequenceProvider.overrideWith((ref) => _SkyPlan(ref)),
        backendCanCommandProvider.overrideWith((ref) => ref.watch(canCommand)),
      ]);
      h.container.read(nightActionApiProvider).armStartAtDark();
      async.flushMicrotasks();
      h.container.read(canCommand.notifier).state = false;
      async.elapse(const Duration(minutes: 31));
      expect(h.ops.calls, isEmpty);
      expect(h.container.read(nightActionStateProvider).error?.key,
          'nightActWhyNoHost');
      h.container.dispose();
    });
  });
}
