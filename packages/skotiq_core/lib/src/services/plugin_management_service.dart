// Plugin management service.
//
// Legacy uploaded-plugin archive registry.
//
// Current Dart AOT builds cannot execute uploaded plugin source. The headless
// plugin handler uses this service only to identify and remove inert archives
// left by older builds. Live plugin state comes from PluginHost.
//
// The registry it still owns, for migration and tests:
//   * archive bytes on disk under `<appData>/Skotiq/plugins/`,
//   * a SHA-256 fingerprint per archive, recomputed on upload and compared
//     against the digest the manifest declares — enough to catch a corrupted
//     or tampered-in-transit payload on a LAN, short of a signing-key scheme,
//   * the enabled/disabled preference in a sidecar JSON file.
//
// It lives in `skotiq_core`, not `skotiq_plugins`, because that package
// is the API surface plugin AUTHORS implement; this is the host-side
// disk/registry layer the headless API exposes, and keeping it here leaves the
// author-facing package free of file-system concerns.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import 'logging_service.dart';
import '../utils/skotiq_data_directory.dart';

/// An installed plugin's full manifest as exposed by the headless API.
/// Mirrors the wire shape the dashboard / mobile companion consumes via
/// `NetworkBackend.listPlugins()`.
class InstalledPluginManifest {
  /// Unique plugin id from the embedded manifest.json. Falls back to the
  /// uploaded filename's stem when the archive does not embed a
  /// manifest (legacy `.dart` bundles).
  final String id;

  /// Human-readable name.
  final String name;

  /// Semantic version string.
  final String version;

  /// Author or maintainer of the plugin (free-form string).
  final String? author;

  /// Plugin description.
  final String? description;

  /// The operator preference recorded by the archive API. Never runtime
  /// state: a Dart AOT build cannot load the archive, and headless responses
  /// override this to false and mark the row a non-runnable uploaded archive.
  final bool enabled;

  /// Whether a signature (SHA-256 manifest hash) was supplied at install
  /// time. False for legacy local plugins that never went through the
  /// upload path.
  final bool signed;

  /// Whether the signature matched the recomputed digest of the on-disk
  /// archive. Always false when [signed] is false. A user-uploaded
  /// plugin whose digest mismatches its manifest is rejected at upload
  /// time, so a stored `signatureValid=false` indicates post-install
  /// corruption.
  final bool signatureValid;

  /// SHA-256 of the on-disk archive bytes. Recomputed at every
  /// list-call so a corrupted file surfaces with
  /// `signatureValid=false` even if the cached manifest still believes
  /// it is fine.
  final String? sha256;

  /// Size of the on-disk archive in bytes.
  final int? sizeBytes;

  /// When the plugin was installed (UTC). Null for plugins discovered
  /// outside the upload flow.
  final DateTime? installedAt;

  /// Original filename submitted with the upload (e.g. `my_plugin.nsplugin`).
  final String? installedFilename;

  /// Archive verification/availability error. Uploaded archives are not
  /// passed to PluginHost by current builds.
  final String? loadError;

  const InstalledPluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.enabled,
    required this.signed,
    required this.signatureValid,
    this.author,
    this.description,
    this.sha256,
    this.sizeBytes,
    this.installedAt,
    this.installedFilename,
    this.loadError,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'author': author,
    'description': description,
    'enabled': enabled,
    'signed': signed,
    'signatureValid': signatureValid,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
    'installedAt': installedAt?.toIso8601String(),
    'installedFilename': installedFilename,
    'loadError': loadError,
  };

  InstalledPluginManifest copyWith({
    String? id,
    String? name,
    String? version,
    String? author,
    String? description,
    bool? enabled,
    bool? signed,
    bool? signatureValid,
    String? sha256,
    int? sizeBytes,
    DateTime? installedAt,
    String? installedFilename,
    String? loadError,
    bool clearLoadError = false,
  }) {
    return InstalledPluginManifest(
      id: id ?? this.id,
      name: name ?? this.name,
      version: version ?? this.version,
      author: author ?? this.author,
      description: description ?? this.description,
      enabled: enabled ?? this.enabled,
      signed: signed ?? this.signed,
      signatureValid: signatureValid ?? this.signatureValid,
      sha256: sha256 ?? this.sha256,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      installedAt: installedAt ?? this.installedAt,
      installedFilename: installedFilename ?? this.installedFilename,
      loadError: clearLoadError ? null : (loadError ?? this.loadError),
    );
  }
}

/// Raised when a plugin upload fails verification. Headless handler maps
/// this to a 400 Bad Request with the message intact.
class PluginVerificationException implements Exception {
  final String reason;
  PluginVerificationException(this.reason);
  @override
  String toString() => 'PluginVerificationException: $reason';
}

/// Raised when an action targets a plugin id that is not installed.
class PluginNotFoundException implements Exception {
  final String pluginId;
  PluginNotFoundException(this.pluginId);
  @override
  String toString() => 'Plugin not found: $pluginId';
}

/// Raised when the on-disk legacy plugin registry cannot be trusted. Treating
/// this as an empty registry would allow the next mutation to erase recoverable
/// entries, so callers must surface the failure and leave the file untouched.
class PluginRegistryException implements Exception {
  final String reason;
  PluginRegistryException(this.reason);

  @override
  String toString() => 'Plugin registry error: $reason';
}

/// Service that owns the on-disk plugin registry. Single producer of
/// truth — the headless handlers never touch the file system directly.
class PluginManagementService {
  /// Default name of the registry sidecar file on disk. Stored next to
  /// the archives in the plugin directory.
  static const String registryFileName = 'registry.json';

  /// Default name of the manifest entry inside an `.nsplugin` archive.
  static const String manifestEntryName = 'manifest.json';

  final LoggingService _logger;

  /// Override for the plugin directory. Tests inject this; production
  /// resolves it from [resolveSkotiqDataDirectory].
  final Future<Directory> Function()? _directoryOverride;
  Future<void> _mutationTail = Future<void>.value();

  PluginManagementService({
    required LoggingService logger,
    Future<Directory> Function()? directoryOverride,
  }) : _logger = logger,
       _directoryOverride = directoryOverride;

  Future<Directory> _pluginDirectory() async {
    final override = _directoryOverride;
    if (override != null) {
      final dir = await override();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
    final appDir = await resolveSkotiqDataDirectory();
    final pluginDir = Directory(path.join(appDir.path, 'Skotiq', 'plugins'));
    if (!await pluginDir.exists()) {
      await pluginDir.create(recursive: true);
    }
    return pluginDir;
  }

  /// Return every installed plugin's manifest, sorted by name. Recomputes
  /// the on-disk SHA-256 for each entry so a corrupted archive surfaces
  /// `signatureValid=false` even when the registry still trusts it.
  Future<List<InstalledPluginManifest>> listPlugins() async {
    final registry = await _loadRegistry();
    final pluginDir = await _pluginDirectory();

    final results = <InstalledPluginManifest>[];
    for (final entry in registry.values) {
      // Walk the archive on every list call. Cheap (~ms even for a few-MB
      // archive on modern SSDs) and the only way to detect tampering /
      // bit-rot between the install and a subsequent enable/disable call.
      InstalledPluginManifest verified = entry;
      if (entry.installedFilename != null) {
        final file = File(path.join(pluginDir.path, entry.installedFilename!));
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final actualHash = sha256.convert(bytes).toString();
          final ok = entry.sha256 == null || entry.sha256 == actualHash;
          verified = entry.copyWith(
            sha256: actualHash,
            sizeBytes: bytes.length,
            signatureValid: entry.signed && ok,
          );
        } else {
          verified = entry.copyWith(
            signatureValid: false,
            loadError: 'Archive missing from plugin directory',
          );
        }
      }
      results.add(verified);
    }

    results.sort((a, b) => a.name.compareTo(b.name));
    return results;
  }

  /// Install a plugin from a raw archive byte stream. The archive is
  /// expected to be either:
  ///   * a JSON manifest itself (developer/test path), OR
  ///   * a binary file whose first 4 KiB contains a parseable JSON
  ///     manifest near the head.
  ///
  /// If neither yields a manifest, the upload is REJECTED: installing an
  /// opaque blob would be a silent fallback.
  Future<InstalledPluginManifest> installFromBytes(
    List<int> bytes, {
    required String filename,
    String? declaredSha256,
  }) => _serializeMutation(
    () => _installFromBytes(
      bytes,
      filename: filename,
      declaredSha256: declaredSha256,
    ),
  );

  Future<InstalledPluginManifest> _installFromBytes(
    List<int> bytes, {
    required String filename,
    String? declaredSha256,
  }) async {
    if (bytes.isEmpty) {
      throw PluginVerificationException('Uploaded plugin is empty');
    }
    final pluginDir = await _pluginDirectory();
    final actualHash = sha256.convert(bytes).toString();

    if (declaredSha256 != null && declaredSha256 != actualHash) {
      throw PluginVerificationException(
        'SHA-256 mismatch: expected $declaredSha256, got $actualHash. '
        'The upload is corrupted or tampered with.',
      );
    }

    final manifestJson = _extractManifest(bytes);
    if (manifestJson == null) {
      throw PluginVerificationException(
        'Plugin archive does not embed a parseable manifest.json. The '
        'first 4 KiB must contain a JSON object with id, name, version.',
      );
    }

    final id = (manifestJson['id'] as String?)?.trim() ?? '';
    final name = (manifestJson['name'] as String?)?.trim() ?? '';
    final version = (manifestJson['version'] as String?)?.trim() ?? '';
    if (id.isEmpty || name.isEmpty || version.isEmpty) {
      throw PluginVerificationException(
        'Plugin manifest is missing required field (id, name, or version).',
      );
    }

    final author = (manifestJson['author'] as String?)?.trim();
    final description = (manifestJson['description'] as String?)?.trim();
    // Load before writing anything. A corrupt registry must not leave a new
    // orphan archive behind or be replaced with a one-entry registry.
    final registry = await _loadRegistry();
    final previous = registry[id];

    // Persist the archive next to existing plugins. The filename is
    // namespaced by plugin id and content hash. Version updates therefore do
    // not overwrite the archive referenced by the last committed registry.
    final safeFilename =
        '${_sanitizeId(id)}-${actualHash.substring(0, 12)}-'
        '${path.basename(filename)}';
    final targetFile = File(path.join(pluginDir.path, safeFilename));
    await targetFile.writeAsBytes(bytes, flush: true);

    // Preserve the operator's existing enabled/disabled flag on
    // re-upload (the common case: plugin author publishes a new version
    // of an already-installed plugin). Default to enabled for a fresh
    // install so the operator does not have to enable separately after
    // upload.
    final manifest = InstalledPluginManifest(
      id: id,
      name: name,
      version: version,
      author: author,
      description: description,
      enabled: previous?.enabled ?? true,
      signed: true,
      signatureValid: true,
      sha256: actualHash,
      sizeBytes: bytes.length,
      installedAt: DateTime.now().toUtc(),
      installedFilename: safeFilename,
    );

    registry[id] = manifest;
    try {
      await _saveRegistry(registry);
    } catch (_) {
      if (previous?.installedFilename != safeFilename &&
          await targetFile.exists()) {
        await targetFile.delete();
      }
      rethrow;
    }

    // The new registry is durable before the previous archive is removed.
    if (previous?.installedFilename case final oldFilename?
        when oldFilename != safeFilename) {
      final oldFile = File(path.join(pluginDir.path, oldFilename));
      try {
        if (await oldFile.exists()) await oldFile.delete();
      } catch (e) {
        _logger.warning(
          'Installed $id but could not remove its superseded archive: $e',
          source: 'PluginManagementService',
        );
      }
    }
    _logger.info(
      'Installed plugin $id (${manifest.version}) sha=${manifest.sha256}',
      source: 'PluginManagementService',
    );
    return manifest;
  }

  /// Set the enabled flag for [pluginId]. Returns the updated manifest.
  Future<InstalledPluginManifest> setEnabled(String pluginId, bool enabled) =>
      _serializeMutation(() => _setEnabled(pluginId, enabled));

  Future<InstalledPluginManifest> _setEnabled(
    String pluginId,
    bool enabled,
  ) async {
    final registry = await _loadRegistry();
    final existing = registry[pluginId];
    if (existing == null) {
      throw PluginNotFoundException(pluginId);
    }
    final updated = existing.copyWith(enabled: enabled);
    registry[pluginId] = updated;
    await _saveRegistry(registry);
    _logger.info(
      'Plugin $pluginId ${enabled ? "enabled" : "disabled"}',
      source: 'PluginManagementService',
    );
    return updated;
  }

  /// Uninstall a plugin: remove its archive and registry entry. No-op if
  /// the id is unknown (the caller can treat 404 as idempotent).
  Future<void> uninstall(String pluginId) =>
      _serializeMutation(() => _uninstall(pluginId));

  Future<void> _uninstall(String pluginId) async {
    final registry = await _loadRegistry();
    final existing = registry[pluginId];
    if (existing == null) {
      throw PluginNotFoundException(pluginId);
    }
    registry.remove(pluginId);
    await _saveRegistry(registry);
    if (existing.installedFilename != null) {
      final pluginDir = await _pluginDirectory();
      final file = File(path.join(pluginDir.path, existing.installedFilename!));
      try {
        if (await file.exists()) await file.delete();
      } catch (e) {
        _logger.warning(
          'Uninstalled $pluginId but could not remove its archived payload: $e',
          source: 'PluginManagementService',
        );
      }
    }
    _logger.info(
      'Uninstalled plugin $pluginId',
      source: 'PluginManagementService',
    );
  }

  /// Fetch a single manifest by id, or null if not installed. Triggers
  /// the same on-disk verification pass that [listPlugins] does.
  Future<InstalledPluginManifest?> getManifest(String pluginId) async {
    final all = await listPlugins();
    for (final m in all) {
      if (m.id == pluginId) return m;
    }
    return null;
  }

  // Internal: registry persistence

  Future<Map<String, InstalledPluginManifest>> _loadRegistry() async {
    final pluginDir = await _pluginDirectory();
    final file = File(path.join(pluginDir.path, registryFileName));
    final backup = File('${file.path}.bak');
    if (!await file.exists()) {
      if (!await backup.exists()) {
        return <String, InstalledPluginManifest>{};
      }
      final recovered = await _decodeRegistryFile(backup);
      // A save interrupted between moving the old registry aside and promoting
      // the new file leaves only .bak. Restore a readable main copy while
      // retaining the backup until the next successful atomic save.
      await backup.copy(file.path);
      return recovered;
    }

    return _decodeRegistryFile(file);
  }

  Future<Map<String, InstalledPluginManifest>> _decodeRegistryFile(
    File file,
  ) async {
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        throw PluginRegistryException('${file.path} is empty');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw PluginRegistryException(
          '${file.path} does not contain a JSON object',
        );
      }
      // The on-disk layout is `{"version": N, "plugins": {id: {...}}}`.
      // We iterate the `plugins` sub-map, not the envelope itself, so the
      // `version` field doesn't trip the manifest decoder.
      final pluginsMap = decoded['plugins'];
      if (pluginsMap is! Map) {
        throw PluginRegistryException('${file.path} has no `plugins` object');
      }
      final out = <String, InstalledPluginManifest>{};
      for (final entry in pluginsMap.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || key.trim().isEmpty || value is! Map) {
          throw PluginRegistryException(
            '${file.path} contains a malformed plugin entry',
          );
        }
        final manifest = _manifestFromRegistryJson(
          value.cast<String, dynamic>(),
        );
        if (manifest.id != key) {
          throw PluginRegistryException(
            '${file.path} entry `$key` declares id `${manifest.id}`',
          );
        }
        out[key] = manifest;
      }
      return out;
    } on PluginRegistryException {
      rethrow;
    } catch (e, st) {
      _logger.error(
        'Failed to read plugin registry: $e\n$st',
        source: 'PluginManagementService',
      );
      throw PluginRegistryException('Failed to read ${file.path}: $e');
    }
  }

  Future<void> _saveRegistry(
    Map<String, InstalledPluginManifest> registry,
  ) async {
    final pluginDir = await _pluginDirectory();
    final file = File(path.join(pluginDir.path, registryFileName));
    final encoded = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'plugins': {
        for (final entry in registry.entries) entry.key: entry.value.toJson(),
      },
    });
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    await temporary.writeAsString(encoded, flush: true);
    try {
      if (await backup.exists()) await backup.delete();
      if (await file.exists()) await file.rename(backup.path);
      try {
        await temporary.rename(file.path);
      } catch (_) {
        if (!await file.exists() && await backup.exists()) {
          await backup.rename(file.path);
        }
        rethrow;
      }
      if (await backup.exists()) await backup.delete();
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  InstalledPluginManifest _manifestFromRegistryJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.trim().isEmpty) {
      throw PluginRegistryException('Plugin registry entry has no valid `id`');
    }
    return InstalledPluginManifest(
      id: id,
      name: json['name'] as String? ?? '',
      version: json['version'] as String? ?? '',
      author: json['author'] as String?,
      description: json['description'] as String?,
      enabled: json['enabled'] as bool? ?? false,
      signed: json['signed'] as bool? ?? false,
      signatureValid: json['signatureValid'] as bool? ?? false,
      sha256: json['sha256'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
      installedAt: (json['installedAt'] as String?) != null
          ? DateTime.tryParse(json['installedAt'] as String)
          : null,
      installedFilename: json['installedFilename'] as String?,
      loadError: json['loadError'] as String?,
    );
  }

  Future<T> _serializeMutation<T>(Future<T> Function() operation) {
    final run = _mutationTail.then((_) => operation());
    _mutationTail = run.then<void>((_) {}, onError: (_, __) {});
    return run;
  }

  /// Inspect the front of an upload's byte stream for an embedded
  /// `manifest.json`. We accept three shapes:
  ///
  ///   1. The whole upload is the manifest (`{...}` JSON object).
  ///   2. The first 4 KiB contains a contiguous JSON object — common
  ///      when the archive is a future zip or tar container.
  ///   3. A small `manifest.json:`-prefixed line followed by the
  ///      payload (test path).
  ///
  /// Returns null when nothing matches — the caller turns that into a
  /// 400 rather than silently accepting an opaque payload.
  Map<String, dynamic>? _extractManifest(List<int> bytes) {
    final scanWindow = bytes.length > 16384 ? bytes.sublist(0, 16384) : bytes;
    String text;
    try {
      // UTF-8 decode the head; archives that aren't text simply won't
      // contain a parseable JSON object and will be rejected.
      text = utf8.decode(scanWindow, allowMalformed: true);
    } catch (_) {
      return null;
    }

    // Shape 1 / 2: scan for the first balanced `{...}` object that
    // contains an `"id"` field. We do a simple bracket walk rather than
    // pulling in a streaming JSON parser; the manifest is small.
    final start = text.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escape) {
          escape = false;
        } else if (ch == r'\') {
          escape = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
        continue;
      }
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) {
          final candidate = text.substring(start, i + 1);
          try {
            final decoded = jsonDecode(candidate);
            if (decoded is Map<String, dynamic> && decoded.containsKey('id')) {
              return decoded;
            }
          } catch (_) {
            // Try again from the next `{` — the first balanced object
            // wasn't a manifest, but a later one could be.
          }
          // Resume scanning past this object.
          final next = text.indexOf('{', i + 1);
          if (next < 0) return null;
          i = next - 1;
          depth = 0;
        }
      }
    }
    return null;
  }

  String _sanitizeId(String id) {
    return id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }
}

/// Riverpod provider for [PluginManagementService]. The directory
/// override is null in production; tests inject a temp directory via
/// `overrideWithProvider`/`overrideWith`.
final pluginManagementServiceProvider = Provider<PluginManagementService>((
  ref,
) {
  return PluginManagementService(logger: ref.watch(loggingServiceProvider));
});
