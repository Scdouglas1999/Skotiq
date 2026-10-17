import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void swap(SkotiqBackend backend) => state = backend;
}

const _source = EquipmentProfile(
  id: '7',
  name: 'Remote Rig',
  description: 'Host-owned profile',
  isActive: true,
);

Future<
    ({
      _SwappableBackendNotifier backendNotifier,
      int? Function() selectedProfileId,
      void Function(int?) setSelectedProfileId,
    })> _pumpEquipment(
  WidgetTester tester,
  _MockNetworkBackend backend,
) async {
  final database = mockDatabase();
  addTearDown(database.close);
  late _SwappableBackendNotifier backendNotifier;
  StateController<int?>? selectedController;
  int? selectedProfileId;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // The profile list is the Profiles tab now (06 §Equipment).
        equipmentTabIndexProvider.overrideWith((ref) => 1),
        backendProvider.overrideWith((ref) {
          backendNotifier = _SwappableBackendNotifier(ref, backend);
          return backendNotifier;
        }),
        databaseProvider.overrideWithValue(database),
        selectedEquipmentProfileIdProvider.overrideWith((ref) => 7),
        activeProfileProvider.overrideWith((ref) => Stream.value(null)),
        allProfilesProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Stack(
            children: [
              const EquipmentScreen(),
              Consumer(
                builder: (context, ref, child) {
                  selectedProfileId =
                      ref.watch(selectedEquipmentProfileIdProvider);
                  selectedController =
                      ref.read(selectedEquipmentProfileIdProvider.notifier);
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return (
    backendNotifier: backendNotifier,
    selectedProfileId: () => selectedProfileId,
    setSelectedProfileId: (id) => selectedController!.state = id,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(
      const EquipmentProfile(id: 'fallback', name: 'fallback'),
    );
  });

  testWidgets('equipment duplicate writes to the remote host', (tester) async {
    final backend = _MockNetworkBackend();
    var duplicated = false;
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.getActiveProfile()).thenAnswer((_) async => _source);
    when(() => backend.getProfiles()).thenAnswer(
      (_) async => [
        _source,
        if (duplicated)
          const EquipmentProfile(id: '8', name: 'Remote Rig (Copy)'),
      ],
    );
    when(() => backend.saveProfile(any())).thenAnswer((invocation) async {
      duplicated = true;
    });

    await _pumpEquipment(tester, backend);
    expect(find.text('Remote Rig'), findsWidgets);

    await tester.longPress(find.text('Remote Rig').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();

    final saved = verify(() => backend.saveProfile(captureAny()))
        .captured
        .single as EquipmentProfile;
    expect(saved.id, isEmpty);
    expect(saved.name, 'Remote Rig (Copy)');
  });

  testWidgets('equipment delete and undo stay on the remote host',
      (tester) async {
    final backend = _MockNetworkBackend();
    var deleted = false;
    var restored = false;
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.getActiveProfile()).thenAnswer(
      (_) async => deleted && !restored ? null : _source,
    );
    when(() => backend.getProfiles()).thenAnswer(
      (_) async => deleted && !restored ? const [] : const [_source],
    );
    when(() => backend.deleteProfile('7')).thenAnswer((_) async {
      deleted = true;
    });
    when(() => backend.lastSavedProfileId).thenReturn('9');
    when(() => backend.saveProfile(any())).thenAnswer((_) async {
      restored = true;
    });
    when(() => backend.loadProfile('9')).thenAnswer((_) async {});

    await _pumpEquipment(tester, backend);
    await tester.longPress(find.text('Remote Rig').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Delete'));
    await tester.pumpAndSettle();

    verify(() => backend.deleteProfile('7')).called(1);
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    final restoredProfile = verify(() => backend.saveProfile(captureAny()))
        .captured
        .single as EquipmentProfile;
    expect(restoredProfile.id, isEmpty);
    expect(restoredProfile.name, _source.name);
    expect(restoredProfile.description, _source.description);
    verify(() => backend.loadProfile('9')).called(1);
  });

  testWidgets('an old-host duplicate cannot select a profile on the new host',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final save = Completer<void>();

    when(() => hostA.eventStream)
        .thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => hostA.getActiveProfile()).thenAnswer((_) async => _source);
    when(() => hostA.getProfiles()).thenAnswer((_) async => const [_source]);
    when(() => hostA.saveProfile(any())).thenAnswer((_) => save.future);

    const hostBProfile = EquipmentProfile(
      id: '20',
      name: 'New host rig',
      isActive: true,
    );
    when(() => hostB.eventStream)
        .thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => hostB.getActiveProfile()).thenAnswer((_) async => hostBProfile);
    when(() => hostB.getProfiles())
        .thenAnswer((_) async => const [hostBProfile]);

    final harness = await _pumpEquipment(tester, hostA);
    await tester.longPress(find.text('Remote Rig').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate'));
    await tester.pump();
    verify(() => hostA.saveProfile(any())).called(1);

    harness.backendNotifier.swap(hostB);
    harness.setSelectedProfileId(20);
    await tester.pump();
    await tester.pump();

    save.complete();
    await tester.pump();
    await tester.pump();

    expect(harness.selectedProfileId(), 20);
    expect(find.text('New host rig'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
