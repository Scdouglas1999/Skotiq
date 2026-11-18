import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

class _Science extends Mock implements ScienceBackend {}

/// Science with image grading on and grading rules saved in the Image
/// Grader, the settings under which the pipeline graded frames a second time.
class _Settings extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async => ScienceSettings.fromRows(const {
    'image_grading_enabled': 'true',
    'science.grading.rules_json': '{"maxGuidingRms":1.2,"maxHfr":3.2}',
  }).copyWith(
    frameQualityMapsEnabled: false,
    photometricCalibrationEnabled: false,
    transparencyEnabled: false,
    psfMapEnabled: false,
    astrometricResidualsEnabled: false,
    photometryEnabled: false,
    fitsHeaderWritebackEnabled: false,
  );
}

void main() {
  setUpAll(() => registerFallbackValue(const SolveOptions()));

  // IC 405, 2026-11-16: the science pipeline graded frames a second time
  // against absolute limits and marked frames the run kept as rejected, so
  // Tonight's strip and the run disagreed. The run's verdict is the only one:
  // the pipeline publishes what the run kept and leaves every verdict as the
  // run wrote it.
  test(
    'the pipeline keeps the run\'s verdict and publishes only what it kept',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      final science = _Science();
      final published = <int>[];
      final repo = LocalImagingRecords(
        sessionsDao: db.sessionsDao,
        imagesDao: db.imagesDao,
        onSolvedFrameFold: (id) async {
          published.add(id);
        },
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          scienceSettingsProvider.overrideWith(_Settings.new),
          imagingRecordsProvider.overrideWithValue(repo),
          scienceBackendProvider.overrideWithValue(science),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      const wcs = WcsSolution(
        raHours: 5.27,
        decDegrees: 34.47,
        pixelScaleArcsecPerPixel: .788,
        rotationDegrees: 179,
        fieldWidthDegrees: 1,
        fieldHeightDegrees: 1,
        solverId: 'test',
      );
      // Kept by the run with guiding and HFR past the old absolute rules
      // (guiding 1.2", HFR 3.2 px), and one the run rejected.
      final frames = <({String name, bool kept, String? reason})>[
        (name: 'IC405_Ha_0001', kept: true, reason: null),
        (
          name: 'IC405_Ha_0002',
          kept: false,
          reason: 'HFR 4.12 px exceeds baseline 2.80 px + 50% (limit 4.20 px)',
        ),
      ];
      for (final frame in frames) {
        final path = '/test/${frame.name}.fits';
        final id = await db
            .into(db.capturedImages)
            .insert(
              CapturedImagesCompanion.insert(
                filePath: path,
                fileName: '${frame.name}.fits',
                exposureDuration: 180,
                capturedAt: DateTime.utc(2026, 11, 17, 2),
                guidingRmsTotal: const Value(1.37),
                hfr: const Value(3.61),
                starCount: const Value(900),
                mountAltitude: const Value(50),
                isAccepted: Value(frame.kept),
                rejectionReason: Value(frame.reason),
              ),
            );
        when(
          () => science.solveForScience(path, const SolveOptions()),
        ).thenAnswer((_) async => wcs);
        final result = await container
            .read(scienceProcessingServiceProvider)
            .processFrame(imagePath: path, capturedImageId: id);
        expect(
          result.kind,
          ScienceFrameOutcomeKind.processed,
          reason: result.error,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final row = (await repo.getImageById(id))!;
        expect(row.isAccepted, frame.kept, reason: frame.name);
        expect(row.rejectionReason, frame.reason, reason: frame.name);
        expect(published.contains(id), frame.kept, reason: frame.name);
      }
      expect(published, hasLength(1));
    },
  );

  // F25: a frame the run's frame watch had solved (center, scale, rotation,
  // no CD matrix) was solved again blind for its full WCS.
  test(
    'a frame with a stored center is solved again around that center',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      final science = _Science();
      final repo = LocalImagingRecords(
        sessionsDao: db.sessionsDao,
        imagesDao: db.imagesDao,
        onSolvedFrameFold: (_) async {},
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          scienceSettingsProvider.overrideWith(_Settings.new),
          imagingRecordsProvider.overrideWithValue(repo),
          scienceBackendProvider.overrideWithValue(science),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      const path = '/test/M31_L_0001.fits';
      final id = await db
          .into(db.capturedImages)
          .insert(
            CapturedImagesCompanion.insert(
              filePath: path,
              fileName: 'M31_L_0001.fits',
              exposureDuration: 30,
              capturedAt: DateTime.utc(2026, 11, 16, 3, 30),
              isPlateSolved: const Value(true),
              solvedRa: const Value(0.712),
              solvedDec: const Value(41.27),
              solvedRotation: const Value(-21.3),
              solvedPixelScale: const Value(0.79),
            ),
          );
      when(
        () => science.solveForScience(any(), any()),
      ).thenAnswer((_) async => null);

      await container
          .read(scienceProcessingServiceProvider)
          .processFrame(imagePath: path, capturedImageId: id);

      final options =
          verify(
                () => science.solveForScience(path, captureAny()),
              ).captured.first
              as SolveOptions;
      expect(options.raHintHours, 0.712);
      expect(options.decHintDegrees, 41.27);
      expect(options.searchRadiusDegrees, isNotNull);
    },
  );
}
