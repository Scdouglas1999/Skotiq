import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/widgets/camera_sensor_specs_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// What the chain resolves for a camera nothing publishes: the state the
/// dialog is opened in when the user has to supply the figures themselves.
final _unknownCamera = CameraSensorSpecResolver().resolve(
  const CameraSensorSpecInputs(cameraName: 'MysteryCam', gain: 10),
);

/// A camera whose published specification is complete except for read noise:
/// ZWO publishes only a best-case figure with no gain for the ASI533MM Pro, so
/// the row omits it. The one empty field has to say why it is empty.
final _partlyPublishedCamera = CameraSensorSpecResolver().resolve(
  const CameraSensorSpecInputs(cameraName: 'ASI533MM Pro', gain: 100),
);

/// What it resolves for the owner's camera: every field already filled in from
/// ZWO's published specification, so the dialog is a correction surface.
final _publishedCamera = CameraSensorSpecResolver().resolve(
  const CameraSensorSpecInputs(cameraName: 'ASI1600MM-Cool', gain: 139),
);

Future<void> _pumpDialog(
  WidgetTester tester, {
  required ResolvedCameraSensorSpecs specs,
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => CameraSensorSpecsDialog.show(context, specs),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

String _fieldText(WidgetTester tester, String key) {
  final field = tester.widget<SkotiqTextField>(
    find.byKey(Key('camera-sensor-spec-$key')),
  );
  return field.controller!.text;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => registerFallbackValue(<String, String>{}));

  testWidgets('the dialog persists a camera hardware override', (tester) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpDialog(
      tester,
      specs: _unknownCamera,
      overrides: [databaseProvider.overrideWithValue(db)],
    );

    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-pixel-size')),
      '4.63',
    );
    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-read-noise')),
      '2.1',
    );
    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-full-well')),
      '42000',
    );
    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-qe')),
      '0.72',
    );
    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-gain')),
      '10',
    );
    await tester.tap(find.text('Save specs'));
    await tester.pumpAndSettle();

    final raw = await db.settingsDao.getSetting(
      HardwareSpecsService.cameraOverridesSettingKey,
    );
    final overrides = jsonDecode(raw!) as List<dynamic>;
    final override = overrides.single as Map<String, dynamic>;

    expect(override['model'], 'MysteryCam');
    expect(override['pixelSizeMicrons'], 4.63);
    expect(override['qePeak'], 0.72);
    final point = (override['gainPoints'] as List).single as Map;
    expect(point['gain'], 10);
    expect(point['readNoiseE'], 2.1);
    expect(point['fullWellE'], 42000);
  });

  testWidgets('a geometry-only correction asserts no noise figures', (
    tester,
  ) async {
    // Opening the dialog to fix a pixel size must not come away having also
    // asserted a read noise. The row carries no gain points, so read noise,
    // full well and QE stay with the tiers below and keep their own caveats.
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpDialog(
      tester,
      specs: _unknownCamera,
      overrides: [databaseProvider.overrideWithValue(db)],
    );

    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-pixel-size')),
      '4.63',
    );
    await tester.tap(find.text('Save specs'));
    await tester.pumpAndSettle();

    final raw = await db.settingsDao.getSetting(
      HardwareSpecsService.cameraOverridesSettingKey,
    );
    final override = (jsonDecode(raw!) as List).single as Map<String, dynamic>;
    expect(override['pixelSizeMicrons'], 4.63);
    expect(override['gainPoints'], isEmpty);
    expect(override.containsKey('qePeak'), isFalse);

    final resolved = CameraSensorSpecResolver().resolve(
      CameraSensorSpecInputs(
        cameraName: 'MysteryCam',
        gain: 10,
        overrides: HardwareSpecsService(
          cameraOverrides: HardwareSpecsService.cameraOverridesFromJson(
            jsonDecode(raw),
          ),
        ).overridesFor(cameraName: 'MysteryCam', gain: 10),
      ),
    );
    expect(resolved.pixelSizeMicrons!.value, 4.63);
    expect(resolved.pixelSizeMicrons!.origin, SensorSpecOrigin.userOverride);
    expect(resolved.readNoiseE, isNull);
    expect(resolved.qePeakFraction, isNull);
  });

  testWidgets('pressing save with nothing changed records nothing', (
    tester,
  ) async {
    // The fields arrive prefilled from the published specification. Saving
    // them unchanged would relabel ZWO's figures "the value you entered" and
    // lose the gain they were quoted at.
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpDialog(
      tester,
      specs: _publishedCamera,
      overrides: [databaseProvider.overrideWithValue(db)],
    );

    await tester.tap(find.text('Save specs'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Change a value'), findsOneWidget);
    expect(
      await db.settingsDao.getSetting(
        HardwareSpecsService.cameraOverridesSettingKey,
      ),
      isNull,
    );
  });

  testWidgets('the dialog arrives prefilled with what resolved', (
    tester,
  ) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpDialog(
      tester,
      specs: _publishedCamera,
      overrides: [databaseProvider.overrideWithValue(db)],
    );

    // ZWO's published figures for the owner's camera, so the user corrects
    // rather than transcribes a datasheet.
    expect(_fieldText(tester, 'model'), 'ZWO ASI1600MM');
    expect(_fieldText(tester, 'pixel-size'), '3.8');
    expect(_fieldText(tester, 'width'), '4656');
    expect(_fieldText(tester, 'height'), '3520');
    expect(_fieldText(tester, 'read-noise'), '1.2');
    expect(_fieldText(tester, 'full-well'), '20000');
    expect(_fieldText(tester, 'qe'), '0.6');
  });

  testWidgets('each field says where its value came from', (tester) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpDialog(
      tester,
      specs: _publishedCamera,
      overrides: [databaseProvider.overrideWithValue(db)],
    );

    expect(
      find.text('The published pixel pitch for ZWO ASI1600MM.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('quotes only at 30 dB gain'),
      findsOneWidget,
    );
  });

  testWidgets('the one unpublished field among many says why it is empty', (
    tester,
  ) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpDialog(
      tester,
      specs: _partlyPublishedCamera,
      overrides: [databaseProvider.overrideWithValue(db)],
    );

    expect(_fieldText(tester, 'read-noise'), isEmpty);
    expect(
      find.textContaining('Not published for this camera'),
      findsOneWidget,
      reason: 'read noise is the only field ZWO does not publish here',
    );
  });

  testWidgets('a camera with nothing published says it once, not six times', (
    tester,
  ) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpDialog(
      tester,
      specs: _unknownCamera,
      overrides: [databaseProvider.overrideWithValue(db)],
    );

    // The paragraph at the top carries it; six identical lines under six
    // empty inputs would be filler.
    expect(
      find.textContaining('Nothing is published for MysteryCam'),
      findsOneWidget,
    );
    expect(find.textContaining('Not published for this camera'), findsNothing);
  });

  testWidgets('read noise without a gain is refused', (tester) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpDialog(
      tester,
      specs: _unknownCamera,
      overrides: [databaseProvider.overrideWithValue(db)],
    );

    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-pixel-size')),
      '4.63',
    );
    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-read-noise')),
      '2.1',
    );
    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-full-well')),
      '42000',
    );
    await tester.tap(find.text('Save specs'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('gain that read noise and full well'),
      findsOneWidget,
    );
    expect(
      await db.settingsDao.getSetting(
        HardwareSpecsService.cameraOverridesSettingKey,
      ),
      isNull,
    );
  });

  testWidgets('a QE above 1 is refused', (tester) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpDialog(
      tester,
      specs: _unknownCamera,
      overrides: [databaseProvider.overrideWithValue(db)],
    );

    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-pixel-size')),
      '4.63',
    );
    await tester.enterText(
        find.byKey(const Key('camera-sensor-spec-qe')), '60');
    await tester.tap(find.text('Save specs'));
    await tester.pumpAndSettle();

    expect(find.textContaining('0.6 means 60%'), findsOneWidget);
  });

  testWidgets('correcting one field keeps the rest of what resolved', (
    tester,
  ) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpDialog(
      tester,
      specs: _publishedCamera,
      overrides: [databaseProvider.overrideWithValue(db)],
    );

    // The user measured their own read noise and changes only that.
    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-read-noise')),
      '3.6',
    );
    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-gain')),
      '0',
    );
    await tester.tap(find.text('Save specs'));
    await tester.pumpAndSettle();

    final raw = await db.settingsDao.getSetting(
      HardwareSpecsService.cameraOverridesSettingKey,
    );
    final override = (jsonDecode(raw!) as List).single as Map<String, dynamic>;
    // Only the field the user touched, plus the pair read noise cannot be
    // recorded without. Pixel size, QE and the geometry stay with the
    // published specification and keep its provenance.
    expect(override.containsKey('pixelSizeMicrons'), isFalse);
    expect(override.containsKey('qePeak'), isFalse);
    expect(override.containsKey('sensorWidthPx'), isFalse);
    final point = (override['gainPoints'] as List).single as Map;
    expect(point['gain'], 0);
    expect(point['readNoiseE'], 3.6);
    expect(point['fullWellE'], 20000);
  });

  testWidgets('the remote dialog writes the imaging host', (tester) async {
    final backend = _MockNetworkBackend();
    when(backend.getSmartNightSettings).thenAnswer((_) async => const {});
    Map<String, String>? written;
    when(() => backend.updateSmartNightSettings(any())).thenAnswer((
      invocation,
    ) async {
      written = (invocation.positionalArguments.single as Map).cast();
    });

    await _pumpDialog(
      tester,
      specs: _unknownCamera,
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );

    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-pixel-size')),
      '3.76',
    );
    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-read-noise')),
      '1.5',
    );
    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-full-well')),
      '19000',
    );
    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-qe')),
      '0.9',
    );
    await tester.enterText(
      find.byKey(const Key('camera-sensor-spec-gain')),
      '10',
    );
    await tester.tap(find.text('Save specs'));
    await tester.pumpAndSettle();

    expect(written, isNotNull);
    final raw = written![HardwareSpecsService.cameraOverridesSettingKey];
    final overrides = jsonDecode(raw!) as List<dynamic>;
    expect((overrides.single as Map)['model'], 'MysteryCam');
    verify(() => backend.updateSmartNightSettings(any())).called(1);
  });
}
