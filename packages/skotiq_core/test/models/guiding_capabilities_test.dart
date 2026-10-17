// Truth table for the guiding capability layer (defect 4/6).
//
// Both the desktop and mobile guiding controls share `GuideControlsPanel` and
// drive every enable/label decision from these getters, so this pure table is
// what guarantees the two surfaces can never disagree about, e.g., whether
// Start is legal. The load-bearing rules:
//   * Start is legal ONLY from a connected, genuinely-idle state (stopped).
//   * paused / calibrating / settling / looping / lost-lock / unknown NEVER
//     offer Start — they offer Stop.
//   * unknown is treated as possibly-live (Stop yes, Start no) so an
//     unrecognised PHD2 state can't falsely re-enable Start.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('Phd2GuidingCapabilities', () {
    const busyPhases = <Phd2GuidingState>[
      Phd2GuidingState.guiding,
      Phd2GuidingState.paused,
      Phd2GuidingState.calibrating,
      Phd2GuidingState.settling,
      Phd2GuidingState.looping,
      Phd2GuidingState.lostLock,
      Phd2GuidingState.unknown,
    ];

    test('Start is legal only from the stopped state', () {
      expect(Phd2GuidingState.stopped.canStart, isTrue);
      for (final s in [...busyPhases, Phd2GuidingState.disconnected]) {
        expect(s.canStart, isFalse, reason: '$s must NOT enable Start');
      }
    });

    test('Stop is legal from every live/transitional/uncertain state', () {
      for (final s in busyPhases) {
        expect(s.canStop, isTrue, reason: 'Stop must work from $s');
      }
      expect(Phd2GuidingState.stopped.canStop, isFalse);
      expect(Phd2GuidingState.disconnected.canStop, isFalse);
    });

    test(
      'Stop works from Paused (there must be a truthful Stop affordance)',
      () {
        expect(Phd2GuidingState.paused.canStop, isTrue);
        expect(Phd2GuidingState.paused.canStart, isFalse);
      },
    );

    test('pause / resume are mutually exclusive and state-truthful', () {
      expect(Phd2GuidingState.guiding.canPause, isTrue);
      expect(Phd2GuidingState.guiding.canResume, isFalse);
      expect(Phd2GuidingState.paused.canResume, isTrue);
      expect(Phd2GuidingState.paused.canPause, isFalse);
      // Transitional phases offer neither.
      expect(Phd2GuidingState.calibrating.canPause, isFalse);
      expect(Phd2GuidingState.settling.canResume, isFalse);
    });

    test('dither only while actively guiding', () {
      expect(Phd2GuidingState.guiding.canDither, isTrue);
      for (final s in [
        Phd2GuidingState.paused,
        Phd2GuidingState.settling,
        Phd2GuidingState.calibrating,
        Phd2GuidingState.looping,
        Phd2GuidingState.lostLock,
        Phd2GuidingState.unknown,
        Phd2GuidingState.stopped,
      ]) {
        expect(s.canDither, isFalse, reason: 'dither must be blocked in $s');
      }
    });

    test('loop only from the stopped state', () {
      expect(Phd2GuidingState.stopped.canLoop, isTrue);
      for (final s in busyPhases) {
        expect(s.canLoop, isFalse, reason: 'loop must be blocked in $s');
      }
    });

    test('unknown surfaces a truthful, conservative label', () {
      expect(Phd2GuidingState.unknown.displayName, 'Unknown');
    });
  });
}
