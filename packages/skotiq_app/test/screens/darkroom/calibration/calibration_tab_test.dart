import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/darkroom/calibration/calibration_match_panel.dart';
import 'package:skotiq_app/screens/darkroom/calibration/calibration_panel.dart';
import 'package:skotiq_app/screens/darkroom/calibration/calibration_settings_panel.dart';
import 'package:skotiq_app/screens/darkroom/calibration/calibration_tab.dart';
import 'package:skotiq_app/screens/darkroom/calibration/calibration_waiting_panel.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/database.dart' as db;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';
import 'package:skotiq_core/providers.dart';

class _Seam extends Mock implements PostSessionSeam {}

class _MockCalibrationLibraryService extends Mock
    implements CalibrationLibraryService {}

class _FakeLightFrameContext extends Fake implements LightFrameContext {}

/// The Darkroom's Calibration tab against an in-memory database seeded with
/// the raw calibration frames of a real night (NGC 7380, 2026-10-22: 20 x
/// 90 s and 20 x 120 s darks and 50 bias at gain 76 / offset 15, -10 C),
/// plus a warm 1 s test dark whose files are not on this computer.
class _Rig {
  _Rig(this.database, this.folder);

  final db.SkotiqDatabase database;
  final Directory folder;
  final missing = <String>{};
  final built = <CalibrationMasterBuildRequest>[];

  /// Frame and master headers by path; a file missing here states nothing.
  final headers = <String, FrameHeader>{};
  Future<FrameHeader> readHeader(String path) async =>
      headers[path] ?? FrameHeader(const {});

  late final library = CalibrationLibraryService(
    db: database,
    flatLibraryDao: FlatLibraryDao(database),
    tagsDao: CalibrationTagsDao(database),
    readHeader: readHeader,
    darkTolerances: () => const DarkLibraryMatchTolerances(temperatureC: 2),
  );

  late final service = CalibrationBacklogService(
    db: database,
    library: library,
    darkLibrary: DarkLibraryService(DarkLibraryDao(database)),
    flatLibrary: FlatLibraryService(
      dao: FlatLibraryDao(database),
      seam: _Seam(),
    ),
    buildMaster: (request) async {
      built.add(request);
      return CalibrationMasterBuildResult(
        outputPath: request.outputPath,
        kind: request.kind,
        width: 4656,
        height: 3520,
        frameCount: request.framePaths.length,
        leakingFrames: const [],
        frameLevels: const [],
        leakBaseline: 0,
        leakThreshold: 0,
        masterMean: 520,
        rejectionFraction: 0.01,
        exposureSecs: request.kind == 'bias' ? 0.001 : 90,
        gain: 76,
        offset: 15,
        binX: 1,
        binY: 1,
        ccdTempMean: -10,
      );
    },
    settings: database.settingsDao,
    fileExists: (path) async => !missing.contains(path),
    readHeader: readHeader,
    temperatureToleranceC: () async => 2,
  );

  Future<void> addFrames(
    String type,
    int count, {
    required double exposure,
    required DateTime start,
    double temp = -10,
    List<double>? temps,
    double? setPoint,
    int gain = 76,
    int offset = 15,
    String dir = 'NGC7380',
  }) async {
    for (var i = 0; i < count; i++) {
      final path = '${folder.path}/$dir/${type}_${exposure}_$i.fits';
      if (setPoint != null) {
        headers[path] = FrameHeader({'SET-TEMP': setPoint});
      }
      await database.into(database.capturedImages).insert(
            db.CapturedImagesCompanion.insert(
              filePath: path,
              fileName: path.split('/').last,
              frameType: Value(type),
              exposureDuration: exposure,
              capturedAt: start.add(Duration(seconds: 95 * i)),
              gain: Value(gain),
              offset: Value(offset),
              sensorTemp: Value(temps?[i] ?? temp),
            ),
          );
    }
  }

  Future<void> seedNight() async {
    final night = DateTime(2026, 10, 22, 0, 52);
    await addFrames('dark', 20, exposure: 90, start: night);
    await addFrames('dark', 20, exposure: 120, start: night);
    await addFrames('bias', 50, exposure: 0.001, start: night);
    await addFrames(
      'dark',
      3,
      exposure: 1,
      start: DateTime(2026, 9, 6, 21, 12),
      temp: 20,
      gain: 139,
      offset: 21,
      dir: 'test',
    );
    missing.add('${folder.path}/test/dark_1.0_0.fits');
  }
}

Future<_Rig> _rig() async {
  final database = mockDatabase();
  addTearDown(database.close);
  final folder = Directory.systemTemp.createTempSync('cal_tab');
  addTearDown(() => folder.deleteSync(recursive: true));
  return _Rig(database, folder);
}

Future<HarnessHandle> _pumpTab(
  WidgetTester tester,
  _Rig rig, {
  Size size = const Size(1800, 1000),
  Widget child = const DarkroomCalibrationTab(),
}) async {
  final handle = await pumpAppScreen(
    tester,
    child,
    size: size,
    database: rig.database,
    settle: false,
    extraOverrides: [
      calibrationLibraryServiceProvider.overrideWithValue(rig.library),
      calibrationBacklogServiceProvider.overrideWithValue(rig.service),
      calibrationBacklogProvider.overrideWith(
        (ref) => CalibrationBacklogNotifier(ref, remote: false),
      ),
    ],
  );
  await _settle(tester);
  return handle;
}

/// Let the database reads and the backlog refresh land without waiting on
/// the spinners' endless animations.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(const CalibrationLibraryFilter());
    registerFallbackValue(_FakeLightFrameContext());
  });

  group('waiting to be built', () {
    testWidgets('lists the night\'s raw darks and bias with a build for each', (
      tester,
    ) async {
      final rig = await _rig();
      await rig.seedNight();

      await _pumpTab(tester, rig);

      expect(find.text('Waiting to be built'), findsOneWidget);
      expect(find.text('Dark 90 s'), findsOneWidget);
      expect(find.text('Dark 120 s'), findsOneWidget);
      expect(find.text('Bias'), findsOneWidget);
      expect(find.text('NIGHT OF OCT 21, 2026'), findsOneWidget);
      expect(find.text('20 frames'), findsNWidgets(2));
      expect(find.text('50 frames'), findsOneWidget);
      expect(
        find.text('gain 76 · offset 15 · bin 1x1 · -10 °C'),
        findsNWidgets(3),
      );
      expect(find.text('Build all 3'), findsOneWidget);
    });

    testWidgets('frames that are not on this computer cannot be built', (
      tester,
    ) async {
      final rig = await _rig();
      await rig.seedNight();

      await _pumpTab(tester, rig);

      expect(find.text('Dark 1 s'), findsOneWidget);
      expect(
        find.text('1 of 3 frames are not on this computer'),
        findsOneWidget,
      );
      final row = find.ancestor(
        of: find.text('Dark 1 s'),
        matching: find.byType(Column),
      );
      final build = tester.widget<SkotiqButton>(
        find.descendant(
          of: row.first,
          matching: find.widgetWithText(SkotiqButton, 'Build'),
        ),
      );
      expect(build.onPressed, isNull);
    });

    testWidgets('darks read off their set-point say so and cannot be built', (
      tester,
    ) async {
      final rig = await _rig();
      // The rig's darks of 2026-11-15 23:27, taken while the sensor warmed
      // from -10 °C toward the 1 °C set-point.
      await rig.addFrames(
        'dark',
        6,
        exposure: 3,
        start: DateTime(2026, 11, 15, 23, 27),
        temps: const [-9.7, -8.9, -8.0, -7.2, -6.3, -5.5],
        setPoint: 1,
        gain: 139,
        offset: 21,
      );

      await _pumpTab(tester, rig);

      expect(
          find.text('gain 139 · offset 21 · bin 1x1 · 1 °C'), findsOneWidget);
      expect(find.text('0 frames'), findsOneWidget);
      expect(
        find.text(
          '6 of 6 frames read too far from the 1 °C set-point; a master '
          'needs at least 2 at it',
        ),
        findsOneWidget,
      );
      final build = tester.widget<SkotiqButton>(
        find.widgetWithText(SkotiqButton, 'Build'),
      );
      expect(build.onPressed, isNull);
    });

    testWidgets(
        'a master built off its set-point is listed with why it is '
        'not used', (tester) async {
      final rig = await _rig();
      final path = '${rig.folder.path}/MasterDark_3s_g139_o21_m8C_bin1.fits';
      File(path).writeAsStringSync('');
      rig.headers[path] = FrameHeader(const {
        'SET-TEMP': 1.0,
        'CCD-TEMP': -7.6,
      });
      await DarkLibraryDao(rig.database).addEntry(
        db.DarkLibraryCompanion.insert(
          filePath: path,
          exposureTime: 3,
          gain: const Value(139),
          offset: const Value(21),
          temperature: const Value(-7.6),
          masterDarkPath: Value(path),
          masterFrameCount: const Value(6),
        ),
      );

      await _pumpTab(tester, rig);

      expect(
        find.text(
          'Not used to calibrate: Built from frames that read -7.6 °C on '
          'average at a 1 °C set-point, more than 2 °C from it.',
        ),
        findsOneWidget,
      );
      expect(find.text('MasterDark_3s_g139_o21_m8C_bin1.fits'), findsOneWidget);
    });

    testWidgets('one click builds the master, registers it and says so', (
      tester,
    ) async {
      final rig = await _rig();
      await rig.addFrames(
        'dark',
        20,
        exposure: 90,
        start: DateTime(2026, 10, 22, 0, 52),
      );
      final handle = await _pumpTab(tester, rig);
      final revision = handle.container.read(
        calibrationLibraryRevisionProvider,
      );

      await tester.tap(find.widgetWithText(SkotiqButton, 'Build'));
      await _settle(tester);

      expect(rig.built.single.framePaths, hasLength(20));
      expect(find.text('Dark 90 s'), findsNothing);
      expect(
        find.textContaining('Master dark built from 20 of 20 frames'),
        findsOneWidget,
      );
      final masters = await DarkLibraryDao(rig.database).getAllEntries();
      expect(masters.single.masterDarkPath, rig.built.single.outputPath);
      expect(
        handle.container.read(calibrationLibraryRevisionProvider),
        revision + 1,
      );
      // The library lists the new master without a manual reload.
      expect(find.text('DARKS · 1'), findsOneWidget);
    });

    testWidgets('nothing waiting reads as done, not as empty', (tester) async {
      final rig = await _rig();

      await _pumpTab(tester, rig);

      expect(find.textContaining('Nothing is waiting'), findsOneWidget);
      expect(find.textContaining('Build all'), findsNothing);
    });

    testWidgets('a remote client says where the frames are built', (
      tester,
    ) async {
      final rig = await _rig();
      await pumpAppScreen(
        tester,
        const SingleChildScrollView(child: CalibrationWaitingPanel()),
        database: rig.database,
        settle: false,
        extraOverrides: [
          calibrationBacklogProvider.overrideWith(
            (ref) => CalibrationBacklogNotifier(ref, remote: true),
          ),
        ],
      );
      await _settle(tester);

      expect(
        find.textContaining('built on the imaging computer'),
        findsOneWidget,
      );
    });
  });

  group('layout', () {
    for (final width in [1280.0, 1800.0]) {
      testWidgets('two columns without overflow at $width', (tester) async {
        final rig = await _rig();
        await rig.seedNight();

        await _pumpTab(tester, rig, size: Size(width, 900));

        expect(tester.takeException(), isNull);
        Offset panel(String title) => tester.getTopLeft(
              find
                  .ancestor(
                    of: find.text(title),
                    matching: find.byType(CalibrationSection),
                  )
                  .first,
            );
        final waiting = panel('Waiting to be built');
        final side = panel('While imaging');
        expect(side.dx, greaterThan(waiting.dx));
        expect(side.dy, closeTo(waiting.dy, 4));
      });
    }

    testWidgets('stacks into one column on a narrow window', (tester) async {
      final rig = await _rig();
      await rig.seedNight();

      await _pumpTab(tester, rig, size: const Size(760, 900));

      expect(tester.takeException(), isNull);
      final waiting = tester.getTopLeft(find.text('Waiting to be built'));
      final library = tester.getTopLeft(find.text('Library'));
      expect(library.dy, greaterThan(waiting.dy));
    });
  });

  group('while imaging', () {
    testWidgets('the calibrate-on-capture switch writes the shared flag', (
      tester,
    ) async {
      final rig = await _rig();
      await rig.database.settingsDao.setSettings({
        'calibration.auto_calibrate': 'true',
      });
      final handle = await _pumpTab(
        tester,
        rig,
        child: const SingleChildScrollView(child: CalibrationSettingsPanel()),
      );
      expect(
        handle.container.read(calibrationSettingsProvider).autoCalibrate,
        isTrue,
      );

      final row = find.ancestor(
        of: find.text('Calibrate frames as they are captured'),
        matching: find.byType(SkotiqSwitchRow),
      );
      await tester.tap(
        find.descendant(of: row, matching: find.byType(SkotiqSwitch)),
      );
      await _settle(tester);

      expect(
        handle.container.read(calibrationSettingsProvider).autoCalibrate,
        isFalse,
      );
      expect(
        await rig.database.settingsDao.getSetting('calibration.auto_calibrate'),
        'false',
      );
    });
  });

  group('check a match', () {
    testWidgets('starts from the newest light and rejects a bad exposure', (
      tester,
    ) async {
      final rig = await _rig();
      await rig.database.into(rig.database.capturedImages).insert(
            db.CapturedImagesCompanion.insert(
              filePath: '/lights/ngc891_L_120.fits',
              fileName: 'ngc891_L_120.fits',
              exposureDuration: 120,
              capturedAt: DateTime(2026, 10, 23, 2),
              gain: const Value(76),
              offset: const Value(15),
              filter: const Value('L'),
              sensorTemp: const Value(-10),
            ),
          );
      final service = _MockCalibrationLibraryService();
      await pumpAppScreen(
        tester,
        SingleChildScrollView(
          child: CalibrationMatchPanel(onAccept: (_) async {}),
        ),
        database: rig.database,
        settle: false,
        extraOverrides: [
          calibrationLibraryServiceProvider.overrideWithValue(service),
        ],
      );
      await _settle(tester);

      String fieldText(String label) => tester
          .widget<EditableText>(
            find.descendant(
              of: find.ancestor(
                of: find.text(label),
                matching: find.byType(SkotiqTextField),
              ),
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text;
      expect(fieldText('Exposure s'), '120');
      expect(fieldText('Gain'), '76');
      expect(fieldText('Filter'), 'L');

      await tester.enterText(
        find.descendant(
          of: find.ancestor(
            of: find.text('Exposure s'),
            matching: find.byType(SkotiqTextField),
          ),
          matching: find.byType(EditableText),
        ),
        'not-a-number',
      );
      await tester.tap(find.widgetWithText(SkotiqButton, 'Check'));
      await tester.pump();

      expect(
        find.textContaining('Exposure must be a finite number'),
        findsOneWidget,
      );
      verifyNever(() => service.match(any()));
    });
  });
}
