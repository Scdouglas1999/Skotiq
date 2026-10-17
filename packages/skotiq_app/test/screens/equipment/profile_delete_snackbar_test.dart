// The "Deleted <profile>" undo snackbar must let go of the status bar.
//
// While it is up the full-width snackbar covers the entire status bar (profile,
// device connection states, focuser position, temperature, clock, LST), and it
// has no close affordance, so it can sit there for minutes across several screen
// changes. A `duration: 6 s` does not dismiss it: Flutter 3.44's SnackBar
// constructor defaults `persist` to `action != null`, and ScaffoldMessenger's
// timer returns without hiding when that is set.
//
// The test drives the real delete flow through the real screen, so removing
// `persist: false` from the call site fails it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _StubBackendNotifier extends BackendNotifier {
  _StubBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

const _profile = EquipmentProfile(
  id: '7',
  name: 'My First Rig',
  description: 'Host-owned profile',
  isActive: true,
);

Future<void> _pumpEquipment(
  WidgetTester tester,
  _MockNetworkBackend backend,
) async {
  final database = mockDatabase();
  addTearDown(database.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // The profile list is the Profiles tab now (06 §Equipment).
        equipmentTabIndexProvider.overrideWith((ref) => 1),
        backendProvider
            .overrideWith((ref) => _StubBackendNotifier(ref, backend)),
        databaseProvider.overrideWithValue(database),
        selectedEquipmentProfileIdProvider.overrideWith((ref) => 7),
        activeProfileProvider.overrideWith((ref) => Stream.value(null)),
        allProfilesProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: const MaterialApp(
        home: Scaffold(body: EquipmentScreen()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _deleteProfile(WidgetTester tester) async {
  await tester.longPress(find.text('My First Rig').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Delete').first);
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(SkotiqButton, 'Delete'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    registerFallbackValue(
      const EquipmentProfile(id: 'fallback', name: 'fallback'),
    );
  });

  _MockNetworkBackend buildBackend() {
    final backend = _MockNetworkBackend();
    var deleted = false;
    when(() => backend.eventStream)
        .thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.getActiveProfile())
        .thenAnswer((_) async => deleted ? null : _profile);
    when(() => backend.getProfiles())
        .thenAnswer((_) async => deleted ? const [] : const [_profile]);
    when(() => backend.deleteProfile('7')).thenAnswer((_) async {
      deleted = true;
    });
    return backend;
  }

  testWidgets('the undo snackbar clears itself and gives the status bar back',
      (tester) async {
    await _pumpEquipment(tester, buildBackend());
    await _deleteProfile(tester);

    expect(find.text('Undo'), findsOneWidget);

    // Still there mid-window: the undo offer is real, not a flash.
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Undo'), findsOneWidget);

    // Past the declared 6 s duration it must be gone without any interaction.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.text('Undo'),
      findsNothing,
      reason: 'a bar that never times out hides the status bar until restart',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('the undo snackbar can be dismissed by hand', (tester) async {
    await _pumpEquipment(tester, buildBackend());
    await _deleteProfile(tester);

    final closeButton = find.descendant(
      of: find.byType(SnackBar),
      matching: find.byIcon(Icons.close),
    );
    expect(
      closeButton,
      findsOneWidget,
      reason: 'waiting out the timer is not a dismissal affordance',
    );

    await tester.tap(closeButton);
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
