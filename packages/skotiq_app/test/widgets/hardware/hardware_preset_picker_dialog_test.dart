// Widget tests for the hardware-preset picker dialog (C10).
//
// Drives the picker against real Riverpod providers backed by an in-memory
// Drift database (no mocks), proving: built-in presets render with their badge
// and spec line, search filters the list, tapping a row returns the preset via
// Navigator.pop, and built-ins expose no delete affordance (they are immutable).
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/widgets/hardware/hardware_preset_picker_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/providers/hardware_presets_provider.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

SkotiqDatabase _newDb() =>
    SkotiqDatabase.forTesting(NativeDatabase.memory());

Future<ProviderContainer> _pumpHost(
  WidgetTester tester, {
  required SkotiqDatabase db,
  required Future<Object?> Function(BuildContext context) open,
  required void Function(Object? result) onResult,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return Center(
                child: ElevatedButton(
                  onPressed: () async {
                    final result = await open(context);
                    onResult(result);
                  },
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
  // Let the hardware-presets notifier finish hydrating its (empty) overrides.
  await container.read(hardwarePresetsServiceProvider.notifier).loaded;
  await tester.pump();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('telescope library lists built-ins with badge and spec line',
      (tester) async {
    final db = _newDb();
    addTearDown(db.close);

    await _pumpHost(
      tester,
      db: db,
      open: HardwarePresetPickerDialog.showTelescope,
      onResult: (_) {},
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Telescope library'), findsOneWidget);
    expect(find.text('Sky-Watcher Esprit 100ED'), findsOneWidget);
    // Built-in badge appears on catalog rows.
    expect(find.text('Built-in'), findsWidgets);
    // Spec line is rendered in the mono style: "550mm f/5.5 · 100mm refractor".
    expect(
      find.textContaining('550mm f/5.5'),
      findsOneWidget,
    );
  });

  testWidgets('search narrows the telescope list', (tester) async {
    final db = _newDb();
    addTearDown(db.close);

    await _pumpHost(
      tester,
      db: db,
      open: HardwarePresetPickerDialog.showTelescope,
      onResult: (_) {},
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Search by brand or model…'),
      'redcat',
    );
    await tester.pumpAndSettle();

    expect(find.text('William Optics RedCat 51'), findsOneWidget);
    expect(find.text('Sky-Watcher Esprit 100ED'), findsNothing);
  });

  testWidgets('tapping a telescope row returns it via Navigator.pop',
      (tester) async {
    final db = _newDb();
    addTearDown(db.close);
    Object? result;

    await _pumpHost(
      tester,
      db: db,
      open: HardwarePresetPickerDialog.showTelescope,
      onResult: (r) => result = r,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('William Optics RedCat 51'));
    await tester.pumpAndSettle();

    expect(result, isA<TelescopePreset>());
    expect((result as TelescopePreset).id, 'tel.williamoptics.redcat51');
  });

  testWidgets('built-in rows expose edit but not delete', (tester) async {
    final db = _newDb();
    addTearDown(db.close);

    await _pumpHost(
      tester,
      db: db,
      open: HardwarePresetPickerDialog.showTelescope,
      onResult: (_) {},
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Built-ins are immutable: no trash affordance is rendered for any row in
    // a fresh (overrides-empty) library.
    expect(find.byIcon(LucideIcons.trash2), findsNothing);
    // Every row offers an edit pencil (built-ins open a copy-to-edit flow).
    expect(find.byIcon(LucideIcons.pencil), findsWidgets);
  });

  testWidgets('camera library renders the camera spec line', (tester) async {
    final db = _newDb();
    addTearDown(db.close);

    await _pumpHost(
      tester,
      db: db,
      open: HardwarePresetPickerDialog.showCamera,
      onResult: (_) {},
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Camera library'), findsOneWidget);
    expect(find.text('ZWO ASI2600MM Pro'), findsOneWidget);
    // "3.76µm · Sony IMX571 mono · 6248×4176"
    expect(
      find.textContaining('3.76µm · Sony IMX571 mono · 6248×4176'),
      findsOneWidget,
    );
  });
}
