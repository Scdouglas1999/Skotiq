// On a client linked to a host, turning the Default profile switch off and
// saving has to clear the host's startup profile. The host keeps a saved
// row's default flag, so the save alone leaves it set.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/dialogs/profile_editor_dialog.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

const _hosted = EquipmentProfile(
  id: '7',
  name: 'Remote Rig',
  telescopeName: 'Esprit 100',
  isActive: true,
  isDefault: true,
);

void main() {
  setUpAll(() {
    registerFallbackValue(
      const EquipmentProfile(id: 'fallback', name: 'fallback'),
    );
  });

  testWidgets('turning Default off on a linked client clears the host default',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.eventStream)
        .thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.getProfiles()).thenAnswer((_) async => [_hosted]);
    when(() => backend.getActiveProfile()).thenAnswer((_) async => _hosted);
    when(() => backend.saveProfileFields(any(), fields: any(named: 'fields')))
        .thenAnswer((_) async {});
    when(() => backend.lastSavedProfileId).thenReturn('7');
    when(() => backend.clearDefaultProfileRemote()).thenAnswer((_) async {});
    final database = mockDatabase();
    addTearDown(database.close);

    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final profile = EquipmentProfileModel.fromRemoteProfile(_hosted);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: ProfileEditorDialog(
              profile: profile,
              mode: ProfileEditorMode.profilePage,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final defaultSwitch = find.descendant(
      of: find.widgetWithText(SkotiqSwitchRow, 'Default profile'),
      matching: find.byType(SkotiqSwitch),
    );
    await tester.ensureVisible(defaultSwitch);
    await tester.tap(defaultSwitch);
    await tester.pump();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Save changes'));
    await tester.pumpAndSettle();

    verify(() => backend.clearDefaultProfileRemote()).called(1);
    verifyNever(() => backend.setDefaultProfileRemote(any()));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
