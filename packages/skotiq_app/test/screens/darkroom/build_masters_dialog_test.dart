import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/build_masters_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _BuildService extends DarkroomBuildService {
  _BuildService(SkotiqDatabase db)
      : super(
            operation: (_) async =>
                throw StateError('Native build must not run'),
            library: CalibrationLibraryService(
                db: db,
                flatLibraryDao: FlatLibraryDao(db),
                tagsDao: CalibrationTagsDao(db)),
            masters: IntegratedMastersDao(db));
  @override
  Future<List<DarkroomBuildGroup>> prepare(
          List<DbCapturedImage> frames) async =>
      [
        DarkroomBuildGroup(
            label: 'Night 1 / L',
            filter: 'L',
            frames: frames,
            calibration: {'cosmeticCorrection': true},
            warnings: ['No matching flat: dust and vignetting remain.'])
      ];
  @override
  Future<void> checkCalibration(List<DarkroomBuildGroup> groups) async {
    throw StateError(
        'Flat has an obstruction. Select another flat or choose no flat.');
  }
}

void main() {
  testWidgets(
      'review is required; failed preflight keeps calibration choices available',
      (tester) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final targetId = await db.targetsDao.createTarget(
        TargetsCompanion.insert(name: 'NGC891', ra: 2.3, dec: 42.3));
    await db.imagesDao.createImage(CapturedImagesCompanion.insert(
        targetId: Value(targetId),
        filePath: '/missing/light.fits',
        fileName: 'light.fits',
        exposureDuration: 90,
        capturedAt: DateTime(2026, 10, 24)));
    await tester.pumpWidget(ProviderScope(overrides: [
      databaseProvider.overrideWithValue(db),
      darkroomBuildServiceProvider.overrideWithValue(_BuildService(db))
    ], child: const MaterialApp(home: Scaffold(body: BuildMastersDialog()))));
    await tester.pumpAndSettle();
    final build = find.widgetWithText(FilledButton, 'Build and export masters');
    expect(tester.widget<FilledButton>(build).onPressed, isNull);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('NGC891 · 1 captures').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prepare calibration'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(build).onPressed, isNull);
    await tester.scrollUntilVisible(find.text('Night 1 / L'), 150,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Night 1 / L'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Build from frames'), findsNWidgets(3));
    await tester.tap(find.text('Night 1 / L'));
    await tester.pumpAndSettle();
    final reviewed = find
        .text('I reviewed the calibration choices and any missing masters.');
    await tester.scrollUntilVisible(reviewed, 250,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(reviewed);
    await tester.pump();
    expect(tester.widget<FilledButton>(build).onPressed, isNotNull);
    await tester.tap(build);
    await tester.pumpAndSettle();
    expect(find.textContaining('Flat has an obstruction'), findsOneWidget);
    expect(find.text('Resume saved build'), findsOneWidget);
    expect(tester.widget<FilledButton>(build).onPressed, isNotNull);
  });
}
