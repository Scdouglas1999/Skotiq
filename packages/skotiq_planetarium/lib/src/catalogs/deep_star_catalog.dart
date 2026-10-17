import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import 'catalog_manager.dart';
import 'deep_star_tile.dart';

/// Installation status of the deep-star tier.
class DeepStarStatus {
  /// Locally installed manifest, if any.
  final DeepStarManifest? manifest;

  /// Tiles from the manifest that are present on disk.
  final int tilesPresent;

  /// Bytes of tile data present on disk.
  final int bytesPresent;

  /// When the tileset was last (fully) installed.
  final DateTime? installedAt;

  /// Whether catalog files exist without a readable installed manifest.
  ///
  /// Downloads write the manifest last, so an interrupted but resumable
  /// download legitimately has local files while [manifest] is null.
  final bool hasLocalFiles;

  const DeepStarStatus({
    this.manifest,
    this.tilesPresent = 0,
    this.bytesPresent = 0,
    this.installedAt,
    this.hasLocalFiles = false,
  });

  bool get isInstalled => manifest != null;
  bool get hasCatalogData => manifest != null || hasLocalFiles;
  bool get isComplete =>
      manifest != null && tilesPresent >= manifest!.tiles.length;
}

/// Progress of a tileset download.
class DeepStarDownloadProgress {
  final int tilesDone;
  final int tilesTotal;
  final int bytesDone;
  final int bytesTotal;
  final String currentFile;
  final bool verifying;

  const DeepStarDownloadProgress({
    required this.tilesDone,
    required this.tilesTotal,
    required this.bytesDone,
    required this.bytesTotal,
    required this.currentFile,
    this.verifying = false,
  });

  double get fraction => bytesTotal <= 0 ? 0 : bytesDone / bytesTotal;
}

/// Result of verifying installed tiles against their manifest hashes.
class DeepStarVerifyResult {
  final int tilesChecked;
  final List<String> missing;
  final List<String> corrupt;

  const DeepStarVerifyResult({
    required this.tilesChecked,
    required this.missing,
    required this.corrupt,
  });

  bool get ok => missing.isEmpty && corrupt.isEmpty;
}

/// Downloads, verifies, and manages the deep-star tileset.
///
/// The tileset is fetched from a configurable, self-hostable base URL
/// (`<baseUrl>/manifest.json` + `<baseUrl>/<tile file>`); see
/// `tools/catalog_prep/README.md` for how to generate and host one from the
/// public Tycho-2 / Gaia source catalogs. Tiles are stored under
/// `<catalog dir>/deep_stars/` and verified with per-tile SHA-256 from the
/// manifest. Downloads are resumable: tiles already on disk with a matching
/// hash are skipped, so "pause" simply stops the run and a later download
/// call continues where it left off.
class DeepStarCatalogManager {
  /// Default base URL: intentionally empty. No official tileset is published,
  /// and a loopback placeholder such as `http://localhost:8765/...` leaves a
  /// fresh install's Download button able only to fail with
  /// connection-refused. Users supply a host in Settings; developers can
  /// self-host a generated tileset
  /// (`tools/catalog_prep/make_deep_star_tiles.py`, then e.g.
  /// `python3 -m http.server 8765` from the output directory).
  static const String defaultBaseUrl = '';

  /// The pre-4.0.1 shipping default. Any config.json that persisted it (the
  /// settings card wrote the field on every download attempt) is treated as
  /// unset, so existing installs migrate onto the empty default too.
  static const String _legacyLoopbackBaseUrl =
      'http://localhost:8765/skotiq_deep_stars';

  final String directory;
  final http.Client Function() _clientFactory;

  DeepStarCatalogManager({
    String? directory,
    http.Client Function()? clientFactory,
  }) : directory =
           directory ??
           path.join(CatalogManager.instance.catalogDirectory, 'deep_stars'),
       _clientFactory = clientFactory ?? http.Client.new;

  String get _manifestPath => path.join(directory, 'manifest.json');
  String get _configPath => path.join(directory, 'config.json');
  String get _metaPath => path.join(directory, 'install_metadata.json');

  // Configuration (base URL)

  /// The configured tileset base URL (persisted), or the default.
  Future<String> getBaseUrl() async {
    try {
      final file = File(_configPath);
      if (await file.exists()) {
        final json = (jsonDecode(await file.readAsString()) as Map)
            .cast<String, Object?>();
        final url = json['baseUrl'] as String?;
        if (url != null && url.isNotEmpty && url != _legacyLoopbackBaseUrl) {
          return url;
        }
      }
    } catch (e) {
      developer.log(
        '[DeepStar] config read error: $e',
        name: 'DeepStarCatalogManager',
        level: 900,
      );
    }
    return defaultBaseUrl;
  }

  Future<void> setBaseUrl(String url) async {
    final dir = Directory(directory);
    if (!await dir.exists()) await dir.create(recursive: true);
    await File(_configPath).writeAsString(jsonEncode({'baseUrl': url.trim()}));
  }

  // Status

  Future<DeepStarStatus> status() async {
    final manifestFile = File(_manifestPath);
    if (!await manifestFile.exists()) {
      return DeepStarStatus(hasLocalFiles: await _hasLocalCatalogFiles());
    }
    DeepStarManifest manifest;
    try {
      manifest = DeepStarManifest.decodeJson(await manifestFile.readAsString());
    } catch (_) {
      // Keep corrupt installs visible in Settings so the user can delete or
      // replace them instead of silently stranding files on disk.
      return const DeepStarStatus(hasLocalFiles: true);
    }

    var present = 0;
    var bytes = 0;
    for (final t in manifest.tiles) {
      final f = File(path.join(directory, t.file));
      if (await f.exists()) {
        present++;
        bytes += await f.length();
      }
    }

    DateTime? installedAt;
    try {
      final meta = File(_metaPath);
      if (await meta.exists()) {
        final json = (jsonDecode(await meta.readAsString()) as Map)
            .cast<String, Object?>();
        installedAt = DateTime.tryParse(json['installedAt'] as String? ?? '');
      }
    } catch (e) {
      // Metadata is cosmetic (install date in Settings); a corrupt or
      // unreadable meta file must not block status reporting, but log it so
      // a damaged install directory is visible in diagnostics.
      developer.log(
        'DeepStarCatalog: failed to read install metadata: $e',
        name: 'skotiq.planetarium',
      );
    }

    return DeepStarStatus(
      manifest: manifest,
      tilesPresent: present,
      bytesPresent: bytes,
      installedAt: installedAt,
    );
  }

  // Download

  /// Fetch the remote manifest from the configured base URL.
  Future<DeepStarManifest> fetchRemoteManifest({String? baseUrl}) async {
    final base = _normalizeBase(baseUrl ?? await getBaseUrl());
    if (base.isEmpty) {
      throw StateError(
        'No tileset host configured. Enter a base URL first — see '
        'tools/catalog_prep/README.md for generating and hosting a tileset.',
      );
    }
    final client = _clientFactory();
    try {
      final response = await client.get(Uri.parse('$base/manifest.json'));
      if (response.statusCode != 200) {
        throw HttpException(
          'Manifest fetch failed: HTTP ${response.statusCode}',
          uri: Uri.parse('$base/manifest.json'),
        );
      }
      return DeepStarManifest.decodeJson(utf8.decode(response.bodyBytes));
    } finally {
      client.close();
    }
  }

  /// Download (or resume downloading) the tileset.
  ///
  /// Tiles already present with a matching SHA-256 are skipped. Returns true
  /// when every tile is installed and verified; false when stopped early via
  /// [isCancelled] (already-downloaded tiles are kept for resume).
  Future<bool> download({
    void Function(DeepStarDownloadProgress progress)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    final dir = Directory(directory);
    if (!await dir.exists()) await dir.create(recursive: true);

    final manifest = await fetchRemoteManifest();
    final base = _normalizeBase(await getBaseUrl());
    final total = manifest.totalBytes;
    var bytesDone = 0;
    var tilesDone = 0;

    void report(String file, {bool verifying = false}) {
      onProgress?.call(
        DeepStarDownloadProgress(
          tilesDone: tilesDone,
          tilesTotal: manifest.tiles.length,
          bytesDone: bytesDone,
          bytesTotal: total,
          currentFile: file,
          verifying: verifying,
        ),
      );
    }

    final client = _clientFactory();
    try {
      for (final t in manifest.tiles) {
        if (isCancelled != null && await isCancelled()) {
          developer.log(
            '[DeepStar] download paused/cancelled',
            name: 'DeepStarCatalogManager',
            level: 800,
          );
          return false;
        }

        final target = File(path.join(directory, t.file));

        // Resume: skip tiles already present with a matching hash.
        if (await target.exists()) {
          report(t.file, verifying: true);
          final existing = await target.readAsBytes();
          if (existing.length == t.sizeBytes &&
              sha256.convert(existing).toString() == t.sha256) {
            bytesDone += t.sizeBytes;
            tilesDone++;
            report(t.file);
            continue;
          }
          await target.delete();
        }

        report(t.file);
        final response = await client.get(Uri.parse('$base/${t.file}'));
        if (response.statusCode != 200) {
          throw HttpException(
            'Tile ${t.file} fetch failed: HTTP ${response.statusCode}',
          );
        }
        final bytes = response.bodyBytes;
        if (sha256.convert(bytes).toString() != t.sha256) {
          throw FormatException('Tile ${t.file} failed SHA-256 verification');
        }
        // Sanity: the payload must decode as an SKDT tile.
        DeepStarTile.decode(bytes);

        final tmp = File('${target.path}.part');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(target.path);

        bytesDone += bytes.length;
        tilesDone++;
        report(t.file);
      }
    } finally {
      client.close();
    }

    // All tiles verified: install the manifest + metadata atomically last so
    // a partial download never looks installed.
    await File(_manifestPath).writeAsString(manifest.encodeJson());
    await File(_metaPath).writeAsString(
      jsonEncode({
        'installedAt': DateTime.now().toIso8601String(),
        'baseUrl': base,
      }),
    );
    return true;
  }

  /// Re-hash every installed tile against the local manifest.
  Future<DeepStarVerifyResult> verify() async {
    final st = await status();
    final manifest = st.manifest;
    if (manifest == null) {
      return const DeepStarVerifyResult(
        tilesChecked: 0,
        missing: [],
        corrupt: [],
      );
    }
    final missing = <String>[];
    final corrupt = <String>[];
    for (final t in manifest.tiles) {
      final f = File(path.join(directory, t.file));
      if (!await f.exists()) {
        missing.add(t.file);
        continue;
      }
      final bytes = await f.readAsBytes();
      if (sha256.convert(bytes).toString() != t.sha256) {
        corrupt.add(t.file);
      }
    }
    return DeepStarVerifyResult(
      tilesChecked: manifest.tiles.length,
      missing: missing,
      corrupt: corrupt,
    );
  }

  /// Delete the installed tileset (keeps the config / base URL).
  Future<void> delete() async {
    final dir = Directory(directory);
    if (!await dir.exists()) return;
    final failures = <(String, Object)>[];
    FileSystemEntity? manifestEntity;
    await for (final entity in dir.list()) {
      final name = path.basename(entity.path);
      if (name == 'config.json') continue;
      if (name == 'manifest.json') {
        manifestEntity = entity;
        continue;
      }
      try {
        await entity.delete(recursive: true);
      } catch (e) {
        // Keep deleting the rest of the tileset — one locked tile (e.g. an
        // open file handle on Windows) should not strand the other files —
        // but record what was left behind.
        developer.log(
          'DeepStarCatalog: failed to delete ${entity.path}: $e',
          name: 'skotiq.planetarium',
        );
        failures.add((entity.path, e));
      }
    }
    // The manifest is the user's handle for retrying cleanup. Delete it only
    // after all tile and metadata files are gone; if any are locked, status()
    // continues to report a partial install and Settings keeps Delete visible.
    if (failures.isEmpty && manifestEntity != null) {
      try {
        await manifestEntity.delete(recursive: true);
      } catch (e) {
        developer.log(
          'DeepStarCatalog: failed to delete ${manifestEntity.path}: $e',
          name: 'skotiq.planetarium',
        );
        failures.add((manifestEntity.path, e));
      }
    }
    if (failures.isNotEmpty) {
      final first = failures.first;
      throw FileSystemException(
        'Could not delete ${failures.length} deep-star catalog '
        'item${failures.length == 1 ? '' : 's'}: ${first.$2}',
        first.$1,
      );
    }
  }

  static String _normalizeBase(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  Future<bool> _hasLocalCatalogFiles() async {
    final dir = Directory(directory);
    if (!await dir.exists()) return false;
    await for (final entity in dir.list()) {
      if (path.basename(entity.path) != 'config.json') return true;
    }
    return false;
  }
}
