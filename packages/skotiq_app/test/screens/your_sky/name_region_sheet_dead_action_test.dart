// "Create region" must never be a control that cannot work.
//
// On a fresh profile with an empty target library, Your Sky -> Name a region
// with the mode left on "From a target" reports `button: Create region` with NO
// [DISABLED] state, and clicking it leaves the dialog open with no error text,
// no toast and no new node anywhere in the tree.
//
// Dimming the button does not reach the user: the only signals a screen reader
// or an automated driver gets both say "actionable", and the click does nothing.
// So in the one state where the mode can never succeed, the sheet does not offer
// that action at all — it offers the escape hatch its own empty-state copy
// names, and that control is live.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/your_sky/widgets/name_region_sheet.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

Widget _surface({List<DbTarget> targets = const []}) {
  return ProviderScope(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, _MockNetworkBackend()),
      ),
      allDbTargetsProvider.overrideWith((ref) => Stream.value(targets)),
    ],
    child: const MaterialApp(home: Scaffold(body: NameRegionSheet())),
  );
}

void main() {
  testWidgets(
    'an empty library offers no "Create region" control at all',
    (tester) async {
      await tester.pumpWidget(_surface());
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No targets in your library yet'),
        findsOneWidget,
        reason: 'this is the state the live drive was in',
      );
      expect(
        find.text('Create region'),
        findsNothing,
        reason: 'a dead primary action is what the live tree mis-reported as '
            'actionable',
      );
    },
  );

  testWidgets(
    'the primary action an empty library DOES offer actually does something',
    (tester) async {
      await tester.pumpWidget(_surface());
      await tester.pumpAndSettle();

      // The exact counter-input the re-drive used: press the primary action
      // and look for any visible consequence.
      await tester.tap(find.text('Switch to Custom RA/Dec'));
      await tester.pumpAndSettle();

      // Custom mode is now live: the coordinate fields and their interpretation
      // line exist, and the create action is offered again because it can now
      // succeed.
      expect(find.text('RA'), findsOneWidget);
      expect(find.text('Dec'), findsOneWidget);
      expect(find.text('Radius (degrees)'), findsOneWidget);
      expect(find.text('Create region'), findsOneWidget);
    },
  );

  testWidgets(
    'with targets present but none picked the blocked action says why',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _surface(
          targets: [
            DbTarget(
              id: 1,
              name: 'M31',
              ra: 0.712,
              dec: 41.27,
              minAltitude: 30,
              priority: 0,
              totalPlannedSubs: 0,
              capturedSubs: 0,
              totalIntegrationSecs: 0,
              goalIntegrationSecs: 0,
              createdAt: DateTime.utc(2026, 8, 13),
              updatedAt: DateTime.utc(2026, 8, 13),
              isFavorite: false,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Create region'), findsOneWidget);
      final node = tester.getSemantics(find.text('Create region'));
      expect(
        node.hint,
        contains('Choose a target'),
        reason: 'dimming carries no reason; the node has to state it',
      );
      handle.dispose();
    },
  );
}
