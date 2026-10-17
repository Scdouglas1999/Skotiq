// Stack-and-Share Loop — tests for the export + sidecar service.
//
// Covers the file-generation contract end-to-end against a real temp directory
// and a real in-memory database:
//   * Each [ShareExportFormat] writes a non-empty, decodable file.
//   * PNG/JPEG go through the injected save functions (matching the bridge's
//     signatures) so the path is exercised without the Rust dynamic library.
//   * The share-card path composites a watermark + stats overlay onto the
//     image and picks PNG vs JPEG from the output extension.
//   * A successful export stamps the written path onto the persisted result.
//   * AstroBin metadata is filled from the profile + run, and the markdown
//     carries the HMS integration, frame count, and telescope/camera lines.
//   * The sidecar writes a .md + .json beside the image, and the json
//     round-trips back to an equal [AstroBinExportMetadata].
//   * Buffer / quality misuse throws rather than writing garbage.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/database/daos/stacked_results_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/stack_and_share_models.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/services/live_stacking_service.dart';
import 'package:skotiq_core/src/services/stack_share_export_service.dart';
import 'package:path/path.dart' as p;

/// A tightly-packed opaque RGBA buffer with a horizontal red ramp — enough
/// structure that the encoders have real pixels to write.
Uint8List _rgbaRamp(int width, int height) {
  final out = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      out[i] = (x * 255 ~/ (width - 1)).clamp(0, 255); // R
      out[i + 1] = 48; // G
      out[i + 2] = 96; // B
      out[i + 3] = 255; // A (opaque)
    }
  }
  return out;
}

StackAndShareResult _sampleResult({
  int? id,
  int width = 16,
  int height = 12,
  int framesStacked = 38,
  int framesAttempted = 40,
  double integrationSecs = 4560, // 01:16:00
  String? targetName = 'M51',
  String? filter = 'L',
}) {
  return StackAndShareResult(
    id: id,
    sessionId: 42,
    targetId: 7,
    targetName: targetName,
    width: width,
    height: height,
    framesStacked: framesStacked,
    framesAttempted: framesAttempted,
    integrationSecs: integrationSecs,
    avgAlignmentResidual: 0.42,
    filter: filter,
    createdAt: DateTime.utc(2026, 3, 14, 21, 47, 30),
    stats: LiveStackingStats(
      stackedFrameCount: framesStacked,
      totalFramesAttempted: framesAttempted,
      avgAlignmentResidual: 0.42,
    ),
  );
}

void main() {
  late Directory tempDir;
  late SkotiqDatabase db;
  late ProviderContainer container;
  late StackedResultsDao resultsDao;

  // Injected pure-Dart substitutes for the bridge save calls. They use the
  // `image` package so the test never touches the Rust dynamic library, while
  // still proving the service routes PNG/JPEG through the save path and writes
  // a real, decodable file. A counter lets tests assert which path ran.
  late int pngSaveCount;
  late int jpegSaveCount;
  late int lastJpegQuality;

  Future<void> savePng({
    required String filePath,
    required int width,
    required int height,
    required List<int> rgba,
  }) async {
    pngSaveCount++;
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: Uint8List.fromList(rgba).buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    await File(filePath).writeAsBytes(img.encodePng(image), flush: true);
  }

  Future<void> saveJpeg({
    required String filePath,
    required int width,
    required int height,
    required List<int> rgba,
    required int quality,
  }) async {
    jpegSaveCount++;
    lastJpegQuality = quality;
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: Uint8List.fromList(rgba).buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    ).convert(numChannels: 3);
    await File(
      filePath,
    ).writeAsBytes(img.encodeJpg(image, quality: quality), flush: true);
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('stack_share_export_test');
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    pngSaveCount = 0;
    jpegSaveCount = 0;
    lastJpegQuality = -1;
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    resultsDao = container.read(stackedResultsDaoProvider);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// Construct the service with the injected save substitutes, reading the
  /// `Ref` from the test container so it shares the in-memory database.
  StackShareExportService service() {
    return StackShareExportService(
      container.read(_refProvider),
      savePng: savePng,
      saveJpeg: saveJpeg,
      applicationSupportDirectoryProvider: () async => tempDir,
    );
  }

  group('durable viewer preview', () {
    test(
      'writes atomically and links the canonical PNG to the result row',
      () async {
        final source = _sampleResult(width: 16, height: 12);
        final id = await resultsDao.insertResult(source);
        final result = source.copyWith(id: id);

        final path = await service().persistViewerPreview(
          result: result,
          rgba: _rgbaRamp(16, 12),
        );

        expect(
          path,
          p.join(tempDir.path, 'stack_and_share', 'results', 'result_$id.png'),
        );
        expect(File(path).existsSync(), isTrue);
        expect(File('$path.partial.png').existsSync(), isFalse);
        final decoded = img.decodePng(File(path).readAsBytesSync());
        expect(decoded, isNotNull);
        expect(decoded!.width, 16);
        expect(decoded.height, 12);
        final stored = await resultsDao.getResultById(id);
        expect(stored!.exportedImagePath, path);
      },
    );

    test('requires a persisted result id before writing anything', () async {
      await expectLater(
        service().persistViewerPreview(
          result: _sampleResult(),
          rgba: _rgbaRamp(16, 12),
        ),
        throwsStateError,
      );
      expect(pngSaveCount, 0);
    });
  });

  group('exportImage — format coverage', () {
    test(
      'PNG export writes a non-empty, decodable file via the save path',
      () async {
        final result = _sampleResult(width: 16, height: 12);
        final rgba = _rgbaRamp(16, 12);
        final out = p.join(tempDir.path, 'm51.png');

        final written = await service().exportImage(
          result: result,
          rgba: rgba,
          format: ShareExportFormat.png,
          outputPath: out,
        );

        expect(written, p.normalize(p.absolute(out)));
        expect(pngSaveCount, 1);
        expect(jpegSaveCount, 0);
        final bytes = File(written).readAsBytesSync();
        expect(bytes, isNotEmpty);
        final decoded = img.decodePng(bytes);
        expect(decoded, isNotNull);
        expect(decoded!.width, 16);
        expect(decoded.height, 12);
      },
    );

    test('JPEG export honours quality and writes a decodable file', () async {
      final result = _sampleResult(width: 16, height: 12);
      final rgba = _rgbaRamp(16, 12);
      final out = p.join(tempDir.path, 'm51.jpg');

      final written = await service().exportImage(
        result: result,
        rgba: rgba,
        format: ShareExportFormat.jpeg,
        outputPath: out,
        jpegQuality: 80,
      );

      expect(jpegSaveCount, 1);
      expect(lastJpegQuality, 80);
      final bytes = File(written).readAsBytesSync();
      expect(bytes, isNotEmpty);
      expect(img.decodeJpg(bytes), isNotNull);
    });

    test(
      'share card composites overlay and writes PNG for a .png path',
      () async {
        final result = _sampleResult(width: 64, height: 48);
        final rgba = _rgbaRamp(64, 48);
        final out = p.join(tempDir.path, 'card.png');
        const spec = ShareCardSpec(
          title: 'M51',
          stats: [ShareStatLine(label: 'Integration', value: '01:16:00')],
          watermark: 'Skotiq',
          targetWidth: 64,
          targetHeight: 48,
        );

        final written = await service().exportImage(
          result: result,
          rgba: rgba,
          format: ShareExportFormat.shareCard,
          outputPath: out,
          cardSpec: spec,
        );

        // The card path renders in Dart, not through the injected save funcs.
        expect(pngSaveCount, 0);
        expect(jpegSaveCount, 0);
        final bytes = File(written).readAsBytesSync();
        expect(bytes, isNotEmpty);
        final decoded = img.decodePng(bytes);
        expect(decoded, isNotNull);
        expect(decoded!.width, 64);
        expect(decoded.height, 48);
      },
    );

    test('share card emits JPEG for a .jpg path', () async {
      final result = _sampleResult(width: 64, height: 48);
      final rgba = _rgbaRamp(64, 48);
      final out = p.join(tempDir.path, 'card.jpg');
      const spec = ShareCardSpec(
        title: 'M51',
        watermark: 'Skotiq',
        targetWidth: 64,
        targetHeight: 48,
      );

      final written = await service().exportImage(
        result: result,
        rgba: rgba,
        format: ShareExportFormat.shareCard,
        outputPath: out,
        cardSpec: spec,
        jpegQuality: 70,
      );

      final bytes = File(written).readAsBytesSync();
      expect(bytes, isNotEmpty);
      expect(img.decodeJpg(bytes), isNotNull);
    });

    test('creates missing parent directories', () async {
      final result = _sampleResult(width: 8, height: 8);
      final rgba = _rgbaRamp(8, 8);
      final out = p.join(tempDir.path, 'nested', 'deeper', 'm51.png');

      final written = await service().exportImage(
        result: result,
        rgba: rgba,
        format: ShareExportFormat.png,
        outputPath: out,
      );
      expect(File(written).existsSync(), isTrue);
    });
  });

  group('exportImage — persistence + validation', () {
    test('stamps the exported path onto a persisted result', () async {
      final id = await resultsDao.insertResult(_sampleResult(id: null));
      final result = _sampleResult(id: id, width: 8, height: 8);
      final out = p.join(tempDir.path, 'persisted.png');

      final written = await service().exportImage(
        result: result,
        rgba: _rgbaRamp(8, 8),
        format: ShareExportFormat.png,
        outputPath: out,
      );

      final stored = await resultsDao.getResultById(id);
      expect(stored, isNotNull);
      expect(stored!.exportedImagePath, written);
    });

    test('does not touch the DAO when the result has no id', () async {
      final result = _sampleResult(id: null, width: 8, height: 8);
      final out = p.join(tempDir.path, 'unpersisted.png');

      // No row exists; the export must still succeed and simply skip the stamp.
      final written = await service().exportImage(
        result: result,
        rgba: _rgbaRamp(8, 8),
        format: ShareExportFormat.png,
        outputPath: out,
      );
      expect(File(written).existsSync(), isTrue);
      expect(await resultsDao.getRecentResults(), isEmpty);
    });

    test(
      'remote export does not stamp a controller-local row with the same id',
      () async {
        final local = _sampleResult(
          id: null,
          width: 8,
          height: 8,
        ).copyWith(exportedImagePath: '/host/canonical.png');
        final id = await resultsDao.insertResult(local);
        final remote = _sampleResult(id: id, width: 8, height: 8);

        await service().exportImage(
          result: remote,
          rgba: _rgbaRamp(8, 8),
          format: ShareExportFormat.png,
          outputPath: p.join(tempDir.path, 'controller-export.png'),
          stampPersistedResult: false,
        );

        final stored = await resultsDao.getResultById(id);
        expect(stored!.exportedImagePath, '/host/canonical.png');
      },
    );

    test('throws on a mis-sized RGBA buffer', () async {
      final result = _sampleResult(width: 16, height: 12);
      final tooShort = Uint8List(16 * 12 * 4 - 8);
      expect(
        () => service().exportImage(
          result: result,
          rgba: tooShort,
          format: ShareExportFormat.png,
          outputPath: p.join(tempDir.path, 'bad.png'),
        ),
        throwsA(isA<ShareExportBufferException>()),
      );
    });

    test('throws when a share card is requested without a spec', () async {
      final result = _sampleResult(width: 8, height: 8);
      expect(
        () => service().exportImage(
          result: result,
          rgba: _rgbaRamp(8, 8),
          format: ShareExportFormat.shareCard,
          outputPath: p.join(tempDir.path, 'card.png'),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on an out-of-range JPEG quality', () async {
      final result = _sampleResult(width: 8, height: 8);
      expect(
        () => service().exportImage(
          result: result,
          rgba: _rgbaRamp(8, 8),
          format: ShareExportFormat.jpeg,
          outputPath: p.join(tempDir.path, 'q.jpg'),
          jpegQuality: 0,
        ),
        throwsA(isA<RangeError>()),
      );
    });
  });

  group('buildAstroBinMetadata', () {
    EquipmentProfileModel profile() => const EquipmentProfileModel(
      id: 1,
      name: 'Rig',
      telescopeName: 'Esprit 100ED',
      telescopeFocalLength: 550,
      telescopeAperture: 100,
      cameraName: 'ASI2600MM Pro',
      focalLength: 550,
      aperture: 100,
    );

    test('fills equipment from the supplied profile and run', () {
      final meta = service().buildAstroBinMetadata(
        result: _sampleResult(),
        profile: profile(),
      );
      expect(meta.title, 'M51');
      expect(meta.frames, 38);
      expect(meta.integrationSecs, 4560);
      expect(meta.telescope, 'Esprit 100ED');
      expect(meta.camera, 'ASI2600MM Pro');
      expect(meta.filter, 'L');
      expect(meta.focalLength, 550);
      expect(meta.aperture, 100);
      expect(meta.focalRatio, closeTo(5.5, 1e-9));
    });

    test('prefers profile-level (effective) optics over bare telescope optics '
        'so a reducer/barlow reports the imaging focal length', () {
      // Esprit 100ED (550mm f/5.5) imaged through a 0.8x reducer: the profile's
      // effective focal length is 440mm (f/4.4). AstroBin acquisition data must
      // report the imaging value, not the bare telescope.
      const reducerProfile = EquipmentProfileModel(
        id: 2,
        name: 'Rig + reducer',
        telescopeName: 'Esprit 100ED',
        telescopeFocalLength: 550,
        telescopeAperture: 100,
        cameraName: 'ASI2600MM Pro',
        focalLength: 440,
        aperture: 100,
      );
      final meta = service().buildAstroBinMetadata(
        result: _sampleResult(),
        profile: reducerProfile,
      );
      expect(meta.focalLength, 440);
      expect(meta.aperture, 100);
      expect(meta.focalRatio, closeTo(4.4, 1e-9));
    });

    test('falls back to bare telescope optics when the profile-level value is '
        'unset', () {
      // A profile that never recorded a profile-level focal length (0.0 =
      // unset) should still report the telescope optics rather than null.
      const teleOnlyProfile = EquipmentProfileModel(
        id: 3,
        name: 'Telescope only',
        telescopeName: 'RC8',
        telescopeFocalLength: 1624,
        telescopeAperture: 203,
        cameraName: 'QHY268M',
        focalLength: 0,
        aperture: 0,
      );
      final meta = service().buildAstroBinMetadata(
        result: _sampleResult(),
        profile: teleOnlyProfile,
      );
      expect(meta.focalLength, 1624);
      expect(meta.aperture, 203);
    });

    test('falls back to the active profile when none is supplied', () {
      final scoped = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          activeEquipmentProfileProvider.overrideWithValue(profile()),
        ],
      );
      addTearDown(scoped.dispose);
      final svc = StackShareExportService(
        scoped.read(_refProvider),
        savePng: savePng,
        saveJpeg: saveJpeg,
      );
      final meta = svc.buildAstroBinMetadata(result: _sampleResult());
      expect(meta.telescope, 'Esprit 100ED');
      expect(meta.camera, 'ASI2600MM Pro');
    });

    test('leaves equipment null when no profile is active', () {
      final meta = service().buildAstroBinMetadata(result: _sampleResult());
      expect(meta.telescope, isNull);
      expect(meta.camera, isNull);
      expect(meta.focalLength, isNull);
      expect(meta.aperture, isNull);
      // Run-derived fields are still present.
      expect(meta.frames, 38);
      expect(meta.integrationSecs, 4560);
    });

    test('markdown carries HMS integration, frame count, and equipment', () {
      final meta = service().buildAstroBinMetadata(
        result: _sampleResult(),
        profile: profile(),
      );
      final md = meta.toMarkdown();
      expect(md, contains('## M51'));
      expect(md, contains('**Integration:** 01:16:00'));
      expect(md, contains('**Frames:** 38'));
      expect(md, contains('Esprit 100ED'));
      expect(md, contains('ASI2600MM Pro'));
      expect(md, contains('f/5.5'));
    });
  });

  group('exportAstroBinAcquisition', () {
    AstroBinExportMetadata rigMeta() => service().buildAstroBinMetadata(
      result: _sampleResult(),
      profile: const EquipmentProfileModel(
        id: 1,
        name: 'Rig',
        telescopeName: 'RC8',
        telescopeFocalLength: 1624,
        telescopeAperture: 203,
        cameraName: 'QHY268M',
        focalLength: 1624,
        aperture: 203,
      ),
      acquisitionDate: DateTime(2026, 7, 30, 22, 15),
    );

    test('a .csv request writes the CSV the user asked for', () async {
      // The whole point of the button: a .csv request writes one file the
      // AstroBin importer reads, not a .json + .md pair.
      final csvPath = p.join(tempDir.path, 'rsr-astrobin.csv');

      final written = await service().exportAstroBinAcquisition(
        meta: rigMeta(),
        outputPath: csvPath,
      );

      expect(written, csvPath);
      expect(File(csvPath).existsSync(), isTrue);
      expect(
        File(p.join(tempDir.path, 'rsr-astrobin.json')).existsSync(),
        isFalse,
      );

      final rows = File(csvPath).readAsLinesSync();
      expect(rows.first, 'date,number,duration');
      // 38 frames x 120 s on the night of 2026-07-30.
      expect(rows[1], '2026-07-30,38,120');
    });

    test('the copy-paste block is still written beside the CSV', () async {
      final csvPath = p.join(tempDir.path, 'rsr-astrobin.csv');
      await service().exportAstroBinAcquisition(
        meta: rigMeta(),
        outputPath: csvPath,
      );

      final md = File(
        p.join(tempDir.path, 'rsr-astrobin.md'),
      ).readAsStringSync();
      expect(md, contains('**Date:** 2026-07-30'));
      expect(md, contains('**Integration:** 01:16:00'));
      expect(md, contains('RC8'));
    });

    test('a .json request writes the payload and it round-trips', () async {
      final meta = rigMeta();
      final jsonPath = p.join(tempDir.path, 'm51.json');

      final written = await service().exportAstroBinAcquisition(
        meta: meta,
        outputPath: jsonPath,
      );

      expect(written, jsonPath);
      final decoded =
          jsonDecode(File(jsonPath).readAsStringSync()) as Map<String, dynamic>;
      expect(AstroBinExportMetadata.fromJson(decoded), meta);
    });

    test('an image path still drops the Markdown block beside it', () async {
      final meta = service().buildAstroBinMetadata(result: _sampleResult());
      final imagePath = p.join(tempDir.path, 'a', 'b', 'm51.jpg');

      final written = await service().exportAstroBinAcquisition(
        meta: meta,
        outputPath: imagePath,
      );

      expect(written, p.join(tempDir.path, 'a', 'b', 'm51.md'));
      expect(File(written).existsSync(), isTrue);
      // Nothing is written over the image itself.
      expect(File(imagePath).existsSync(), isFalse);
    });
  });
}

/// Exposes the enclosing [ProviderContainer]'s [Ref] to construct services that
/// take a `Ref`. A throwaway provider whose body simply returns its own `ref`.
final _refProvider = Provider<Ref>((ref) => ref);
