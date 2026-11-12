/// The plugins a host reports (`PluginApi`).
library;

import '../wire_time.dart';

/// One row of `GET /api/plugins`, and the `manifest` of the enable and
/// disable answers.
///
/// Hosts report the plugins compiled into their build. Older hosts may also
/// list stored upload archives, so [source], [runtimeLoaded] and [canEnable]
/// tell an executable plugin from a stored artifact.
class RemotePluginManifest {
  const RemotePluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.enabled,
    required this.signed,
    required this.signatureValid,
    this.description,
    this.author,
    this.sha256,
    this.sizeBytes,
    this.installedAt,
    this.installedFilename,
    this.loadError,
    this.source = 'uploadedArchive',
    this.runtimeLoaded = false,
    this.canEnable = false,
  });

  factory RemotePluginManifest.fromJson(Map<String, dynamic> json) {
    return RemotePluginManifest(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      version: json['version'] as String? ?? '',
      description: json['description'] as String?,
      author: json['author'] as String?,
      enabled: json['enabled'] as bool? ?? false,
      signed: json['signed'] as bool? ?? false,
      signatureValid: json['signatureValid'] as bool? ?? false,
      sha256: json['sha256'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
      installedAt: switch (json['installedAt']) {
        final String raw => tryParseWireTime(raw),
        _ => null,
      },
      installedFilename: json['installedFilename'] as String?,
      loadError: json['loadError'] as String?,
      source: json['source'] as String? ?? 'uploadedArchive',
      runtimeLoaded: json['runtimeLoaded'] as bool? ?? false,
      canEnable: json['canEnable'] as bool? ?? false,
    );
  }

  final String id;
  final String name;
  final String version;
  final String? description;
  final String? author;
  final bool enabled;

  /// Whether an uploaded archive carried a signature. Always false for a
  /// bundled plugin, which has no archive: false there means "does not
  /// apply", not "untrusted".
  final bool signed;
  final bool signatureValid;
  final String? sha256;
  final int? sizeBytes;
  final DateTime? installedAt;
  final String? installedFilename;
  final String? loadError;

  /// `bundled` for a plugin compiled into the host, `uploadedArchive` for a
  /// stored upload.
  final String source;
  final bool runtimeLoaded;
  final bool canEnable;

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
    'installedAt': installedAt?.toWireTime(),
    'installedFilename': installedFilename,
    'loadError': loadError,
    'source': source,
    'runtimeLoaded': runtimeLoaded,
    'canEnable': canEnable,
  };
}
