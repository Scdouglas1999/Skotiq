import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:path/path.dart' as p;

import '../database/daos/stacked_results_dao.dart';
import '../models/imaging/stack_and_share_models.dart';
import '../providers/profiles_provider.dart';
import '../utils/skotiq_data_directory.dart';
import 'logging_service.dart';
import 'share_card_renderer.dart';

/// Signature of the function used to persist an 8-bit RGBA buffer as a PNG.
///
/// Defaults to the native bridge ([bridge.apiSaveRgbaPngFile]); injectable so
/// the export path is unit-testable without loading the Rust dynamic library
/// (tests substitute the pure-Dart [ShareCardRenderer]/`image` encoder).
typedef SaveRgbaPng =
    Future<void> Function({
      required String filePath,
      required int width,
      required int height,
      required List<int> rgba,
    });

/// Signature of the function used to persist an 8-bit RGBA buffer as a JPEG.
///
/// Defaults to the native bridge ([bridge.apiSaveRgbaJpegFile]); injectable for
/// the same reason as [SaveRgbaPng].
typedef SaveRgbaJpeg =
    Future<void> Function({
      required String filePath,
      required int width,
      required int height,
      required List<int> rgba,
      required int quality,
    });

/// Thrown when a Stack-and-Share export is requested with an RGBA buffer whose
/// length does not match `width * height * 4`.
///
/// A length mismatch is an upstream programming error (wrong stride, truncated
/// buffer), surfaced here at the Dart boundary with the offending dimensions
/// rather than handed to the encoder, which would write a plausible-looking but
/// garbage image.
class ShareExportBufferException implements Exception {
  /// Human-readable explanation suitable for direct display.
  final String message;

  const ShareExportBufferException(this.message);

  @override
  String toString() => 'ShareExportBufferException: $message';
}

/// File generation for the **Stack-and-Share Loop** (component C8).
///
/// Owns turning a completed [StackAndShareResult] (plus its stretched RGBA
/// pixels) into share-ready artifacts on disk, and building the AstroBin-style
/// acquisition sidecar that accompanies them:
///
///  * [exportImage] writes the stacked master as PNG, JPEG, or an annotated
///    share card to an explicit path, then stamps that path back onto the
///    persisted result via [StackedResultsDao.updateExportedPath].
///  * [buildAstroBinMetadata] fills the equipment block from the active
///    equipment profile (telescope / camera / focal length / aperture) and the
///    run's frames / integration / filter.
///  * [exportAstroBinAcquisition] writes the acquisition export in the format
///    the chosen filename asks for — AstroBin's import CSV, the JSON payload,
///    or the copy-paste Markdown block — plus the Markdown block beside it.
///
/// **Why no OS-share call here:** `share_plus` lives in the UI packages'
/// pubspecs, not `skotiq_core`. To respect the package boundary, this
/// service only *generates* the file and returns its path; the actual
/// `Share.shareXFiles(...)` invocation is performed by the screen layer.
/// This keeps `skotiq_core` free of a Flutter-plugin dependency it would
/// otherwise have to take on solely for one call site.
///
/// **Why a file rather than an upload:** AstroBin exposes no open public API
/// for unattended image upload. The honest, non-stub deliverable is therefore
/// the acquisition CSV its importer reads, plus the Markdown block for a
/// description or a forum post — a real, complete export, not a placeholder for
/// a non-existent API.
///
/// The PNG/JPEG save paths delegate to the native bridge by default (so the
/// pixel write matches every other image export in the app), but the save
/// functions are injectable so this service is unit-testable without the Rust
/// dynamic library loaded.
class StackShareExportService {
  StackShareExportService(
    this._ref, {
    SaveRgbaPng? savePng,
    SaveRgbaJpeg? saveJpeg,
    ShareCardRenderer cardRenderer = const ShareCardRenderer(),
    Future<Directory> Function()? applicationSupportDirectoryProvider,
  }) : _savePng = savePng ?? bridge.apiSaveRgbaPngFile,
       _saveJpeg = saveJpeg ?? bridge.apiSaveRgbaJpegFile,
       _cardRenderer = cardRenderer,
       _applicationSupportDirectoryProvider =
           applicationSupportDirectoryProvider ??
           resolveSkotiqDataDirectory;

  final Ref _ref;
  final SaveRgbaPng _savePng;
  final SaveRgbaJpeg _saveJpeg;
  final ShareCardRenderer _cardRenderer;
  final Future<Directory> Function() _applicationSupportDirectoryProvider;

  LoggingService get _logger => _ref.read(loggingServiceProvider);
  StackedResultsDao get _resultsDao => _ref.read(stackedResultsDaoProvider);

  /// Canonical host-local path for a result's durable viewer preview.
  ///
  /// This is intentionally separate from a user-selected export destination:
  /// later PNG/JPEG/share-card exports may update `exportedImagePath`, but the
  /// application-owned preview remains stable and reopenable.
  Future<String> viewerPreviewPath(int resultId) async {
    if (resultId <= 0) {
      throw ArgumentError.value(resultId, 'resultId', 'must be positive');
    }
    final support = await _applicationSupportDirectoryProvider();
    return p.normalize(
      p.absolute(
        p.join(
          support.path,
          'stack_and_share',
          'results',
          'result_$resultId.png',
        ),
      ),
    );
  }

  /// Persist the canonical lossless preview used by result history and remote
  /// viewers. The write is staged to a sibling partial file and renamed only
  /// after validation, so a crash or encoder failure cannot leave a corrupt
  /// path attached to an otherwise successful database row.
  Future<String> persistViewerPreview({
    required StackAndShareResult result,
    required Uint8List rgba,
  }) async {
    final id = result.id;
    if (id == null || id <= 0) {
      throw StateError(
        'A stacked result must be persisted before its viewer preview is saved.',
      );
    }

    _validateBuffer(rgba: rgba, width: result.width, height: result.height);
    final outputPath = await viewerPreviewPath(id);
    // The native image writer infers PNG from the filename extension, so the
    // staging name must still end in `.png` (a `.partial` suffix would make the
    // Rust `image` encoder reject the path as an unknown format).
    final partialPath = '$outputPath.partial.png';
    await _ensureParentDirectory(outputPath);

    try {
      final partial = File(partialPath);
      if (await partial.exists()) {
        await partial.delete();
      }
      await _savePng(
        filePath: partialPath,
        width: result.width,
        height: result.height,
        rgba: rgba,
      );
      await _verifyWritten(partialPath, ShareExportFormat.png);

      final output = File(outputPath);
      if (await output.exists()) {
        await output.delete();
      }
      await partial.rename(outputPath);

      final updated = await _resultsDao.updateExportedPath(id, outputPath);
      if (updated != 1) {
        throw StateError(
          'Stacked result $id disappeared before its viewer preview could be '
          'linked.',
        );
      }
    } catch (e) {
      _logger.error(
        'Failed to write the Stack-and-Share viewer preview for result $id to '
        '$outputPath: $e',
        source: 'StackShareExportService',
      );
      for (final path in [partialPath, outputPath]) {
        try {
          final file = File(path);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (cleanupError) {
          // Cleanup must never replace the export failure being rethrown, but
          // a file we could not remove is a stale artifact the operator would
          // otherwise find on disk with no record of why it is there.
          _logger.warning(
            'Could not remove partial Stack-and-Share export $path after a '
            'failed write: $cleanupError',
            source: 'StackShareExportService',
          );
        }
      }
      rethrow;
    }

    _logger.info(
      'Persisted Stack-and-Share viewer preview to $outputPath '
      '(${result.width}x${result.height})',
      source: 'StackShareExportService',
    );
    return outputPath;
  }

  /// Export [result]'s stacked master to [outputPath] in the requested
  /// [format], returning the absolute path written.
  ///
  /// [rgba] is the already-stretched 8-bit RGBA display buffer for the
  /// integration (tightly packed `R,G,B,A`, `result.width * result.height * 4`
  /// bytes long); it is typically [StackAndShareService.lastRgbaResult]'s pixels.
  ///
  ///  * [ShareExportFormat.png] / [ShareExportFormat.jpeg] write the bare
  ///    stacked master (no overlay) via the native bridge save path.
  ///  * [ShareExportFormat.shareCard] composites the watermark + stat overlay
  ///    described by [cardSpec] onto the image with [ShareCardRenderer] and
  ///    writes the resulting bytes to disk. The card's file format follows the
  ///    [outputPath] extension: a `.jpg`/`.jpeg` path emits JPEG (honouring
  ///    [jpegQuality]); anything else emits PNG.
  ///
  /// When [result] has a persisted [StackAndShareResult.id], the written path is
  /// stamped onto its row via [StackedResultsDao.updateExportedPath] so the
  /// stacked master can be re-shared later. Set [stampPersistedResult] false
  /// when exporting a result whose id belongs to a remote imaging host; this
  /// prevents an unrelated controller-local row with the same integer id from
  /// being modified.
  ///
  /// Throws [ShareExportBufferException] when [rgba] is shorter than
  /// `width * height * 4`, [ArgumentError] when [format] is
  /// [ShareExportFormat.shareCard] but no [cardSpec] is supplied, and
  /// [RangeError] when [jpegQuality] is outside `[1, 100]`.
  Future<String> exportImage({
    required StackAndShareResult result,
    required Uint8List rgba,
    required ShareExportFormat format,
    required String outputPath,
    ShareCardSpec? cardSpec,
    int jpegQuality = 92,
    bool stampPersistedResult = true,
  }) async {
    final width = result.width;
    final height = result.height;
    _validateBuffer(rgba: rgba, width: width, height: height);

    final absolutePath = p.normalize(p.absolute(outputPath));
    await _ensureParentDirectory(absolutePath);

    switch (format) {
      case ShareExportFormat.png:
        await _savePng(
          filePath: absolutePath,
          width: width,
          height: height,
          rgba: rgba,
        );
      case ShareExportFormat.jpeg:
        _validateJpegQuality(jpegQuality);
        await _saveJpeg(
          filePath: absolutePath,
          width: width,
          height: height,
          rgba: rgba,
          quality: jpegQuality,
        );
      case ShareExportFormat.shareCard:
        if (cardSpec == null) {
          throw ArgumentError.notNull('cardSpec');
        }
        await _writeShareCard(
          width: width,
          height: height,
          rgba: rgba,
          spec: cardSpec,
          outputPath: absolutePath,
          jpegQuality: jpegQuality,
        );
    }

    await _verifyWritten(absolutePath, format);

    final id = result.id;
    if (stampPersistedResult && id != null) {
      final updated = await _resultsDao.updateExportedPath(id, absolutePath);
      if (updated == 0) {
        // The result claims a persisted id but no row matched — a stale id is a
        // genuine inconsistency, not a benign miss, so log it rather than
        // silently dropping the provenance link.
        _logger.warning(
          'Stack-and-Share export stamped path on result id $id but no '
          'stacked_results row was updated (stale id).',
          source: 'StackShareExportService',
        );
      }
    }

    _logger.info(
      'Stack-and-Share exported ${format.name} to $absolutePath '
      '(${width}x$height)',
      source: 'StackShareExportService',
    );
    return absolutePath;
  }

  /// Composite [spec]'s overlay onto the RGBA buffer and write the share card.
  ///
  /// The output format follows the [outputPath] extension: `.jpg`/`.jpeg`
  /// emit JPEG (honouring [jpegQuality]); every other extension emits PNG so a
  /// `.png` path stays lossless.
  Future<void> _writeShareCard({
    required int width,
    required int height,
    required Uint8List rgba,
    required ShareCardSpec spec,
    required String outputPath,
    required int jpegQuality,
  }) async {
    final ext = p.extension(outputPath).toLowerCase();
    final isJpeg = ext == '.jpg' || ext == '.jpeg';
    final Uint8List bytes;
    if (isJpeg) {
      _validateJpegQuality(jpegQuality);
      bytes = _cardRenderer.renderJpegFromRgba(
        width: width,
        height: height,
        rgba: rgba,
        spec: spec,
        quality: jpegQuality,
      );
    } else {
      bytes = _cardRenderer.renderPngFromRgba(
        width: width,
        height: height,
        rgba: rgba,
        spec: spec,
      );
    }
    await File(outputPath).writeAsBytes(bytes, flush: true);
  }

  /// Build the AstroBin-style acquisition metadata for [result].
  ///
  /// Equipment fields are taken from [profile] when supplied, otherwise from the
  /// active equipment profile ([activeEquipmentProfileProvider]). The telescope
  /// description prefers the explicit [EquipmentProfileModel.telescopeName],
  /// falling back to the camera-side optical-train fields; the camera comes from
  /// [EquipmentProfileModel.cameraName]. Focal length / aperture prefer the
  /// profile-level (effective, post-reducer/barlow) values, falling back to the
  /// bare telescope optics only when the profile value is unset.
  ///
  /// Frames, total integration, filter, and title come from the run [result]
  /// itself. Nothing is fabricated — a field with no source stays null so the
  /// acquisition block omits it rather than printing a guess.
  AstroBinExportMetadata buildAstroBinMetadata({
    required StackAndShareResult result,
    EquipmentProfileModel? profile,
    DateTime? acquisitionDate,
  }) {
    final p0 = profile ?? _ref.read(activeEquipmentProfileProvider);

    final telescope = _firstNonEmpty([p0?.telescopeName]);
    final camera = _firstNonEmpty([p0?.cameraName]);

    // Prefer the profile-level optical values — these are the *effective*
    // focal length / aperture of the imaging train (post reducer / barlow),
    // which is the true acquisition value AstroBin wants. Fall back to the bare
    // telescope optics only when the profile-level value is unset. This matches
    // the `EquipmentProfileExtension.effectiveFocalLength` convention used
    // elsewhere (base field preferred over the telescope field); preferring the
    // telescope value first would report the wrong focal length / f-ratio for
    // anyone using a focal reducer or barlow. A non-positive value is treated
    // as "unknown" so f-ratio math never divides by zero.
    final focalLength = _firstPositive([
      p0?.focalLength,
      p0?.telescopeFocalLength,
    ]);
    final aperture = _firstPositive([p0?.aperture, p0?.telescopeAperture]);

    return AstroBinExportMetadata(
      title: result.targetName,
      integrationSecs: result.integrationSecs,
      frames: result.framesStacked,
      telescope: telescope,
      camera: camera,
      filter: result.filter,
      focalLength: focalLength,
      aperture: aperture,
      // The night the subs were taken when the caller can resolve it (the
      // session's start time); otherwise the run's own timestamp, which for the
      // usual stack-it-now flow is the same night.
      date: acquisitionDate ?? result.createdAt,
    );
  }

  /// Write the AstroBin acquisition export for [meta] to [outputPath].
  ///
  /// The format follows the extension the caller asked for, because ignoring it
  /// is how this ended up writing `rsr-astrobin.json` + `rsr-astrobin.md` for a
  /// user who typed `rsr-astrobin.csv`:
  ///
  ///  * `.csv` — AstroBin's acquisition CSV ([toAstroBinCsv]), the one file the
  ///    importer accepts;
  ///  * `.json` — the machine-readable payload ([toJson]);
  ///  * anything else (including an image path, so a sidecar can still be
  ///    dropped beside an exported PNG) — the copy-paste Markdown block
  ///    ([toMarkdown]), written to `<base>.md`.
  ///
  /// A non-Markdown primary also gets the `<base>.md` block beside it, so the
  /// forum-post text is never lost by choosing the importable format. Returns
  /// the path actually written for the requested format.
  Future<String> exportAstroBinAcquisition({
    required AstroBinExportMetadata meta,
    required String outputPath,
  }) async {
    final absolutePath = p.normalize(p.absolute(outputPath));
    await _ensureParentDirectory(absolutePath);

    final dir = p.dirname(absolutePath);
    final base = p.basenameWithoutExtension(absolutePath);
    final markdownPath = p.join(dir, '$base.md');
    final ext = p.extension(absolutePath).toLowerCase();

    final csv = meta.toAstroBinCsv();
    final String primaryPath;
    if (ext == '.csv' && csv != null) {
      primaryPath = absolutePath;
      await File(primaryPath).writeAsString(csv, flush: true);
    } else if (ext == '.json') {
      primaryPath = absolutePath;
      await File(primaryPath).writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(meta.toJson())}\n',
        flush: true,
      );
    } else {
      primaryPath = markdownPath;
    }

    await File(
      markdownPath,
    ).writeAsString('${meta.toMarkdown()}\n', flush: true);

    _logger.info(
      'Stack-and-Share wrote AstroBin acquisition export: $primaryPath',
      source: 'StackShareExportService',
    );
    return primaryPath;
  }

  // Helpers

  void _validateBuffer({
    required Uint8List rgba,
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0) {
      throw ShareExportBufferException(
        'Stack-and-Share export has non-positive dimensions '
        '(width=$width height=$height)',
      );
    }
    final expected = width * height * 4;
    if (rgba.length != expected) {
      throw ShareExportBufferException(
        'Stack-and-Share RGBA buffer length ${rgba.length} != expected '
        '$expected (width=$width height=$height x 4 channels)',
      );
    }
  }

  void _validateJpegQuality(int quality) {
    if (quality < 1 || quality > 100) {
      throw RangeError.range(quality, 1, 100, 'jpegQuality');
    }
  }

  Future<void> _ensureParentDirectory(String absolutePath) async {
    final parent = Directory(p.dirname(absolutePath));
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
  }

  /// Assert the export actually produced a non-empty file. A zero-byte image is
  /// a silent corruption a user would only discover when the share fails, so we
  /// catch it here at the source.
  Future<void> _verifyWritten(String path, ShareExportFormat format) async {
    final file = File(path);
    if (!await file.exists()) {
      throw StateError(
        'Stack-and-Share ${format.name} export reported success but no file '
        'exists at $path',
      );
    }
    final length = await file.length();
    if (length <= 0) {
      throw StateError(
        'Stack-and-Share ${format.name} export wrote an empty file at $path',
      );
    }
  }

  /// First trimmed, non-empty string in [candidates], or null when none qualify.
  String? _firstNonEmpty(List<String?> candidates) {
    for (final candidate in candidates) {
      final trimmed = candidate?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  /// First strictly-positive value in [candidates], or null when none qualify.
  double? _firstPositive(List<double?> candidates) {
    for (final candidate in candidates) {
      if (candidate != null && candidate > 0) return candidate;
    }
    return null;
  }
}

/// Provider for the [StackShareExportService].
///
/// Reads the results DAO, active equipment profile, and logging providers
/// lazily inside the service so it follows the same Drift instance and backend
/// as the rest of the app, and so test overrides flow through. The save
/// functions default to the native bridge; tests construct the service directly
/// with pure-Dart substitutes.
final stackShareExportServiceProvider = Provider<StackShareExportService>((
  ref,
) {
  return StackShareExportService(ref);
});
