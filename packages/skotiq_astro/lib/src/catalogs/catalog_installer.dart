import '../format/byte_format.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart' show protected, visibleForTesting;
import 'package:path/path.dart' as path;

import 'catalog_install_models.dart';
import 'catalog_transfer.dart';
import 'sky_catalog.dart';

/// The catalog files on disk: what is installed, and the one way a catalog
/// gets there or leaves (download, install from a file, uninstall, verify).
///
/// The desktop settings screen, the first-run prompt and the host's
/// `/api/catalog` routes all go through this class, so they share one download
/// (candidate fallback, checksum, stall and cancel handling), one metadata
/// sidecar and one progress feed.
class CatalogInstaller {
  /// How long to wait for response headers before abandoning a candidate.
  @visibleForTesting
  static Duration connectTimeout = const Duration(seconds: 30);

  /// How long a transfer may go without delivering a byte before it is
  /// declared stalled.
  @visibleForTesting
  static Duration streamIdleTimeout = const Duration(seconds: 60);

  /// How often a running download polls its cancellation token, independent of
  /// chunk arrival.
  @visibleForTesting
  static Duration cancelPollInterval = const Duration(seconds: 1);

  @visibleForTesting
  static http.Client Function() httpClientFactory = http.Client.new;

  /// Suffixes a download writes to before promoting the finished file.
  /// `.partial` is this class's; `.part` is the deep-star tile fetcher's, one
  /// per tile inside `deep_stars/`, which is why the sweep recurses.
  static const List<String> _abandonedDownloadSuffixes = ['.partial', '.part'];

  String? _directory;
  final _progress = StreamController<DownloadProgress>.broadcast();
  final _events = StreamController<CatalogEvent>.broadcast();
  final Map<SkyCatalog, DownloadProgress> _active = {};

  bool get isInitialized => _directory != null;

  String get catalogDirectory {
    final directory = _directory;
    if (directory == null) {
      throw StateError(
        'CatalogManager not initialized. Call initialize() first.',
      );
    }
    return directory;
  }

  /// Progress of every running install, for the catalog screens.
  Stream<DownloadProgress> get downloadProgress => _progress.stream;

  /// Installs in flight. Lives here rather than in a widget so a screen that
  /// is disposed and rebuilt mid-download can restore its progress bar.
  Map<SkyCatalog, DownloadProgress> get activeDownloads =>
      Map.unmodifiable(_active);

  /// Lifecycle events in the shape the host's WebSocket stream publishes.
  Stream<CatalogEvent> get events => _events.stream;

  /// Point the installer at [catalogDirectory], creating it if needed, and
  /// reclaim what an interrupted download left behind.
  ///
  /// [builtIn] holds the catalogs that ship inside the app, each with a
  /// function that reads its bytes. One that is not installed is installed
  /// from that copy, so it works offline from the first start. A copy that
  /// cannot be installed is logged and skipped: the catalog stays missing and
  /// can still be downloaded.
  Future<void> initialize(
    String catalogDirectory, {
    Map<SkyCatalog, Future<List<int>> Function()> builtIn = const {},
  }) async {
    _directory = catalogDirectory;
    final dir = Directory(catalogDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _log('initialized with directory: $catalogDirectory');
    await _sweepAbandonedPartials(dir);
    for (final MapEntry(key: catalog, value: read) in builtIn.entries) {
      if ((await status(catalog)).state != CatalogInstallStatus.missing) {
        continue;
      }
      try {
        await _installBuiltIn(catalog, await read());
      } catch (e) {
        _log(
          'the built-in ${catalog.displayName} could not be installed: $e',
          level: 1000,
        );
      }
    }
  }

  /// Install [catalog] from the copy that ships with the app. [bytes] must be
  /// the canonical file: anything that does not hash to [SkyCatalog.sha256]
  /// is refused with [CatalogHashMismatchException].
  Future<void> _installBuiltIn(SkyCatalog catalog, List<int> bytes) async {
    final tempFile = File(
      '${path.join(catalogDirectory, catalog.fileName)}.partial',
    );
    try {
      await tempFile.writeAsBytes(bytes, flush: true);
      await _installStagedFile(
        catalog,
        tempFile,
        expectedSha256: catalog.sha256,
        metadata: {'installedFrom': 'built-in'},
      );
    } finally {
      await _deleteQuietly(tempFile);
    }
  }

  /// Deletes the temp files a download that never finished left in the
  /// catalog directory, and returns the bytes reclaimed.
  ///
  /// Every download writes to `<name>.partial` and promotes it on success; the
  /// `finally` that removes it only runs if the process lives that long. A
  /// crash or a power cut during the GLADE+ download therefore strands the
  /// whole partial (observed: 407 MiB, six weeks old). A partial is never
  /// resumed, each attempt truncates it, so reclaiming it at startup is safe.
  /// Runs before any download this process starts, so it cannot race one.
  Future<int> _sweepAbandonedPartials(Directory dir) async {
    var reclaimed = 0;
    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        if (!_abandonedDownloadSuffixes.any(entity.path.endsWith)) continue;
        try {
          final size = await entity.length();
          await entity.delete();
          reclaimed += size;
          _log(
            'removed abandoned download ${entity.path} '
            '(${ByteFormat.size(size)} reclaimed)',
          );
        } catch (e) {
          // A locked or unreadable leftover is not worth failing startup over.
          _log('could not remove ${entity.path}: $e', level: 900);
        }
      }
    } catch (e) {
      _log('could not scan for abandoned downloads: $e', level: 900);
    }
    return reclaimed;
  }

  /// Path of [catalog]'s data file: the installed one (current or legacy
  /// name) when present, otherwise where it would be installed.
  String pathOf(SkyCatalog catalog) => path.join(
    catalogDirectory,
    catalog.resolveInstalledName(catalogDirectory),
  );

  Future<List<CatalogStatus>> statuses() async => [
    for (final catalog in SkyCatalog.values) await status(catalog),
  ];

  Future<CatalogStatus> status(SkyCatalog catalog) async {
    if (!isInitialized) return CatalogStatus.missing(catalog);
    final filePath = pathOf(catalog);
    final file = File(filePath);
    if (!await file.exists()) return CatalogStatus.missing(catalog);

    int fileSize;
    try {
      fileSize = await file.length();
    } on FileSystemException {
      return CatalogStatus(
        catalog: catalog,
        state: CatalogInstallStatus.corrupted,
        errors: const ['Failed to stat catalog file'],
      );
    }
    // A zero-byte file is the fingerprint of an interrupted install, not a
    // usable catalog.
    if (fileSize == 0) {
      return CatalogStatus(
        catalog: catalog,
        state: CatalogInstallStatus.corrupted,
        fileCount: 1,
        errors: const ['Catalog file is empty'],
      );
    }

    final metaFile = File(
      path.join(catalogDirectory, catalog.metadataFileName),
    );
    if (!await metaFile.exists()) {
      return CatalogStatus(
        catalog: catalog,
        state: CatalogInstallStatus.installed,
        installedPath: filePath,
        version: catalog.version,
        sizeBytes: fileSize,
        fileCount: 1,
      );
    }
    try {
      final raw = jsonDecode(await metaFile.readAsString());
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('metadata is not a JSON object');
      }
      return CatalogStatus(
        catalog: catalog,
        state: CatalogInstallStatus.installed,
        installedPath: filePath,
        version: raw['version'] as String? ?? catalog.version,
        sizeBytes: fileSize,
        fileCount: 2,
        installedAt: DateTime.tryParse(raw['installedDate']?.toString() ?? ''),
        lastVerified: DateTime.tryParse(raw['lastVerified']?.toString() ?? ''),
        expectedHash: raw['sha256'] as String?,
        objectCount: (raw['objectCount'] as num?)?.toInt(),
        annotationPackage: catalog == SkyCatalog.annotation
            ? AnnotationPackage.tryParse(raw['package'])
            : null,
      );
    } catch (e) {
      _log('status(${catalog.name}): malformed metadata: $e', level: 900);
      return CatalogStatus(
        catalog: catalog,
        state: CatalogInstallStatus.partial,
        installedPath: filePath,
        version: catalog.version,
        sizeBytes: fileSize,
        fileCount: 2,
        errors: const ['Metadata file is malformed'],
      );
    }
  }

  String? _baseUrlOverride;

  /// Base URL of the release that hosts the catalog assets: a self-hoster's
  /// mirror when one is set, otherwise [kCatalogReleaseBaseUrl].
  String get catalogBaseUrl => _baseUrlOverride ?? kCatalogReleaseBaseUrl;

  /// Point downloads at a mirror of the catalog release. An empty [url] goes
  /// back to [kCatalogReleaseBaseUrl]. Throws [ArgumentError] with the reason
  /// when [url] is not one ([catalogBaseUrlProblem]).
  void setCatalogBaseUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      _baseUrlOverride = null;
      return;
    }
    final problem = catalogBaseUrlProblem(trimmed);
    if (problem != null) throw ArgumentError.value(url, 'url', problem);
    _baseUrlOverride = trimmed;
  }

  /// Download and install [catalog].
  ///
  /// Candidates are tried in order (release asset, then upstream). One that
  /// fails on HTTP status, checksum, gunzip or an empty payload is discarded
  /// and the next is tried; a cancel ends the install. The bytes land in a
  /// `.partial` sibling and replace the installed file only once verified, so
  /// a failed or abandoned download leaves an existing install intact.
  ///
  /// [tier] selects the GLADE+ depth and is ignored for the other catalogs.
  /// Throws [CatalogCancelled] when [isCancelled] fires, otherwise the last
  /// candidate's error. Either way a terminal [DownloadProgress] and
  /// [CatalogEvent] have been published first.
  Future<CatalogInstallResult> install(
    SkyCatalog catalog, {
    AnnotationPackage tier = AnnotationPackage.standard,
    String? jobId,
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    if (!isInitialized) {
      throw StateError('CatalogManager not initialized');
    }
    if (_active.containsKey(catalog)) {
      throw CatalogDownloadException(
        phase: 'busy',
        message: '${catalog.displayName} is already downloading',
      );
    }

    void report(DownloadProgress progress) {
      if (progress.isTerminal) {
        _active.remove(catalog);
      } else {
        _active[catalog] = progress;
      }
      if (!_progress.isClosed) _progress.add(progress);
      onProgress?.call(progress);
    }

    final candidates = catalog.downloadCandidates(
      baseUrl: catalogBaseUrl,
      tier: tier,
    );
    final tempFile = File(
      '${path.join(catalogDirectory, catalog.fileName)}.partial',
    );

    report(DownloadProgress.starting(catalog));
    try {
      if (candidates.isEmpty) {
        throw CatalogDownloadException(
          phase: 'download',
          message: 'No download URL configured for ${catalog.displayName}',
        );
      }
      _log(
        'Starting download of ${catalog.displayName}; '
        'candidates: ${candidates.join(', ')}',
      );
      _events.add(
        CatalogEvent.downloadStarted(
          jobId: jobId,
          name: catalog.name,
          downloadUrl: candidates.first,
          totalBytes: catalog.approximateSizeBytes,
        ),
      );
      await Directory(catalogDirectory).create(recursive: true);

      int? bytesReceived;
      String? usedUrl;
      Object? lastError;
      var allUnreachable = true;
      for (var i = 0; i < candidates.length; i++) {
        final url = candidates[i];
        try {
          bytesReceived = await _fetch(
            catalog: catalog,
            url: url,
            tempFile: tempFile,
            jobId: jobId,
            report: report,
            isCancelled: isCancelled,
          );
          usedUrl = url;
          _log(
            '${catalog.displayName} downloaded from '
            '${i == 0 ? 'primary' : 'fallback'} candidate $url',
          );
          break;
        } on CatalogCancelled {
          rethrow;
        } catch (e) {
          lastError = e;
          if (e is! CatalogDownloadException || e.phase != 'network') {
            allUnreachable = false;
          }
          _log(
            'Candidate ${i + 1}/${candidates.length} for '
            '${catalog.displayName} ($url) failed: $e'
            '${i + 1 < candidates.length ? '; trying the next one' : ''}',
            level: 900,
          );
          // Never carry a partial from a failed candidate into the next try.
          await _deleteQuietly(tempFile);
        }
      }
      if (bytesReceived == null) {
        if (allUnreachable) {
          final hosts = {for (final url in candidates) Uri.parse(url).host};
          throw CatalogDownloadException(
            phase: 'network',
            message:
                'Could not reach ${hosts.join(' or ')}. '
                'Check the internet connection and try again.',
          );
        }
        throw lastError!;
      }

      final result = await _installStagedFile(
        catalog,
        tempFile,
        metadata: {
          'downloadUrl': usedUrl,
          if (catalog == SkyCatalog.annotation) ...{
            'package': tier.name,
            'magnitudeLimit': tier.magnitudeLimit,
          },
        },
      );
      _events.add(
        CatalogEvent.downloadComplete(
          jobId: jobId,
          name: catalog.name,
          version: result.version,
          sizeBytes: result.sizeBytes,
          sha256: result.sha256,
        ),
      );
      report(DownloadProgress.complete(catalog, bytesReceived));
      return result;
    } on CatalogCancelled {
      _log('Download of ${catalog.displayName} canceled');
      _events.add(
        CatalogEvent.downloadFailed(
          jobId: jobId,
          name: catalog.name,
          error: 'cancelled',
          phase: 'cancelled',
        ),
      );
      report(DownloadProgress.cancelled(catalog));
      rethrow;
    } catch (e, stackTrace) {
      developer.log(
        '[Catalog] Download of ${catalog.displayName} failed: $e',
        name: 'CatalogManager',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      _events.add(
        CatalogEvent.downloadFailed(
          jobId: jobId,
          name: catalog.name,
          error: e.toString(),
          phase: e is CatalogDownloadException ? e.phase : 'unknown',
        ),
      );
      report(DownloadProgress.failed(catalog, e.toString()));
      rethrow;
    } finally {
      // On success the partial has been renamed away already.
      await _deleteQuietly(tempFile);
    }
  }

  /// Fetch [url] into [tempFile] and verify the SHA-256 of the as-downloaded
  /// bytes before anything decodes them. Returns the bytes received.
  Future<int> _fetch({
    required SkyCatalog catalog,
    required String url,
    required File tempFile,
    required String? jobId,
    required void Function(DownloadProgress) report,
    required Future<bool> Function()? isCancelled,
  }) async {
    final client = httpClientFactory();
    try {
      return await _transfer(
        client,
        catalog: catalog,
        url: url,
        tempFile: tempFile,
        jobId: jobId,
        report: report,
        isCancelled: isCancelled,
      );
    } on http.ClientException catch (e) {
      throw _unreachable(url, e);
    } on SocketException catch (e) {
      throw _unreachable(url, e);
    } on TlsException catch (e) {
      throw _unreachable(url, e);
    } finally {
      client.close();
    }
  }

  CatalogDownloadException _unreachable(String url, Object cause) {
    _log('$url unreachable: $cause', level: 900);
    return CatalogDownloadException(
      phase: 'network',
      message:
          'Could not reach ${Uri.parse(url).host}. '
          'Check the internet connection and try again.',
    );
  }

  Future<int> _transfer(
    http.Client client, {
    required SkyCatalog catalog,
    required String url,
    required File tempFile,
    required String? jobId,
    required void Function(DownloadProgress) report,
    required Future<bool> Function()? isCancelled,
  }) async {
    final response = await sendCatalogRequest(
      client,
      http.Request('GET', Uri.parse(url)),
      timeout: connectTimeout,
      cancelPollInterval: cancelPollInterval,
      isCancelled: isCancelled,
    );
    if (response.statusCode != 200) {
      throw CatalogDownloadException(
        phase: 'http_send',
        message:
            'HTTP ${response.statusCode} downloading '
            '${catalog.displayName} from $url',
      );
    }
    final contentLength = response.contentLength ?? 0;

    var received = 0;
    var lastReported = 0;
    var lastEvent = DateTime.fromMillisecondsSinceEpoch(0);
    // Coalesced so a fast connection does not rebuild the screen per chunk.
    const reportEveryBytes = 512 * 1024;
    void onChunk(int length) {
      received += length;
      if (received - lastReported >= reportEveryBytes) {
        lastReported = received;
        report(
          DownloadProgress(
            catalog: catalog,
            progress: contentLength > 0 ? received / contentLength : 0,
            bytesReceived: received,
            totalBytes: contentLength,
            status:
                'Downloading... '
                '${ByteFormat.size(received)}',
          ),
        );
      }
      final now = DateTime.now();
      if (now.difference(lastEvent).inMilliseconds >= 1000) {
        lastEvent = now;
        _events.add(
          CatalogEvent.downloadProgress(
            jobId: jobId,
            name: catalog.name,
            downloadedBytes: received,
            totalBytes: contentLength > 0 ? contentLength : -1,
          ),
        );
      }
    }

    // Cancellation and stall detection come from the guard, not from chunk
    // arrival: a stalled connection produces no chunk to notice them on.
    final body = guardCatalogTransfer(
      response.stream,
      idleTimeout: streamIdleTimeout,
      cancelPollInterval: cancelPollInterval,
      isCancelled: isCancelled,
    );

    // Decided per URL: every HYG candidate ends in `.gz`, OpenNGC's do not.
    if (url.endsWith('.gz')) {
      // The compressed payload is small (HYG: 14 MB), so it is held in
      // memory, checked, and only then inflated.
      final compressed = BytesBuilder(copy: false);
      await for (final chunk in body) {
        compressed.add(chunk);
        onChunk(chunk.length);
      }
      final compressedBytes = compressed.takeBytes();
      if (!catalogBytesMatchSha256(catalog.sha256, compressedBytes)) {
        throw CatalogHashMismatchException(
          expected: catalog.sha256,
          actual: sha256.convert(compressedBytes).toString(),
        );
      }
      final List<int> inflated;
      try {
        inflated = gzip.decode(compressedBytes);
      } catch (e) {
        throw CatalogDownloadException(
          phase: 'decompress',
          message: 'Failed to gunzip ${catalog.displayName}: $e',
        );
      }
      await tempFile.writeAsBytes(inflated, flush: true);
    } else {
      // Straight to disk, hashed on the way: the GLADE+ complete tier is
      // about 2 GB and must never be held in memory.
      Digest? digest;
      final hashInput = sha256.startChunkedConversion(
        ChunkedConversionSink<Digest>.withCallback((d) => digest = d.single),
      );
      final sink = tempFile.openWrite();
      try {
        await for (final chunk in body) {
          sink.add(chunk);
          hashInput.add(chunk);
          onChunk(chunk.length);
        }
      } finally {
        await sink.close();
      }
      hashInput.close();
      if (!catalogSha256Matches(catalog.sha256, digest!.toString())) {
        throw CatalogHashMismatchException(
          expected: catalog.sha256,
          actual: digest!.toString(),
        );
      }
    }

    if (!await tempFile.exists() || await tempFile.length() == 0) {
      throw CatalogDownloadException(
        phase: 'verify',
        message: 'Downloaded ${catalog.displayName} is empty',
      );
    }
    return received;
  }

  /// Install [catalog] from a file already on this machine: a CSV the user
  /// picked, or an upload the host staged.
  ///
  /// The file is copied, never moved. With [expectedSha256] the copy is
  /// rejected with [CatalogHashMismatchException] unless it hashes to it.
  /// [tier] records which GLADE+ depth the file holds.
  Future<CatalogInstallResult> installFromFile(
    SkyCatalog catalog,
    File source, {
    String? expectedSha256,
    AnnotationPackage? tier,
  }) async {
    if (!isInitialized) {
      throw StateError('CatalogManager not initialized');
    }
    if (!await source.exists()) {
      throw FileSystemException('Source file does not exist', source.path);
    }
    await Directory(catalogDirectory).create(recursive: true);
    final tempFile = File(
      '${path.join(catalogDirectory, catalog.fileName)}.partial',
    );
    try {
      await source.copy(tempFile.path);
      if (await tempFile.length() == 0) {
        throw const CatalogDownloadException(
          phase: 'install_from_file',
          message: 'Source file is empty',
        );
      }
      final result = await _installStagedFile(
        catalog,
        tempFile,
        expectedSha256: expectedSha256,
        metadata: {
          'installedFrom': 'file',
          if (catalog == SkyCatalog.annotation && tier != null) ...{
            'package': tier.name,
            'magnitudeLimit': tier.magnitudeLimit,
          },
        },
      );
      _events.add(
        CatalogEvent.downloadComplete(
          name: catalog.name,
          version: result.version,
          sizeBytes: result.sizeBytes,
          sha256: result.sha256,
        ),
      );
      return result;
    } finally {
      await _deleteQuietly(tempFile);
    }
  }

  /// Promote a complete, non-empty [staged] file to [catalog]'s installed
  /// path and write its metadata sidecar.
  Future<CatalogInstallResult> _installStagedFile(
    SkyCatalog catalog,
    File staged, {
    String? expectedSha256,
    required Map<String, Object?> metadata,
  }) async {
    final (hash, sizeBytes, objectCount) = await _hashAndCount(staged);
    if (expectedSha256 != null && !catalogSha256Matches(expectedSha256, hash)) {
      throw CatalogHashMismatchException(
        expected: expectedSha256,
        actual: hash,
      );
    }

    final finalPath = path.join(catalogDirectory, catalog.fileName);
    // POSIX rename replaces in place; Windows rename throws when the
    // destination exists, so remove it first.
    final finalFile = File(finalPath);
    if (await finalFile.exists()) await finalFile.delete();
    await staged.rename(finalPath);

    // An upgraded install should not keep tens of MB of the previous file.
    for (final legacy in catalog.legacyFileNames) {
      await _deleteQuietly(File(path.join(catalogDirectory, legacy)));
    }

    final installedAt = DateTime.now().toUtc();
    await File(
      path.join(catalogDirectory, catalog.metadataFileName),
    ).writeAsString(
      jsonEncode({
        'source': catalog.displayName,
        'name': catalog.name,
        'version': catalog.version,
        'sha256': hash,
        'objectCount': objectCount,
        'sizeBytes': sizeBytes,
        'installedDate': installedAt.toIso8601String(),
        ...metadata,
      }),
    );
    catalogChanged(catalog);
    _log(
      '${catalog.displayName} installed: $objectCount objects, '
      '$sizeBytes bytes',
    );
    return CatalogInstallResult(
      catalog: catalog,
      sha256: hash,
      sizeBytes: sizeBytes,
      objectCount: objectCount,
      version: catalog.version,
      installedAt: installedAt,
    );
  }

  /// SHA-256, byte size and data-row count (lines minus the header) of
  /// [file], in one streamed pass.
  Future<(String sha256, int sizeBytes, int rows)> _hashAndCount(
    File file,
  ) async {
    Digest? digest;
    final hashInput = sha256.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback((d) => digest = d.single),
    );
    var size = 0;
    var newlines = 0;
    var lastByte = 0x0A;
    await for (final chunk in file.openRead()) {
      hashInput.add(chunk);
      size += chunk.length;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] == 0x0A) newlines++;
      }
      if (chunk.isNotEmpty) lastByte = chunk.last;
    }
    hashInput.close();
    final lines = newlines + (lastByte == 0x0A ? 0 : 1);
    return (digest!.toString(), size, lines > 0 ? lines - 1 : 0);
  }

  /// Delete [catalog]'s data file (under any name it was ever installed as)
  /// and its metadata. Returns whether anything was there to remove.
  ///
  /// Every file is attempted before a failure is reported, and readers are
  /// told the catalog changed even then, so a search cannot keep serving a
  /// file that is already gone.
  Future<bool> uninstall(SkyCatalog catalog) async {
    if (!isInitialized) return false;
    var removed = false;
    final failures = <(String, Object)>[];
    try {
      for (final name in [
        ...catalog.candidateFileNames,
        catalog.metadataFileName,
      ]) {
        final file = File(path.join(catalogDirectory, name));
        if (!await file.exists()) continue;
        try {
          await file.delete();
          removed = true;
        } catch (e) {
          failures.add((file.path, e));
        }
      }
    } finally {
      catalogChanged(catalog);
    }
    if (removed) _events.add(CatalogEvent.uninstalled(name: catalog.name));
    if (failures.isNotEmpty) {
      final first = failures.first;
      throw FileSystemException(
        'Could not delete ${failures.length} catalog '
        'file${failures.length == 1 ? '' : 's'}: ${first.$2}',
        first.$1,
      );
    }
    return removed;
  }

  /// Re-hash installed catalogs against the hash recorded at install. [only]
  /// limits it to one catalog. A catalog that is not installed reports
  /// `not_installed`; one installed before hashes were recorded reports
  /// `no_expected_hash`.
  Future<Map<SkyCatalog, CatalogVerifyResult>> verify({
    SkyCatalog? only,
  }) async {
    if (!isInitialized) {
      throw StateError('CatalogManager not initialized');
    }
    return {
      for (final catalog in only == null ? SkyCatalog.values : [only])
        catalog: await _verifyOne(catalog),
    };
  }

  Future<CatalogVerifyResult> _verifyOne(SkyCatalog catalog) async {
    final current = await status(catalog);
    final CatalogVerifyResult result;
    if (!current.isInstalled) {
      result = const CatalogVerifyResult(
        ok: false,
        expectedHash: null,
        actualHash: null,
        errors: ['not_installed'],
      );
    } else {
      final (actual, _, _) = await _hashAndCount(File(current.installedPath!));
      final expected = current.expectedHash;
      final ok = expected != null && catalogSha256Matches(expected, actual);
      result = CatalogVerifyResult(
        ok: ok,
        expectedHash: expected,
        actualHash: actual,
        errors: [
          if (expected == null)
            'no_expected_hash'
          else if (!ok)
            'hash_mismatch',
        ],
      );
      await _recordVerified(catalog);
    }
    _events.add(
      CatalogEvent.verified(
        name: catalog.name,
        ok: result.ok,
        errors: result.errors,
      ),
    );
    return result;
  }

  Future<void> _recordVerified(SkyCatalog catalog) async {
    final metaFile = File(
      path.join(catalogDirectory, catalog.metadataFileName),
    );
    if (!await metaFile.exists()) return;
    try {
      final raw = jsonDecode(await metaFile.readAsString());
      if (raw is Map<String, dynamic>) {
        raw['lastVerified'] = DateTime.now().toUtc().toIso8601String();
        await metaFile.writeAsString(jsonEncode(raw));
      }
    } catch (e) {
      _log(
        'verify(${catalog.name}): failed to update lastVerified: $e',
        level: 900,
      );
    }
  }

  /// Called after [catalog]'s file was installed, replaced or removed.
  @protected
  void catalogChanged(SkyCatalog catalog) {}

  /// Tell listeners the files may have changed outside this class (an
  /// operator copied a catalog into the directory).
  Future<void> reload() async {
    SkyCatalog.values.forEach(catalogChanged);
    _events.add(const CatalogEvent.reloaded());
  }

  void dispose() {
    _progress.close();
    _events.close();
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      // A leftover is swept at the next start.
      _log('could not remove ${file.path}: $e', level: 900);
    }
  }

  void _log(String message, {int level = 800}) =>
      developer.log('[Catalog] $message', name: 'CatalogManager', level: level);
}
