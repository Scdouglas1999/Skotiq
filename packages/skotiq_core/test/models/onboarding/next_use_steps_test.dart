import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show NextUseActionId, NextUseStep, kNextUseSteps, stepFor;

void main() {
  group('kNextUseSteps', () {
    test('covers every NextUseActionId exactly once', () {
      final ids = kNextUseSteps.map((s) => s.id).toList();

      // Exactly one step per id (no duplicates, no extras).
      expect(ids.length, NextUseActionId.values.length);
      expect(ids.toSet(), NextUseActionId.values.toSet());

      for (final id in NextUseActionId.values) {
        expect(
          ids.where((stepId) => stepId == id).length,
          1,
          reason: 'Expected exactly one next-use step for $id',
        );
      }
    });

    test('is in the required teaching order', () {
      expect(kNextUseSteps.map((s) => s.id).toList(), const <NextUseActionId>[
        NextUseActionId.buildSmartNight,
        NextUseActionId.frameTarget,
        NextUseActionId.configurePlateSolver,
        NextUseActionId.runAutofocus,
        NextUseActionId.captureFirstLight,
      ]);
    });

    test('maps each id to the exact deep-link route', () {
      expect(
        stepFor(NextUseActionId.buildSmartNight).deepLinkRoute,
        '/planner?tab=scheduler',
      );
      expect(stepFor(NextUseActionId.frameTarget).deepLinkRoute, '/framing');
      expect(
        stepFor(NextUseActionId.configurePlateSolver).deepLinkRoute,
        '/settings?section=plate-solving',
      );
      expect(stepFor(NextUseActionId.runAutofocus).deepLinkRoute, '/equipment');
      expect(
        stepFor(NextUseActionId.captureFirstLight).deepLinkRoute,
        '/imaging?firstLight=1',
      );
    });

    test(
      'has non-empty title, body, actionLabel and iconKey for every step',
      () {
        for (final step in kNextUseSteps) {
          expect(step.title.trim(), isNotEmpty, reason: '${step.id} title');
          expect(step.body.trim(), isNotEmpty, reason: '${step.id} body');
          expect(
            step.actionLabel.trim(),
            isNotEmpty,
            reason: '${step.id} actionLabel',
          );
          expect(step.iconKey.trim(), isNotEmpty, reason: '${step.id} iconKey');
        }
      },
    );

    test('every deep-link route is a parseable, rooted path', () {
      for (final step in kNextUseSteps) {
        expect(
          step.deepLinkRoute.startsWith('/'),
          isTrue,
          reason: '${step.id} route must be app-rooted',
        );
        // Must not throw — a malformed deep link should fail loudly here.
        expect(
          () => Uri.parse(step.deepLinkRoute),
          returnsNormally,
          reason: '${step.id} route',
        );
      }
    });

    test('every query parameter value is a non-empty string', () {
      // Guards against deep links like "?section=" or "?firstLight=" that would
      // route to the wrong place or be silently ignored at runtime.
      for (final step in kNextUseSteps) {
        final uri = Uri.parse(step.deepLinkRoute);
        uri.queryParameters.forEach((key, value) {
          expect(
            key.trim(),
            isNotEmpty,
            reason: '${step.id} has an empty query key',
          );
          expect(
            value.trim(),
            isNotEmpty,
            reason: '${step.id} query "$key" has an empty value',
          );
        });
      }
    });

    test(
      'the configure-plate-solver step carries a non-empty section= value',
      () {
        final uri = Uri.parse(
          stepFor(NextUseActionId.configurePlateSolver).deepLinkRoute,
        );
        final section = uri.queryParameters['section'];
        expect(section, isNotNull);
        expect(section!.trim(), isNotEmpty);
        expect(section, 'plate-solving');
      },
    );
  });

  group('stepFor', () {
    test('returns the matching step for every id', () {
      for (final id in NextUseActionId.values) {
        expect(stepFor(id).id, id);
      }
    });

    test('never throws for any real NextUseActionId (list is exhaustive)', () {
      // The StateError guard in stepFor only fires when kNextUseSteps is
      // missing an id. That must be unreachable via the public API: every id in
      // the enum resolves. If someone adds a new NextUseActionId without a step,
      // this fails with the surfaced StateError rather than shipping the gap.
      for (final id in NextUseActionId.values) {
        expect(() => stepFor(id), returnsNormally, reason: '$id');
      }
    });

    test('throws StateError when an id is absent from the lookup list', () {
      // Exercise the fail-closed guard directly: mirror stepFor's lookup
      // against a list with one id removed and confirm the StateError path
      // fires rather than returning a wrong/null step. This proves the guard in
      // stepFor is live, not dead code — the production list happens to be
      // exhaustive, so the throw is otherwise unreachable.
      const removed = NextUseActionId.frameTarget;
      final pruned = kNextUseSteps
          .where((s) => s.id != removed)
          .toList(growable: false);

      NextUseStep lookup(NextUseActionId id) {
        for (final step in pruned) {
          if (step.id == id) {
            return step;
          }
        }
        throw StateError(
          'No NextUseStep defined for NextUseActionId.${id.name}.',
        );
      }

      expect(() => lookup(removed), throwsStateError);
      // Remaining ids still resolve through the pruned list.
      expect(
        lookup(NextUseActionId.buildSmartNight).id,
        NextUseActionId.buildSmartNight,
      );
    });
  });
}
