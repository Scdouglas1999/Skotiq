import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/flat_wizard/widgets/flat_build_master_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _Seam extends Mock implements PostSessionSeam {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('a finished run builds its master flat into the library', (
    tester,
  ) async {
    final database = mockDatabase();
    addTearDown(database.close);
    final folder = Directory.systemTemp.createTempSync('flat_step');
    addTearDown(() => folder.deleteSync(recursive: true));
    final seam = _Seam();
    final flatCalls = <Map<String, dynamic>>[];
    when(() => seam.buildMasterFlat(any())).thenAnswer((inv) async {
      final args = inv.positionalArguments.first as Map<String, dynamic>;
      flatCalls.add(args);
      return BuildMasterFlatResult(
        outputPath: args['outputPath'] as String,
        frameCount: (args['flatPaths'] as List).length,
        inputMean: 30000,
        outputMean: 1,
        width: 4656,
        height: 3520,
        channels: 1,
        outputBitDepth: 'f32',
      );
    });
    final service = CalibrationBacklogService(
      db: database,
      library: CalibrationLibraryService(
        db: database,
        flatLibraryDao: FlatLibraryDao(database),
        tagsDao: CalibrationTagsDao(database),
      ),
      darkLibrary: DarkLibraryService(DarkLibraryDao(database)),
      flatLibrary:
          FlatLibraryService(dao: FlatLibraryDao(database), seam: seam),
      buildMaster: (_) => throw UnimplementedError(),
      settings: database.settingsDao,
      fileExists: (_) async => true,
    );
    // The night's master bias, built before the flats were taken.
    await DarkLibraryDao(database).addEntry(
      db.DarkLibraryCompanion.insert(
        filePath: '/masters/MasterBias.fits',
        exposureTime: 0.001,
        frameType: const Value('bias'),
        gain: const Value(76),
        offset: const Value(15),
        masterDarkPath: const Value('/masters/MasterBias.fits'),
        masterFrameCount: const Value(50),
        createdAt: Value(DateTime(2026, 10, 22, 9)),
      ),
    );
    final paths = <String>[];
    for (var i = 0; i < 3; i++) {
      final path = '${folder.path}/Flats/Flat_L_$i.fits';
      paths.add(path);
      await service.recordCapturedFlat(
        filePath: path,
        exposureSeconds: 1.8,
        capturedAt: DateTime(2026, 10, 24, 18, 5, i),
        filter: 'L',
        gain: 76,
        offset: 15,
      );
    }

    final handle = await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: FlatBuildMasterStep()),
      database: database,
      settle: false,
      extraOverrides: [
        calibrationBacklogServiceProvider.overrideWithValue(service),
        calibrationBacklogProvider.overrideWith(
          (ref) => CalibrationBacklogNotifier(ref, remote: false),
        ),
      ],
    );
    handle.container.read(flatRunOutputProvider.notifier).state = FlatRunOutput(
      filters: {
        'L': FlatRunFilterOutput(
          filter: 'L',
          exposureSeconds: 1.8,
          gain: 76,
          offset: 15,
          paths: paths,
        ),
      },
    );
    await settle(tester);

    expect(find.text('3 frames ready'), findsOneWidget);
    await tester.tap(find.widgetWithText(SkotiqButton, 'Build master flat'));
    await settle(tester);

    expect(flatCalls.single['biasOrDarkFlat'], '/masters/MasterBias.fits');
    expect(find.text('In the library, 3 of 3 frames'), findsOneWidget);
    final flat = (await FlatLibraryDao(database).getAllEntries()).single;
    expect(flat.filter, 'L');
    expect(flat.gain, 76);
    expect(
      tester
          .widgetList<SkotiqButton>(find.byType(SkotiqButton))
          .map((b) => b.label),
      isNot(contains('Build master flat')),
    );
  });

  testWidgets('flats saved on a remote host point to where they are built', (
    tester,
  ) async {
    final database = mockDatabase();
    addTearDown(database.close);
    final handle = await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: FlatBuildMasterStep()),
      database: database,
      settle: false,
      extraOverrides: [
        calibrationBacklogProvider.overrideWith(
          (ref) => CalibrationBacklogNotifier(ref, remote: true),
        ),
      ],
    );
    handle.container.read(flatRunOutputProvider.notifier).state =
        const FlatRunOutput(
      remote: true,
      filters: {
        'Ha': FlatRunFilterOutput(
          filter: 'Ha',
          exposureSeconds: 6,
          paths: ['C:/flats/a.fits', 'C:/flats/b.fits'],
        ),
      },
    );
    await settle(tester);

    expect(find.text('2 frames on the imaging computer'), findsOneWidget);
    expect(find.textContaining('Darkroom there'), findsOneWidget);
    expect(
        find.widgetWithText(SkotiqButton, 'Build master flat'), findsNothing);
  });
}
