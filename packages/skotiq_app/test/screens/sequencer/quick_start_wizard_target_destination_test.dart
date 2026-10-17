// The Quick-Start Wizard's "your library is empty" branch used to send the
// operator to "Sky or Planner". Neither is a destination in this build: the
// rail reads "Plan Tonight", and the control that writes a library row is the
// Add-target action on its Projects tab. Copy that names a place the operator
// cannot find is a dead end at the exact moment they are stuck.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/screens/sequencer/widgets/quick_start_wizard_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _AppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

class _ProfilesNotifier extends EquipmentProfilesNotifier {
  @override
  Future<EquipmentProfilesState> build() async =>
      const EquipmentProfilesState(profiles: [], activeProfile: null);
}

class _WizardHost extends StatelessWidget {
  const _WizardHost();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const QuickStartWizardDialog(),
          ),
          child: const Text('Open wizard'),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('empty target library points at a destination that exists',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(_AppSettingsNotifier.new),
          equipmentProfilesProvider.overrideWith(_ProfilesNotifier.new),
          smartNightExposureContextProvider.overrideWith((ref) async => null),
          // Nothing has ever been saved: this is the branch under test.
          allDbTargetsProvider.overrideWith(
            (ref) => Stream<List<DbTarget>>.value(const []),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const _WizardHost(),
        ),
      ),
    );
    await tester.tap(find.text('Open wizard'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Target Name'),
      'M31',
    );
    // 300 ms search debounce, then the DAO lookup + the "is the library empty
    // at all?" follow-up.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Sky or Planner'),
      findsNothing,
      reason: 'neither "Sky" nor "Planner" is a destination in this build',
    );
    expect(
      find.textContaining('Plan tonight'),
      findsOneWidget,
      reason: 'the empty-library branch must name the real screen that saves '
          'a target into the library',
    );
  });
}
