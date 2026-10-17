// A validation message must not outlive the state that produced it.
//
// In Your Sky > Name a region the "From a target" mode says "No targets in your
// library yet — switch to Custom to enter a sky position by hand". Pressing an
// enabled Create region there produces the red "Pick a target first.", and if
// that error survives the switch to Custom RA/Dec — doing exactly what the sheet
// asked — it stays on screen while RA, Dec and a name are filled in, right up to
// a successful create, telling the user to do something the current mode does
// not offer.
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
    child: const MaterialApp(
      home: Scaffold(body: NameRegionSheet()),
    ),
  );
}

/// The error the custom-coordinate branch raises; reachable by hand, unlike the
/// target branch which is now blocked before it can fail.
const _rangeError =
    'Enter RA as 05h 35m 16s or 83.82°, Dec from -90° to +90°, and a radius '
    'greater than 0° and no more than 180°.';

Future<void> _raiseRangeError(WidgetTester tester) async {
  await tester.tap(find.text('Custom RA/Dec'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).at(0), '999');
  await tester.pumpAndSettle();
  await tester.tap(find.text('Create region'));
  await tester.pumpAndSettle();
  expect(find.textContaining('Enter RA as'), findsOneWidget);
}

void main() {
  testWidgets('Create region is not offered when there is no target to pick',
      (tester) async {
    await tester.pumpWidget(_surface());
    await tester.pumpAndSettle();

    // "From a target" is the default mode and the library is empty.
    expect(
        find.textContaining('No targets in your library yet'), findsOneWidget);

    // A PRESENT-but-disabled `Create region` never reaches the user: the
    // accessibility tree reports the dim button as a plain actionable one and
    // clicking it does nothing at all. So the action is absent in this state and
    // the slot carries a live control instead — see
    // `name_region_sheet_dead_action_test.dart`.
    expect(find.text('Create region'), findsNothing);
    expect(find.text('Switch to Custom RA/Dec'), findsOneWidget);
    expect(find.text('Pick a target first.'), findsNothing);
  });

  testWidgets('switching mode clears the error the other mode raised',
      (tester) async {
    await tester.pumpWidget(_surface());
    await tester.pumpAndSettle();

    await _raiseRangeError(tester);

    await tester.tap(find.text('From a target'));
    await tester.pumpAndSettle();

    expect(find.text(_rangeError), findsNothing);
    expect(find.textContaining('Enter RA as'), findsNothing);
  });

  testWidgets('editing a field clears the error', (tester) async {
    await tester.pumpWidget(_surface());
    await tester.pumpAndSettle();

    await _raiseRangeError(tester);

    await tester.enterText(find.byType(TextField).at(0), '283.4');
    await tester.pumpAndSettle();

    expect(find.textContaining('Enter RA as'), findsNothing);
  });
}
