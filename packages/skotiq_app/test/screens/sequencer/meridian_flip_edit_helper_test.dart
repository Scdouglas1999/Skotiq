// Tests for `applyMeridianFlipEdit(...)`, the editor-layer helper that
// owns the "touching a config field clears useGlobalDefaults" UX heuristic.
//
// The heuristic belongs in the editor layer, not in
// `MeridianFlipNode.copyWith`, so the data model stays a plain field-replace
// (see `meridian_flip_edit_helper.dart`). These tests pin the behaviour where it
// lives.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/meridian_flip_edit_helper.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('applyMeridianFlipEdit', () {
    test('no_args_returns_a_clone_with_identical_field_values', () {
      final n = MeridianFlipNode(
        useGlobalDefaults: false,
        triggerMethod: MeridianTriggerMethod.hourAngleThreshold,
        minutesPastMeridian: 7.0,
      );
      final out = applyMeridianFlipEdit(n);
      expect(out.useGlobalDefaults, isFalse);
      expect(out.triggerMethod, MeridianTriggerMethod.hourAngleThreshold);
      expect(out.minutesPastMeridian, 7.0);
    });

    test('touching_a_config_field_implicitly_flips_global_defaults_off', () {
      // The 11 flip-config fields each independently signal "user edit
      // happened" — each one flips useGlobalDefaults off.
      final n = MeridianFlipNode();
      expect(n.useGlobalDefaults, isTrue);

      expect(
        applyMeridianFlipEdit(n,
                triggerMethod: MeridianTriggerMethod.hourAngleThreshold)
            .useGlobalDefaults,
        isFalse,
      );
      expect(
        applyMeridianFlipEdit(n, minutesPastMeridian: 10.0).useGlobalDefaults,
        isFalse,
      );
      expect(
        applyMeridianFlipEdit(n, minutesBeforeLimit: 15.0).useGlobalDefaults,
        isFalse,
      );
      expect(
        applyMeridianFlipEdit(n, hourAngleThreshold: 1.0).useGlobalDefaults,
        isFalse,
      );
      expect(
        applyMeridianFlipEdit(n, pauseGuiding: false).useGlobalDefaults,
        isFalse,
      );
      expect(
        applyMeridianFlipEdit(n, autoCenter: false).useGlobalDefaults,
        isFalse,
      );
      expect(
        applyMeridianFlipEdit(n, refocusAfter: true).useGlobalDefaults,
        isFalse,
      );
      expect(
        applyMeridianFlipEdit(n, settleTime: 5.0).useGlobalDefaults,
        isFalse,
      );
      expect(
        applyMeridianFlipEdit(n, resumeGuiding: false).useGlobalDefaults,
        isFalse,
      );
      expect(
        applyMeridianFlipEdit(n, maxRetries: 5).useGlobalDefaults,
        isFalse,
      );
      expect(
        applyMeridianFlipEdit(n, failureAction: FlipFailureAction.abortAndPark)
            .useGlobalDefaults,
        isFalse,
      );
    });

    test('touching_only_structural_fields_does_not_flip_global_defaults', () {
      // Pure structural changes (id/name/parent/etc.) leave the flag alone.
      final n = MeridianFlipNode();
      expect(applyMeridianFlipEdit(n, name: 'X').useGlobalDefaults, isTrue);
      expect(applyMeridianFlipEdit(n, parentId: 'p').useGlobalDefaults, isTrue);
      expect(applyMeridianFlipEdit(n, orderIndex: 5).useGlobalDefaults, isTrue);
      expect(applyMeridianFlipEdit(n, comment: 'c').useGlobalDefaults, isTrue);
      expect(
          applyMeridianFlipEdit(n, isEnabled: false).useGlobalDefaults, isTrue);
    });

    test('explicit_use_global_defaults_arg_always_wins', () {
      // The properties panel's "Use global defaults" toggle drives this
      // path: the explicit arg overrides the touched-config heuristic.
      final n = MeridianFlipNode();
      final copy = applyMeridianFlipEdit(
        n,
        triggerMethod: MeridianTriggerMethod.hourAngleThreshold,
        useGlobalDefaults: true,
      );
      expect(copy.useGlobalDefaults, isTrue);
      expect(copy.triggerMethod, MeridianTriggerMethod.hourAngleThreshold);
    });

    test('field_values_round_trip_through_the_helper', () {
      // Every supplied non-null value lands on the returned node.
      final n = MeridianFlipNode();
      final out = applyMeridianFlipEdit(
        n,
        triggerMethod: MeridianTriggerMethod.minutesBeforeLimit,
        minutesPastMeridian: 12.0,
        minutesBeforeLimit: 8.0,
        hourAngleThreshold: 0.75,
        pauseGuiding: false,
        autoCenter: false,
        refocusAfter: true,
        settleTime: 3.0,
        resumeGuiding: false,
        maxRetries: 7,
        failureAction: FlipFailureAction.abortAndPark,
      );
      expect(out.triggerMethod, MeridianTriggerMethod.minutesBeforeLimit);
      expect(out.minutesPastMeridian, 12.0);
      expect(out.minutesBeforeLimit, 8.0);
      expect(out.hourAngleThreshold, 0.75);
      expect(out.pauseGuiding, isFalse);
      expect(out.autoCenter, isFalse);
      expect(out.refocusAfter, isTrue);
      expect(out.settleTime, 3.0);
      expect(out.resumeGuiding, isFalse);
      expect(out.maxRetries, 7);
      expect(out.failureAction, FlipFailureAction.abortAndPark);
      // ...and the heuristic still fired.
      expect(out.useGlobalDefaults, isFalse);
    });
  });
}
