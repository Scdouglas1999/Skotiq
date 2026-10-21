// The Quick Start wizard's target search finds catalog objects by name, not
// only targets already saved in the library.
//
// It used to search the library alone with SQL LIKE '%q%', so on a fresh
// install (an empty library) "M42" found nothing and the step said so. It now
// ranks the installed catalog with the same resolver Framing uses (exact
// designations and names first), lists saved targets beside it, and sends a
// name nothing local knows to SIMBAD's exact resolver.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/quick_start_wizard_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show CelestialCoordinate, DeepSkyObject, DsoType, loadedDsosProvider;
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

/// OpenNGC's row for M42, as the catalog loader builds it.
const _ngc1976 = DeepSkyObject(
  id: 'NGC1976',
  name: 'M42',
  coordinates: CelestialCoordinate(ra: 5.587911, dec: -5.389667),
  type: DsoType.clusterWithNebulosity,
  magnitude: 4.0,
  catalogIds: ['LBN 974', 'M42'],
  commonNames: 'Great Orion Nebula,Orion Nebula',
);

/// Carries "M42" inside a cross-identifier and is brighter than M42, so
/// substring matching or magnitude order alone would put it first.
const _trap = DeepSkyObject(
  id: 'NGC9998',
  name: 'NGC9998',
  coordinates: CelestialCoordinate(ra: 7.968, dec: -60.753),
  type: DsoType.openCluster,
  magnitude: 3.8,
  catalogIds: ['Cl* NGC 2516 HTR M42'],
);

class _FakeSesame extends SesameNameResolver {
  _FakeSesame(this.answers);

  final Map<String, ResolvedTargetName> answers;
  final asked = <String>[];

  @override
  Future<ResolvedTargetName?> resolve(String name) async {
    asked.add(name);
    return answers[name];
  }
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

  late _FakeSesame sesame;

  Future<void> openWizard(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    sesame = _FakeSesame({
      'Sh2-129': const ResolvedTargetName(
        mainId: 'SH 2-129',
        raHours: 21.196667,
        decDegrees: 59.95,
        objectType: 'HII',
      ),
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(_AppSettingsNotifier.new),
          equipmentProfilesProvider.overrideWith(_ProfilesNotifier.new),
          smartNightExposureContextProvider.overrideWith((ref) async => null),
          loadedDsosProvider.overrideWith((ref) async => [_trap, _ngc1976]),
          sesameNameResolverProvider.overrideWithValue(sesame),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const _WizardHost(),
        ),
      ),
    );
    await tester.tap(find.text('Open wizard'));
    await tester.pumpAndSettle();
  }

  Finder nameField() => find.widgetWithText(TextField, 'Target Name');

  Future<void> typeName(WidgetTester tester, String text) async {
    await tester.enterText(nameField(), text);
    // 300 ms debounce, then the catalog rank and the library query.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  Future<void> pressEnter(WidgetTester tester) async {
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
  }

  testWidgets('M42 on an empty library lists the catalog object first',
      (tester) async {
    await openWizard(tester);
    await typeName(tester, 'M42');

    final rows = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(rows, isNotEmpty);
    expect((rows.first.title! as Text).data, 'M42');
    expect(find.textContaining('library is empty'), findsNothing);
  });

  testWidgets('saved targets are listed beside the catalog object',
      (tester) async {
    await openWizard(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(QuickStartWizardDialog)),
    );
    await tester.runAsync(
      () => container.read(targetsDaoProvider).createTarget(
            TargetsCompanion.insert(
              name: 'Orion mosaic',
              catalogId: const Value('M42'),
              ra: 5.6,
              dec: -5.0,
            ),
          ),
    );
    await typeName(tester, 'M42');

    final titles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((row) => (row.title! as Text).data)
        .toList();
    expect(titles.take(2), ['M42', 'Orion mosaic']);
    expect(find.textContaining('Saved · M42'), findsOneWidget);
  });

  testWidgets('Enter selects the one object the name designates',
      (tester) async {
    await openWizard(tester);
    await typeName(tester, 'm 42');
    await pressEnter(tester);

    expect(find.textContaining('Selected: M42'), findsOneWidget);
    expect(sesame.asked, isEmpty, reason: 'the catalog named it exactly');
    final ra = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Right Ascension'),
    );
    expect(ra.controller!.text, startsWith('5h 35m'));
  });

  testWidgets('a name the catalog lacks goes to SIMBAD by exact name',
      (tester) async {
    await openWizard(tester);
    await typeName(tester, 'Sh2-129');
    expect(find.text('Look up on SIMBAD'), findsOneWidget);
    await pressEnter(tester);

    expect(sesame.asked, ['Sh2-129']);
    expect(find.textContaining('Selected: SH 2-129'), findsOneWidget);
  });

  testWidgets('a name SIMBAD does not know selects nothing and says so',
      (tester) async {
    await openWizard(tester);
    await typeName(tester, 'Nonexistent 77');
    await tester.tap(find.text('Look up on SIMBAD'));
    await tester.pumpAndSettle();

    expect(sesame.asked, ['Nonexistent 77']);
    expect(find.textContaining('SIMBAD has no object named'), findsOneWidget);
    expect(find.textContaining('Selected:'), findsNothing);
  });

  testWidgets('renaming after a pick drops the picked coordinates',
      (tester) async {
    await openWizard(tester);
    await typeName(tester, 'M42');
    await pressEnter(tester);
    expect(find.textContaining('Selected: M42'), findsOneWidget);

    await typeName(tester, 'M31');
    expect(find.textContaining('Selected:'), findsNothing);
    final ra = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Right Ascension'),
    );
    expect(ra.controller!.text, isEmpty);
  });
}
