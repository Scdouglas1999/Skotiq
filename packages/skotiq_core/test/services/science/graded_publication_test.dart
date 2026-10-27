import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _Science extends Mock implements ScienceBackend {}

class _Settings extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async => const ScienceSettings(
    frameQualityMapsEnabled: false,
    photometricCalibrationEnabled: false,
    transparencyEnabled: false,
    psfMapEnabled: false,
    astrometricResidualsEnabled: false,
    photometryEnabled: false,
    fitsHeaderWritebackEnabled: false,
    autoFrameGradingEnabled: true,
    frameGradeRulesJson: '{"maxGuidingRms":1.2}',
  );
}

void main() {
  test(
    'the real pipeline grades before publishing and omits rejected frames',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      final science = _Science();
      final published = <int>[];
      final repo = ImagingRecordsRepository.local(
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
          imagingRecordsRepositoryProvider.overrideWithValue(repo),
          scienceBackendProvider.overrideWithValue(science),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      const wcs = WcsSolution(
        raHours: 2.375,
        decDegrees: 42.35,
        pixelScaleArcsecPerPixel: .788,
        rotationDegrees: -21.3,
        fieldWidthDegrees: 1,
        fieldHeightDegrees: 1,
        solverId: 'test',
      );
      for (final rms in [.67, 1.37]) {
        final path = '/test/NGC891-$rms.fits';
        final id = await db
            .into(db.capturedImages)
            .insert(
              CapturedImagesCompanion.insert(
                filePath: path,
                fileName: 'NGC891-$rms.fits',
                exposureDuration: 120,
                capturedAt: DateTime.utc(2026, 10, 27),
                guidingRmsTotal: Value(rms),
                mountAltitude: const Value(50),
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
        expect(row.isAccepted, rms < 1.2);
        expect(published.contains(id), rms < 1.2);
      }
      expect(published, hasLength(1));
    },
  );
}
