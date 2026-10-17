import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/equipment_profiles_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void swap(SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

class _ProfileSettingsBackendFake implements ProfileSettingsBackend {
  @override
  Future<void> loadProfile(String id) async {}

  @override
  Future<void> saveProfile(EquipmentProfile profile) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('profile import is single-flight and discards an old-host file',
      (tester) async {
    final pick = Completer<XFile?>();
    var pickerCalls = 0;
    var readerCalls = 0;
    var importerCalls = 0;

    final handle = await pumpAppScreen(
      tester,
      const EquipmentProfilesScreen(),
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
        ),
        profileSettingsBackendProvider.overrideWithValue(
          _ProfileSettingsBackendFake(),
        ),
        equipmentProfileImportPickerProvider.overrideWithValue(() {
          pickerCalls++;
          return pick.future;
        }),
        equipmentProfileImportReaderProvider.overrideWithValue((file) async {
          readerCalls++;
          return '{}';
        }),
        equipmentProfileImporterProvider.overrideWithValue((json) async {
          importerCalls++;
          return const [];
        }),
      ],
    );

    await tester.tap(find.byTooltip('Import profiles'));
    await tester.tap(find.byTooltip('Import profiles'));
    await tester.pump();
    expect(pickerCalls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    final backendNotifier = handle.container.read(backendProvider.notifier)
        as _SwappableBackendNotifier;
    backendNotifier.swap(DisconnectedBackend());
    await tester.pump();
    await tester.pumpAndSettle();

    pick.complete(XFile('/old-host-profiles.json'));
    await tester.pump();
    await tester.pump();

    expect(readerCalls, 0);
    expect(importerCalls, 0);
    expect(find.byTooltip('Import profiles'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile import completion after disposal is ignored',
      (tester) async {
    final pick = Completer<XFile?>();
    var readerCalls = 0;
    await pumpAppScreen(
      tester,
      const EquipmentProfilesScreen(),
      extraOverrides: [
        equipmentProfileImportPickerProvider
            .overrideWithValue(() => pick.future),
        equipmentProfileImportReaderProvider.overrideWithValue((file) async {
          readerCalls++;
          return '{}';
        }),
      ],
    );

    await tester.tap(find.byTooltip('Import profiles'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    pick.complete(XFile('/late-profiles.json'));
    await tester.pump();
    await tester.pump();

    expect(readerCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile import reports failures and unlocks retry',
      (tester) async {
    await pumpAppScreen(
      tester,
      const EquipmentProfilesScreen(),
      extraOverrides: [
        equipmentProfileImportPickerProvider.overrideWithValue(
          () async => throw StateError('picker unavailable'),
        ),
      ],
    );

    await tester.tap(find.byTooltip('Import profiles'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('picker unavailable'), findsOneWidget);
    expect(find.byTooltip('Import profiles'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // The screen must hand a rejected import to describeProfileImportFailure,
  // not print the thrown object. Cutting that call at the call site turns this
  // red: a raw ProfileImportException toString has no file name in it.
  testWidgets('a rejected import names the picked file, not a Dart exception',
      (tester) async {
    await pumpAppScreen(
      tester,
      const EquipmentProfilesScreen(),
      extraOverrides: [
        equipmentProfileImportPickerProvider.overrideWithValue(
          () async => XFile('/home/op/m31.nseq.json', name: 'm31.nseq.json'),
        ),
        equipmentProfileImportReaderProvider.overrideWithValue(
          (file) async => '{"name":"M31","nodes":{},"rootNodeId":"r"}',
        ),
        equipmentProfileImporterProvider.overrideWithValue(
          (json) async =>
              profilesFromExportDocument(json).map((e) => 0).toList(),
        ),
      ],
    );

    await tester.tap(find.byTooltip('Import profiles'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('"m31.nseq.json"'), findsOneWidget);
    expect(find.textContaining('Skotiq sequence'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile export is single-flight and stops after a host switch',
      (tester) async {
    final pick = Completer<ExportTarget?>();
    var pickerCalls = 0;
    var exporterCalls = 0;
    var writerCalls = 0;

    final handle = await pumpAppScreen(
      tester,
      const EquipmentProfilesScreen(),
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
        ),
        profileSettingsBackendProvider.overrideWithValue(
          _ProfileSettingsBackendFake(),
        ),
        equipmentProfileExportPickerProvider.overrideWithValue((name) {
          pickerCalls++;
          return pick.future;
        }),
        equipmentProfileExporterProvider.overrideWithValue((profileId) async {
          exporterCalls++;
          return '{"profileId":$profileId}';
        }),
        equipmentProfileExportWriterProvider.overrideWithValue(
          (path, fileName, json) async {
            writerCalls++;
          },
        ),
      ],
    );

    final profiles = handle.container.read(equipmentProfilesProvider.notifier);
    final profileId = await profiles.createProfile(name: 'Exportable profile');
    await profiles.setActiveProfile(profileId);
    await tester.pumpAndSettle();
    await tester.pump();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export'));
    await tester.pump();
    expect(pickerCalls, 1);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export'));
    await tester.pump();
    expect(pickerCalls, 1);

    final backendNotifier = handle.container.read(backendProvider.notifier)
        as _SwappableBackendNotifier;
    backendNotifier.swap(DisconnectedBackend());
    await tester.pump();

    pick.complete(
      const ExportTarget(
        path: '/tmp/old-host-profile.json',
        needsShareSheet: false,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(exporterCalls, 0);
    expect(writerCalls, 0);
    expect(tester.takeException(), isNull);
  });
}
