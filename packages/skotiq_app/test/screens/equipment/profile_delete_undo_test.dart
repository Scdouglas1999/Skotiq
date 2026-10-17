// Deleting a profile must say what actually happens, and the Undo it offers
// must actually work.
//
// Two live findings, one flow:
//   * the confirmation read 'Delete "My First Rig"? This cannot be undone.'
//     and then raised a snackbar with a working Undo;
//   * that Undo was a State method guarded by `mounted`, so pressing it after
//     navigating away from Equipment — which is easy, the bar lives in the app
//     ScaffoldMessenger and follows you — aborted silently: no restore, no
//     error, the row stayed deleted.

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
  telescopeName: 'Sky-Watcher Esprit 100ED',
  cameraName: 'Simulated Camera',
  isActive: true,
);

/// Swaps the Equipment screen out for another screen on demand — the state
/// change that disposes the screen while the undo snackbar is still up.
class _NavigationHarness extends StatefulWidget {
  const _NavigationHarness();

  @override
  State<_NavigationHarness> createState() => _NavigationHarnessState();
}

class _NavigationHarnessState extends State<_NavigationHarness> {
  bool _onEquipment = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _onEquipment
          ? const EquipmentScreen()
          : const Center(child: Text('Dashboard')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _onEquipment = false),
        child: const Icon(Icons.arrow_forward),
      ),
    );
  }
}

class _Harness {
  _Harness(this.backend, this.saved);
  final _MockNetworkBackend backend;
  final List<EquipmentProfile> saved;
}

Future<_Harness> _pumpEquipment(WidgetTester tester) async {
  final database = mockDatabase();
  addTearDown(database.close);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1600, 1200);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final backend = _MockNetworkBackend();
  final saved = <EquipmentProfile>[];
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
  when(() => backend.saveProfile(any())).thenAnswer((invocation) async {
    saved.add(invocation.positionalArguments.first as EquipmentProfile);
    deleted = false;
  });
  when(() => backend.lastSavedProfileId).thenReturn('7');
  when(() => backend.loadProfile(any())).thenAnswer((_) async {});

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
      child: const MaterialApp(home: _NavigationHarness()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return _Harness(backend, saved);
}

Future<void> _openDeleteConfirmation(WidgetTester tester) async {
  await tester.longPress(find.text('My First Rig').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Delete').first);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    registerFallbackValue(
      const EquipmentProfile(id: 'fallback', name: 'fallback'),
    );
  });

  testWidgets('the confirmation describes the undo instead of denying it',
      (tester) async {
    await _pumpEquipment(tester);
    await _openDeleteConfirmation(tester);

    expect(
      find.textContaining('cannot be undone'),
      findsNothing,
      reason: 'the delete raises a working Undo — saying otherwise is a lie',
    );
    expect(find.textContaining('undo this'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('Sky-Watcher Esprit 100ED'),
      ),
      findsOneWidget,
      reason: 'two profiles can share a name, so name alone cannot identify '
          'which rig is about to be destroyed',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('Undo still restores after leaving the Equipment screen',
      (tester) async {
    final harness = await _pumpEquipment(tester);
    await _openDeleteConfirmation(tester);
    await tester.tap(find.widgetWithText(SkotiqButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Undo'), findsOneWidget);

    // Walk away. The snackbar follows (it lives in the app messenger), so the
    // offer is still on screen with the Equipment screen disposed.
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(
      harness.saved.map((p) => p.name),
      contains('My First Rig'),
      reason: 'an Undo that silently does nothing is worse than no Undo',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}
