// The science hub asks where to save its CSVs, like every other export in the
// app. A hard-coded path ignores the directory this install keeps its data in
// and shares one folder with every other instance on the machine.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_export_hub.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

TestFlutterView get _view =>
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;

final _measurement = PhotometryMeasurementRow(
  id: 1,
  objectId: 'V-TEST',
  role: 'target',
  x: 10,
  y: 20,
  flux: 1234,
  differentialMagnitude: -0.31,
  snr: 42,
  uncertainty: 0.02,
  isOutlier: false,
  timestamp: DateTime.utc(2026, 8, 1, 9),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('science-export-save-loc');
    _view.physicalSize = const Size(1200, 1400);
    _view.devicePixelRatio = 1;
  });

  tearDown(() {
    _view.resetPhysicalSize();
    _view.resetDevicePixelRatio();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Pump the hub with a picker that records how it was asked and answers
  /// [chosenPath] (null = the operator cancelled).
  Future<Map<String, Object?>> pumpAndExport(
    WidgetTester tester, {
    required String? chosenPath,
    required Directory suggestedDirectory,
    required void Function(File file, String contents) onWrite,
  }) async {
    final asked = <String, Object?>{};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allSessionsProvider.overrideWith(
            (ref) => Stream.value(const <ImagingSession>[]),
          ),
          allTransientDetectionsProvider.overrideWith(
            (ref) => Stream.value(const <TransientDetectionRow>[]),
          ),
          sessionlessPhotometryExportProvider
              .overrideWith((ref) => Future.value([_measurement])),
          scienceExportDirectoryProvider
              .overrideWith((ref) => suggestedDirectory),
          scienceExportSavePickerProvider.overrideWithValue(
            ({
              required fileName,
              required initialDirectory,
              required allowedExtensions,
            }) async {
              asked['fileName'] = fileName;
              asked['initialDirectory'] = initialDirectory;
              asked['allowedExtensions'] = allowedExtensions;
              return chosenPath;
            },
          ),
          scienceExportFileWriterProvider.overrideWithValue((file, contents) {
            onWrite(file, contents);
            return Future<void>.value();
          }),
        ],
        child: const MaterialApp(home: Scaffold(body: ScienceExportHub())),
      ),
    );
    await tester.pumpAndSettle();

    final csvButton = find.widgetWithText(SkotiqButton, 'CSV').first;
    await tester.ensureVisible(csvButton);
    await tester.tap(csvButton);
    for (var attempt = 0; attempt < 100 && asked.isEmpty; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
    return asked;
  }

  testWidgets('a CSV export asks where to save and writes where told',
      (tester) async {
    final suggested = Directory('${tempDir.path}/data/exports')
      ..createSync(recursive: true);
    final chosen = '${tempDir.path}/elsewhere/photometry.csv';
    String? writtenTo;

    final asked = await pumpAndExport(
      tester,
      chosenPath: chosen,
      suggestedDirectory: suggested,
      onWrite: (file, _) => writtenTo = file.path,
    );

    expect(
      asked['fileName'],
      startsWith('photometry_'),
      reason: 'the export must offer a name, not pick one silently',
    );
    expect(
      asked['initialDirectory'],
      suggested.path,
      reason: 'the dialog opens next to this install\'s data, not a fixed '
          '~/Documents tree',
    );
    expect(asked['allowedExtensions'], const ['csv']);
    expect(writtenTo, chosen);
    // …and the confirmation names the path the operator picked.
    expect(find.textContaining(chosen), findsWidgets);
  });

  testWidgets('cancelling the save dialog writes nothing and says so',
      (tester) async {
    final suggested = Directory('${tempDir.path}/data/exports')
      ..createSync(recursive: true);
    var writes = 0;

    await pumpAndExport(
      tester,
      chosenPath: null,
      suggestedDirectory: suggested,
      onWrite: (_, __) => writes++,
    );

    expect(writes, 0);
    expect(find.text('Export cancelled.'), findsOneWidget);
  });
}
