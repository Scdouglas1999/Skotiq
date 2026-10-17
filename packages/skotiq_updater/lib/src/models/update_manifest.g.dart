// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'update_manifest.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_UpdateFileInfo _$UpdateFileInfoFromJson(Map<String, dynamic> json) =>
    _UpdateFileInfo(
      path: json['path'] as String,
      size: (json['size'] as num).toInt(),
      sha256: json['sha256'] as String,
    );

Map<String, dynamic> _$UpdateFileInfoToJson(_UpdateFileInfo instance) =>
    <String, dynamic>{
      'path': instance.path,
      'size': instance.size,
      'sha256': instance.sha256,
    };

_UpdateManifest _$UpdateManifestFromJson(Map<String, dynamic> json) =>
    _UpdateManifest(
      version: json['version'] as String,
      buildNumber: (json['buildNumber'] as num).toInt(),
      releaseDate: DateTime.parse(json['releaseDate'] as String),
      platform: json['platform'] as String,
      arch: json['arch'] as String,
      minVersion: json['minVersion'] as String?,
      files: (json['files'] as Map<String, dynamic>).map(
        (k, e) =>
            MapEntry(k, UpdateFileInfo.fromJson(e as Map<String, dynamic>)),
      ),
      totalSize: (json['totalSize'] as num).toInt(),
      compressedSize: (json['compressedSize'] as num).toInt(),
      packageSha256: json['packageSha256'] as String?,
      downloadUrl: json['downloadUrl'] as String,
      releaseNotes: json['releaseNotes'] as String?,
      signature: json['signature'] as String?,
    );

Map<String, dynamic> _$UpdateManifestToJson(_UpdateManifest instance) =>
    <String, dynamic>{
      'version': instance.version,
      'buildNumber': instance.buildNumber,
      'releaseDate': instance.releaseDate.toIso8601String(),
      'platform': instance.platform,
      'arch': instance.arch,
      'minVersion': instance.minVersion,
      'files': instance.files,
      'totalSize': instance.totalSize,
      'compressedSize': instance.compressedSize,
      'packageSha256': instance.packageSha256,
      'downloadUrl': instance.downloadUrl,
      'releaseNotes': instance.releaseNotes,
      'signature': instance.signature,
    };

_VersionInfo _$VersionInfoFromJson(Map<String, dynamic> json) => _VersionInfo(
  latestVersion: json['latestVersion'] as String,
  latestBuildNumber: (json['latestBuildNumber'] as num).toInt(),
  channels: (json['channels'] as Map<String, dynamic>).map(
    (k, e) => MapEntry(k, ChannelInfo.fromJson(e as Map<String, dynamic>)),
  ),
  minSupportedVersion: json['minSupportedVersion'] as String?,
  serverVersion: json['serverVersion'] as String?,
);

Map<String, dynamic> _$VersionInfoToJson(_VersionInfo instance) =>
    <String, dynamic>{
      'latestVersion': instance.latestVersion,
      'latestBuildNumber': instance.latestBuildNumber,
      'channels': instance.channels,
      'minSupportedVersion': instance.minSupportedVersion,
      'serverVersion': instance.serverVersion,
    };

_ChannelInfo _$ChannelInfoFromJson(Map<String, dynamic> json) => _ChannelInfo(
  version: json['version'] as String,
  manifestUrl: json['manifestUrl'] as String,
);

Map<String, dynamic> _$ChannelInfoToJson(_ChannelInfo instance) =>
    <String, dynamic>{
      'version': instance.version,
      'manifestUrl': instance.manifestUrl,
    };
