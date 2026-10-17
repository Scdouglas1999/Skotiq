// Widget tests for the hardware-preset editor dialog (C10).
//
// Drives the editor end-to-end against real Riverpod providers backed by an
// in-memory Drift database (no mocks), proving: required-numeric validation
// surfaces inline errors, a valid telescope/camera persists and is returned via
// Navigator.pop, and editing a built-in produces a user override (isBuiltIn
// false, same id) so the catalog stays pristine.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/hardware/hardware_preset_editor_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/providers/hardware_presets_provider.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

SkotiqDatabase _newDb() =>
    SkotiqDatabase.forTesting(NativeDatabase.memory());

/// Pumps a host with a button that opens the editor and captures the result.
/// Returns the [ProviderContainer] backing the scope, after the hardware-
/// presets notifier has finished hydrating its (empty) overrides — so a save
/// cannot race a late `_load()` that would otherwise wipe the override.
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
  await container.read(hardwarePresetsServiceProvider.notifier).loaded;
  await tester.pump();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('telescope mode', () {
    testWidgets('rejects empty required numerics with inline errors',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      Object? result = 'unset';

      await _pumpHost(
        tester,
        db: db,
        open: (context) => HardwarePresetEditorDialog.editTelescope(context),
        onResult: (r) => result = r,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Fill brand/model but leave focal length and aperture empty.
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. Sky-Watcher'), 'Acme');
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. Esprit 100ED'), 'Scope');

      await tester.tap(find.widgetWithText(SkotiqButton, 'Add'));
      await tester.pumpAndSettle();

      // Dialog stays open with validation errors; nothing was returned.
      expect(find.text('Enter a valid number'), findsNWidgets(2));
      expect(result, 'unset');
    });

    testWidgets('saves a valid telescope and returns it', (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      Object? result = 'unset';

      await _pumpHost(
        tester,
        db: db,
        open: (context) => HardwarePresetEditorDialog.editTelescope(context),
        onResult: (r) => result = r,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. Sky-Watcher'), 'Acme');
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. Esprit 100ED'), 'TenInch');
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. 550'), '1000');
      await tester.enterText(find.widgetWithText(TextField, 'e.g. 100'), '200');

      await tester.tap(find.widgetWithText(SkotiqButton, 'Add'));
      await tester.pumpAndSettle();

      expect(result, isA<TelescopePreset>());
      final saved = result as TelescopePreset;
      expect(saved.brand, 'Acme');
      expect(saved.model, 'TenInch');
      expect(saved.focalLengthMm, 1000);
      expect(saved.apertureMm, 200);
      expect(saved.isBuiltIn, isFalse);
      expect(saved.focalRatio, closeTo(5.0, 1e-9));
    });

    // Validating optics only against `> 0` lets a custom telescope preset carry
    // 999999999 mm at 0.0001 mm (f/9999999990000). A preset prefills the
    // equipment profile editor and drives the planetarium FOV overlay, so it
    // needs the same bounds a profile has.
    testWidgets('rejects an implausible focal length / aperture pair',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      Object? result = 'unset';

      await _pumpHost(
        tester,
        db: db,
        open: (context) => HardwarePresetEditorDialog.editTelescope(context),
        onResult: (r) => result = r,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. Sky-Watcher'), 'Acme');
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. Esprit 100ED'), 'Absurd');
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. 550'), '999999999');
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. 100'), '0.0001');

      await tester.tap(find.widgetWithText(SkotiqButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text('Focal length must be between 1 and 50000 mm'),
          findsOneWidget);
      expect(
          find.text('Aperture must be between 1 and 5000 mm'), findsOneWidget);
      expect(result, 'unset', reason: 'nothing may be persisted or returned');
    });

    testWidgets('rejects an impossible f-ratio built from in-range fields',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      Object? result = 'unset';

      await _pumpHost(
        tester,
        db: db,
        open: (context) => HardwarePresetEditorDialog.editTelescope(context),
        onResult: (r) => result = r,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. Sky-Watcher'), 'Acme');
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. Esprit 100ED'), 'Ratio');
      // Both numbers are individually in range; only f/20000 is impossible.
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. 550'), '40000');
      await tester.enterText(find.widgetWithText(TextField, 'e.g. 100'), '2');

      await tester.tap(find.widgetWithText(SkotiqButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.textContaining('f/20000'), findsOneWidget);
      expect(result, 'unset');
    });

    testWidgets('editing a built-in stores a user override under its id',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      Object? result;

      const builtIn = TelescopePreset(
        id: 'tel.skywatcher.esprit100ed',
        brand: 'Sky-Watcher',
        model: 'Esprit 100ED',
        focalLengthMm: 550,
        apertureMm: 100,
        design: OpticalDesign.refractor,
        nativeFocalRatio: 5.5,
        isBuiltIn: true,
      );

      final container = await _pumpHost(
        tester,
        db: db,
        open: (context) => HardwarePresetEditorDialog.editTelescope(
          context,
          initial: builtIn,
        ),
        onResult: (r) => result = r,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The built-in notice is shown.
      expect(find.byType(SkotiqInlineBanner), findsOneWidget);

      // Change the model and save.
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. Esprit 100ED'),
          'Esprit 100ED (mine)');
      await tester.tap(find.widgetWithText(SkotiqButton, 'Save'));
      await tester.pumpAndSettle();

      final saved = result as TelescopePreset;
      expect(saved.id, 'tel.skywatcher.esprit100ed');
      expect(saved.isBuiltIn, isFalse);
      expect(saved.model, 'Esprit 100ED (mine)');

      // The merged catalog now shows exactly one entry for that id, and it is
      // the user override (not built-in) — the catalog stayed pristine.
      final service = container.read(hardwarePresetsServiceProvider);
      final matches = service
          .allTelescopes()
          .where((p) => p.id == 'tel.skywatcher.esprit100ed')
          .toList();
      expect(matches, hasLength(1));
      expect(matches.single.isBuiltIn, isFalse);
      expect(matches.single.model, 'Esprit 100ED (mine)');
    });
  });

  group('camera mode', () {
    testWidgets('saves a valid camera with cooling toggled off',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      Object? result;

      await _pumpHost(
        tester,
        db: db,
        open: (context) => HardwarePresetEditorDialog.editCamera(context),
        onResult: (r) => result = r,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. ZWO'), 'TestCam Co');
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. ASI2600MM Pro'), 'TC-1');
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. 3.76'), '3.76');
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. Sony IMX571'), 'TestSensor');
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. 6248'), '6000');
      await tester.enterText(
          find.widgetWithText(TextField, 'e.g. 4176'), '4000');
      await tester.enterText(find.widgetWithText(TextField, 'e.g. 100'), '100');
      await tester.enterText(find.widgetWithText(TextField, 'e.g. 50'), '25');

      await tester.tap(find.widgetWithText(SkotiqButton, 'Add'));
      await tester.pumpAndSettle();

      expect(result, isA<CameraDefaultsPreset>());
      final saved = result as CameraDefaultsPreset;
      expect(saved.brand, 'TestCam Co');
      expect(saved.pixelSizeMicrons, 3.76);
      expect(saved.sensorWidthPx, 6000);
      expect(saved.sensorHeightPx, 4000);
      expect(saved.sensorName, 'TestSensor');
      expect(saved.recommendedGain, 100);
      expect(saved.recommendedOffset, 25);
      // Cooling defaults off for a fresh camera, so the set-point stays null
      // rather than collapsing to 0 °C.
      expect(saved.recommendedCoolingTempC, isNull);
      expect(saved.isBuiltIn, isFalse);
    });
  });
}
