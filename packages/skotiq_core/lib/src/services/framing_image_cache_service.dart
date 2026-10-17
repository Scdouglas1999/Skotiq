import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../providers/framing_provider.dart' show SurveySource;
import '../utils/skotiq_data_directory.dart';

/// Result of a [FramingImageCacheService.saveSurveyImage] call.
class FramingImageCacheEntry {
  /// Absolute path to the cached image file on disk.
  final String filePath;

  /// Size of the cached image in bytes.
  final int sizeBytes;

  /// When the image was written.
  final DateTime savedAt;

  const FramingImageCacheEntry({
    required this.filePath,
    required this.sizeBytes,
    required this.savedAt,
  });
}

/// Persists survey background images fetched by the framing assistant.
///
/// Survey images (DSS2, SDSS, 2MASS, WISE, ...) are downloaded over the
/// network from Aladin HiPS2FITS or NASA SkyView. The framing screen has a
/// "Cache Image" action that lets the user pin the currently-displayed
/// survey snapshot so it survives app restart and offline use.
///
/// Cache layout under the application support directory:
/// ```
/// <appSupport>/framing_cache/
///   <ra>_<dec>_<survey>.jpg
/// ```
///
/// The filename is fully derived from the target coordinates and survey
/// source, so re-caching the same target/survey overwrites the previous
/// snapshot. Coordinates are quantised to ~arcsec resolution (RA: 5 frac
/// digits of hours, Dec: 4 frac digits of degrees) so floating-point drift
/// across sessions does not produce phantom cache misses.
class FramingImageCacheService {
  /// Optional override for the application-support directory provider. Tests
  /// can inject a temporary directory; production passes `null` to use
  /// [resolveSkotiqDataDirectory].
  final Future<Directory> Function()? _supportDirProvider;

  /// Subdirectory under app support where framing images live.
  static const String _cacheDirName = 'framing_cache';

  FramingImageCacheService({Future<Directory> Function()? supportDirProvider})
    : _supportDirProvider = supportDirProvider;

  Future<Directory> _resolveSupportDir() async {
    final provider = _supportDirProvider;
    if (provider != null) {
      return provider();
    }
    return resolveSkotiqDataDirectory();
  }

  /// Returns the absolute path of the cache directory, creating it on demand.
  Future<Directory> ensureCacheDirectory() async {
    final support = await _resolveSupportDir();
    final cacheDir = Directory(p.join(support.path, _cacheDirName));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  /// Build the deterministic cache filename for a given target + survey.
  ///
  /// Coordinates are formatted with fixed precision to keep filenames
  /// stable across runs even when the framing provider rounds slightly
  /// differently each time. The survey code matches the enum's
  /// [SurveySource.surveyCode] (e.g. `DSS2R`, `SDSSg`, `WISE12`).
  String buildFilename({
    required double raHours,
    required double decDegrees,
    required SurveySource source,
    String extension = 'jpg',
  }) {
    // Normalise RA to [0, 24) so wrap-around values produce a stable name.
    var ra = raHours % 24.0;
    if (ra < 0) ra += 24.0;
    final raToken = ra.toStringAsFixed(5).replaceAll('.', 'p');

    final dec = decDegrees.clamp(-90.0, 90.0);
    final decSign = dec >= 0 ? 'P' : 'M';
    final decToken =
        '$decSign${dec.abs().toStringAsFixed(4).replaceAll('.', 'p')}';

    final ext = extension.startsWith('.') ? extension.substring(1) : extension;
    return '${raToken}_${decToken}_${source.surveyCode}.$ext';
  }

  /// Resolve the absolute path that [saveSurveyImage] would write to.
  Future<String> resolvePath({
    required double raHours,
    required double decDegrees,
    required SurveySource source,
    String extension = 'jpg',
  }) async {
    final dir = await ensureCacheDirectory();
    return p.join(
      dir.path,
      buildFilename(
        raHours: raHours,
        decDegrees: decDegrees,
        source: source,
        extension: extension,
      ),
    );
  }

  /// Persist [bytes] as the survey snapshot for the given target/source.
  ///
  /// Returns the on-disk metadata for the freshly-written file. Throws on
  /// IO failure (callers should surface the error to the user — silent
  /// fallbacks hide real bugs, ).
  ///
  /// A sidecar `.meta.json` file is written alongside each image carrying
  /// the human-readable target name and the precise RA/Dec/source it was
  /// pinned for. This lets future "browse cached frames" UIs reconstruct
  /// the target without re-parsing the filename hash.
  Future<FramingImageCacheEntry> saveSurveyImage({
    required Uint8List bytes,
    required double raHours,
    required double decDegrees,
    required SurveySource source,
    String? targetName,
    String? catalogId,
    String extension = 'jpg',
  }) async {
    if (bytes.isEmpty) {
      throw ArgumentError(
        'Survey image bytes are empty — refusing to write a zero-byte file.',
      );
    }

    final dir = await ensureCacheDirectory();
    final filename = buildFilename(
      raHours: raHours,
      decDegrees: decDegrees,
      source: source,
      extension: extension,
    );
    final filePath = p.join(dir.path, filename);
    final tmpPath = '$filePath.tmp';

    // Write atomically: write to .tmp then rename. Avoids leaving a
    // half-written image if the process is killed mid-flush.
    final tmp = File(tmpPath);
    await tmp.writeAsBytes(bytes, flush: true);
    final target = File(filePath);
    if (await target.exists()) {
      await target.delete();
    }
    await tmp.rename(filePath);

    final savedAt = DateTime.now();

    // Sidecar metadata.
    final metaPath = '$filePath.meta.json';
    final meta = <String, Object?>{
      'raHours': raHours,
      'decDegrees': decDegrees,
      'survey': source.name,
      'surveyCode': source.surveyCode,
      'savedAtIso': savedAt.toIso8601String(),
      'sizeBytes': bytes.length,
      if (targetName != null) 'targetName': targetName,
      if (catalogId != null) 'catalogId': catalogId,
    };
    try {
      await File(metaPath).writeAsString(jsonEncode(meta), flush: true);
    } catch (e, stack) {
      // Sidecar is best-effort: the image is the source of truth. Log the
      // failure but do not fail the save — the on-disk image is already good.
      developer.log(
        'FramingImageCacheService: failed to write sidecar metadata at $metaPath: $e',
        name: 'FramingImageCache',
        level: 900,
        error: e,
        stackTrace: stack,
      );
    }

    return FramingImageCacheEntry(
      filePath: filePath,
      sizeBytes: bytes.length,
      savedAt: savedAt,
    );
  }

  /// Look up a previously-cached survey image. Returns null when no cache
  /// entry exists for the requested target+source.
  Future<File?> loadCachedSurveyImage({
    required double raHours,
    required double decDegrees,
    required SurveySource source,
    String extension = 'jpg',
  }) async {
    final dir = await ensureCacheDirectory();
    final file = File(
      p.join(
        dir.path,
        buildFilename(
          raHours: raHours,
          decDegrees: decDegrees,
          source: source,
          extension: extension,
        ),
      ),
    );
    if (await file.exists()) {
      return file;
    }
    return null;
  }

  /// Enumerate all cached survey images on disk. Useful for diagnostics and
  /// a future "Manage cached previews" UI.
  Future<List<FramingImageCacheEntry>> listCachedImages() async {
    final dir = await ensureCacheDirectory();
    final out = <FramingImageCacheEntry>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.endsWith('.meta.json') || name.endsWith('.tmp')) continue;
      final stat = await entity.stat();
      out.add(
        FramingImageCacheEntry(
          filePath: entity.path,
          sizeBytes: stat.size,
          savedAt: stat.modified,
        ),
      );
    }
    return out;
  }

  /// Delete the cached survey image and its sidecar for the given target.
  /// Returns true if an entry was removed.
  Future<bool> removeCachedSurveyImage({
    required double raHours,
    required double decDegrees,
    required SurveySource source,
    String extension = 'jpg',
  }) async {
    final dir = await ensureCacheDirectory();
    final filePath = p.join(
      dir.path,
      buildFilename(
        raHours: raHours,
        decDegrees: decDegrees,
        source: source,
        extension: extension,
      ),
    );
    final file = File(filePath);
    var removed = false;
    if (await file.exists()) {
      await file.delete();
      removed = true;
    }
    final meta = File('$filePath.meta.json');
    if (await meta.exists()) {
      await meta.delete();
    }
    return removed;
  }
}
