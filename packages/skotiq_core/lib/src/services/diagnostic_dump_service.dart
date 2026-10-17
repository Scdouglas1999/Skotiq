import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../database/database.dart' show EquipmentProfile;
import '../models/equipment/equipment_models.dart';
import '../models/sequence/sequence_models.dart';
import '../providers/app_version_provider.dart';
import '../providers/equipment/camera_state_provider.dart';
import '../providers/equipment/cover_calibrator_state_provider.dart';
import '../providers/equipment/dome_state_provider.dart';
import '../providers/equipment/filter_wheel_state_provider.dart';
import '../providers/equipment/focuser_state_provider.dart';
import '../providers/equipment/guider_state_provider.dart';
import '../providers/equipment/mount_state_provider.dart';
import '../providers/equipment/rotator_state_provider.dart';
import '../providers/equipment/safety_monitor_state_provider.dart';
import '../providers/equipment/weather_state_provider.dart';
import '../providers/database_provider.dart';
import '../providers/sequence_provider.dart';
import 'logging_service.dart';
import '../utils/skotiq_data_directory.dart';

/// Snapshot of one device's contribution to the diagnostic-dump device list.
///
/// Why a dedicated struct rather than `Map<String, Object?>`: bug reports are
/// the primary consumer; field stability across versions matters more than
/// flexibility. A typed record forces every gather-step to fill in the same
/// columns, so a missing field surfaces at compile time instead of as an
/// invisible gap in the JSON.
class DumpDeviceEntry {
  final String role;
  final String connectionState;
  final String? deviceId;
  final String? deviceName;
  final String? lastError;

  const DumpDeviceEntry({
    required this.role,
    required this.connectionState,
    this.deviceId,
    this.deviceName,
    this.lastError,
  });

  Map<String, Object?> toJson() => {
    'role': role,
    'connection_state': connectionState,
    'device_id': deviceId,
    'device_name': deviceName,
    'last_error': lastError,
  };
}

/// Tagged outcome for one gather step. The dump always emits the file even
/// if the gather failed; the failure payload is the body so support engineers
/// can see what went wrong without the dump silently missing an entry.
class _GatherOutcome {
  final Object? data;
  final String? error;

  const _GatherOutcome.success(this.data) : error = null;
  const _GatherOutcome.failure(this.error) : data = null;

  Map<String, Object?> toErrorJson() => {
    'error': error ?? 'unknown',
    'collected_at': DateTime.now().toUtc().toIso8601String(),
  };
}

/// Bundles app state into a single zip suitable for attaching to bug reports.
///
/// Contents (deterministic layout — keep stable so issue templates can
/// reference paths):
/// - `manifest.json`              dump version + per-entry status
/// - `system_info.json`           OS, Dart/Flutter, app version, install path
/// - `profile.json`               active equipment profile (or error stub)
/// - `sequence.json`              current sequence state (or "no sequence")
/// - `devices.json`               connected device list (optional)
/// - `logs/<basename>`            one entry per rotated log file, raw text
///
/// Every gather step is wrapped so one failure cannot abort the whole dump.
/// A gather failure is logged at `error` level and preserved verbatim inside
/// the failed entry's body, so the bug-report reader sees what went wrong.
class DiagnosticDumpService {
  /// Current dump-bundle layout version. Bump when the file layout or any
  /// field semantics change so consumers (issue triage scripts) can detect
  /// incompatible bundles.
  static const int bundleVersion = 1;

  final LoggingService _logging;
  final Future<Map<String, Object?>?> Function() _gatherProfile;
  final Sequence? Function() _gatherSequence;
  final List<DumpDeviceEntry> Function() _gatherDevices;
  final Future<Map<String, Object?>> Function() _gatherSystemInfo;
  final Future<Directory> Function() _tempDirProvider;

  DiagnosticDumpService({
    required LoggingService logging,
    required Future<Map<String, Object?>?> Function() gatherProfile,
    required Sequence? Function() gatherSequence,
    required List<DumpDeviceEntry> Function() gatherDevices,
    required Future<Map<String, Object?>> Function() gatherSystemInfo,
    Future<Directory> Function()? tempDirProvider,
  }) : _logging = logging,
       _gatherProfile = gatherProfile,
       _gatherSequence = gatherSequence,
       _gatherDevices = gatherDevices,
       _gatherSystemInfo = gatherSystemInfo,
       _tempDirProvider = tempDirProvider ?? getTemporaryDirectory;

  /// Build the zip and write it to [outputPath] (or a generated path under
  /// the documents directory if null). Returns the resulting File.
  ///
  /// The file is overwritten if it exists. Caller is responsible for picking
  /// a non-conflicting path when running interactively (the
  /// `diagnostic_dump_screen` uses a timestamped filename).
  Future<File> createDump({required String outputPath}) async {
    final manifest = <String, Object?>{
      'bundle_version': bundleVersion,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'entries': <Map<String, Object?>>[],
    };
    final entries = manifest['entries'] as List<Map<String, Object?>>;

    final archive = Archive();

    // system_info.json
    await _addJsonEntry(
      archive: archive,
      entries: entries,
      path: 'system_info.json',
      gather: () async => _GatherOutcome.success(await _gatherSystemInfo()),
      stepName: 'system_info',
    );

    // profile.json
    await _addJsonEntry(
      archive: archive,
      entries: entries,
      path: 'profile.json',
      gather: () async {
        try {
          final profile = await _gatherProfile();
          // Why a synthetic object instead of `null`: the file is always
          // present in the dump (so triage scripts can rely on the path);
          // when no active profile exists we record that explicitly rather
          // than producing an empty file that could be misread as corruption.
          return _GatherOutcome.success(
            profile ??
                <String, Object?>{
                  'active_profile': null,
                  'note': 'No active equipment profile is set.',
                },
          );
        } catch (e, st) {
          _logging.error(
            'DiagnosticDump: profile gather failed: $e',
            source: 'DiagnosticDumpService',
            fields: {'stack': st.toString()},
          );
          return _GatherOutcome.failure('Profile gather failed: $e');
        }
      },
      stepName: 'profile',
    );

    // sequence.json
    await _addJsonEntry(
      archive: archive,
      entries: entries,
      path: 'sequence.json',
      gather: () async {
        try {
          final sequence = _gatherSequence();
          if (sequence == null) {
            return const _GatherOutcome.success(<String, Object?>{
              'current_sequence': null,
              'note': 'No sequence is currently loaded.',
            });
          }
          return _GatherOutcome.success(_sequenceToJson(sequence));
        } catch (e, st) {
          _logging.error(
            'DiagnosticDump: sequence gather failed: $e',
            source: 'DiagnosticDumpService',
            fields: {'stack': st.toString()},
          );
          return _GatherOutcome.failure('Sequence gather failed: $e');
        }
      },
      stepName: 'sequence',
    );

    // devices.json
    await _addJsonEntry(
      archive: archive,
      entries: entries,
      path: 'devices.json',
      gather: () async {
        try {
          final devices = _gatherDevices();
          return _GatherOutcome.success({
            'collected_at': DateTime.now().toUtc().toIso8601String(),
            'count': devices.length,
            'devices': devices.map((d) => d.toJson()).toList(),
          });
        } catch (e, st) {
          _logging.error(
            'DiagnosticDump: devices gather failed: $e',
            source: 'DiagnosticDumpService',
            fields: {'stack': st.toString()},
          );
          return _GatherOutcome.failure('Devices gather failed: $e');
        }
      },
      stepName: 'devices',
    );

    // logs/
    // Why use a temp scratch file: LoggingService.exportLogs writes to a path
    // we then immediately read back. That gives us the same concatenated
    // export the existing settings → log-viewer flow produces, without
    // duplicating the rotation/concatenation logic.
    await _addLogsEntry(archive: archive, entries: entries);

    // manifest.json
    // Written last so it reflects the final entries list.
    archive.addFile(
      _textFile(
        'manifest.json',
        const JsonEncoder.withIndent('  ').convert(manifest),
      ),
    );

    // Encode to disk
    final outFile = File(outputPath);
    final parent = outFile.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final bytes = ZipEncoder().encode(archive);
    if (bytes == null) {
      // ZipEncoder.encode currently never returns null in practice, but the
      // signature is nullable; surface that loudly instead of writing a
      // zero-byte file the user would attach without realizing it's empty.
      throw StateError(
        'ZipEncoder produced no bytes; diagnostic dump aborted.',
      );
    }
    await outFile.writeAsBytes(bytes, flush: true);

    _logging.info(
      'Diagnostic dump written to $outputPath '
      '(${bytes.length} bytes, ${archive.length} entries)',
      source: 'DiagnosticDumpService',
    );
    return outFile;
  }

  Future<void> _addJsonEntry({
    required Archive archive,
    required List<Map<String, Object?>> entries,
    required String path,
    required Future<_GatherOutcome> Function() gather,
    required String stepName,
  }) async {
    final outcome = await gather();
    final Object? body;
    final String status;
    if (outcome.error != null) {
      body = outcome.toErrorJson();
      status = 'failed';
    } else {
      body = outcome.data;
      status = 'ok';
    }
    final encoded = const JsonEncoder.withIndent('  ').convert(body);
    archive.addFile(_textFile(path, encoded));
    entries.add({
      'name': stepName,
      'path': path,
      'status': status,
      if (outcome.error != null) 'error': outcome.error,
    });
  }

  /// How much log history a dump carries.
  ///
  /// The native appender (tracing_appender daily roller) has no retention cap,
  /// so the log directory grows forever and an unbounded export would ship
  /// every capture path, target name and host name the install ever wrote. Two
  /// days covers last night plus the night before, the window a bug report
  /// about an imaging session needs.
  static const Duration logRetentionWindow = Duration(hours: 48);

  Future<void> _addLogsEntry({
    required Archive archive,
    required List<Map<String, Object?>> entries,
  }) async {
    try {
      // exportLogs concatenates all rotated logs to one file; we add it as a
      // single archive entry under logs/ so reviewers can scroll one file.
      final tmpDir = await _tempDirProvider();
      if (!await tmpDir.exists()) {
        await tmpDir.create(recursive: true);
      }
      final scratch = File(
        '${tmpDir.path}${Platform.pathSeparator}'
        'skotiq_dump_logs_${DateTime.now().microsecondsSinceEpoch}.txt',
      );
      await _logging.exportLogs(scratch.path, maxAge: logRetentionWindow);
      final bytes = await scratch.readAsBytes();
      archive.addFile(
        ArchiveFile('logs/exported_logs.txt', bytes.length, bytes),
      );
      try {
        await scratch.delete();
      } on FileSystemException catch (e) {
        // Why log instead of throw: the scratch file is in the OS temp dir;
        // failing to delete it is a janitorial concern, not a dump-integrity
        // concern. The dump itself succeeded.
        _logging.warning(
          'DiagnosticDump: could not delete scratch log file ${scratch.path}: $e',
          source: 'DiagnosticDumpService',
        );
      }
      entries.add({
        'name': 'logs',
        'path': 'logs/exported_logs.txt',
        'status': 'ok',
        'bytes': bytes.length,
        // The recipient of a bug report must be able to see how much history
        // they were handed; the UI calls this entry "recent log files".
        'span_hours': logRetentionWindow.inHours,
        'span_start': DateTime.now()
            .toUtc()
            .subtract(logRetentionWindow)
            .toIso8601String(),
      });
    } catch (e, st) {
      _logging.error(
        'DiagnosticDump: logs gather failed: $e',
        source: 'DiagnosticDumpService',
        fields: {'stack': st.toString()},
      );
      final stub = const JsonEncoder.withIndent('  ').convert({
        'error': 'Logs gather failed: $e',
        'collected_at': DateTime.now().toUtc().toIso8601String(),
      });
      archive.addFile(_textFile('logs/exported_logs.error.json', stub));
      entries.add({
        'name': 'logs',
        'path': 'logs/exported_logs.error.json',
        'status': 'failed',
        'error': 'Logs gather failed: $e',
      });
    }
  }

  ArchiveFile _textFile(String path, String body) {
    final bytes = utf8.encode(body);
    return ArchiveFile(path, bytes.length, bytes);
  }
}

/// Build a JSON-serializable view of a [Sequence].
///
/// Why we don't just call into `SequenceFileService._sequenceToJson`: that
/// method is private and lives behind a `file_selector` import path. The
/// diagnostic dump needs the same shape minus the UI coupling, so we mirror
/// the structure here and only include the fields a triage engineer needs
/// (full node bodies aren't required — the count + tree shape is what
/// catches "wrong sequence loaded" bugs).
Map<String, Object?> _sequenceToJson(Sequence sequence) {
  return {
    'id': sequence.id,
    'database_id': sequence.databaseId,
    'name': sequence.name,
    'description': sequence.description,
    'root_node_id': sequence.rootNodeId,
    'is_template': sequence.isTemplate,
    'created_at': sequence.createdAt.toIso8601String(),
    'modified_at': sequence.modifiedAt.toIso8601String(),
    'estimated_duration_mins': sequence.estimatedDurationMins,
    'node_count': sequence.nodes.length,
    'nodes': sequence.nodes.map(
      (id, node) => MapEntry(id, {
        'id': node.id,
        'node_type': node.nodeType,
        'name': node.name,
        'parent_id': node.parentId,
        'child_ids': node.childIds,
        'order_index': node.orderIndex,
        'is_enabled': node.isEnabled,
        'comment': node.comment,
      }),
    ),
  };
}

/// Provider that wires the live app's gather closures into the service.
///
/// All gather closures are bound at provider-build time, so consumers don't
/// need to inject anything beyond the Riverpod ref. Tests construct
/// `DiagnosticDumpService` directly with stubbed closures (see
/// `diagnostic_dump_service_test.dart`).
final diagnosticDumpServiceProvider = Provider<DiagnosticDumpService>((ref) {
  final logging = ref.read(loggingServiceProvider);

  return DiagnosticDumpService(
    logging: logging,
    gatherProfile: () => _gatherActiveProfileJson(ref),
    gatherSequence: () => ref.read(currentSequenceProvider),
    gatherDevices: () => _gatherDeviceEntries(ref),
    gatherSystemInfo: () => _gatherSystemInfo(ref),
  );
});

Future<Map<String, Object?>?> _gatherActiveProfileJson(Ref ref) async {
  final dao = ref.read(equipmentProfilesDaoProvider);
  final profile = await dao.getDefaultProfile() ?? await dao.getActiveProfile();
  if (profile == null) return null;
  return _profileToJson(profile);
}

Map<String, Object?> _profileToJson(EquipmentProfile profile) {
  // ProfileExportData.toJson() is the canonical serialization but it lives
  // alongside the import/export workflow; using it here would couple the
  // dump to the import-validator. Inline the same fields explicitly.
  return {
    'id': profile.id,
    'name': profile.name,
    'description': profile.description,
    'is_active': profile.isActive,
    'is_default': profile.isDefault,
    'camera_id': profile.cameraId,
    'mount_id': profile.mountId,
    'focuser_id': profile.focuserId,
    'filter_wheel_id': profile.filterWheelId,
    'guider_id': profile.guiderId,
    'rotator_id': profile.rotatorId,
    'dome_id': profile.domeId,
    'weather_id': profile.weatherId,
    'cover_calibrator_id': profile.coverCalibratorId,
    'focal_length': profile.focalLength,
    'aperture': profile.aperture,
    'focal_ratio': profile.focalRatio,
    'default_gain': profile.defaultGain,
    'default_offset': profile.defaultOffset,
    'default_bin_x': profile.defaultBinX,
    'default_bin_y': profile.defaultBinY,
    'default_cooling_temp': profile.defaultCoolingTemp,
    'filter_names': profile.filterNames,
    'filter_focus_offsets': profile.filterFocusOffsets,
    'created_at': profile.createdAt.toIso8601String(),
    'updated_at': profile.updatedAt.toIso8601String(),
  };
}

List<DumpDeviceEntry> _gatherDeviceEntries(Ref ref) {
  final entries = <DumpDeviceEntry>[];

  void add({
    required String role,
    required DeviceConnectionState state,
    String? id,
    String? name,
    DeviceError? error,
  }) {
    entries.add(
      DumpDeviceEntry(
        role: role,
        connectionState: state.name,
        deviceId: id,
        deviceName: name,
        lastError: error == null
            ? null
            : (error.code != null
                  ? '${error.code}: ${error.message}'
                  : error.message),
      ),
    );
  }

  final camera = ref.read(cameraStateProvider);
  add(
    role: 'camera',
    state: camera.connectionState,
    id: camera.deviceId,
    name: camera.deviceName,
    error: camera.lastError,
  );

  final mount = ref.read(mountStateProvider);
  add(
    role: 'mount',
    state: mount.connectionState,
    id: mount.deviceId,
    name: mount.deviceName,
    error: mount.lastError,
  );

  final focuser = ref.read(focuserStateProvider);
  add(
    role: 'focuser',
    state: focuser.connectionState,
    id: focuser.deviceId,
    name: focuser.deviceName,
    error: focuser.lastError,
  );

  final filterWheel = ref.read(filterWheelStateProvider);
  add(
    role: 'filter_wheel',
    state: filterWheel.connectionState,
    id: filterWheel.deviceId,
    name: filterWheel.deviceName,
    error: filterWheel.lastError,
  );

  final guider = ref.read(guiderStateProvider);
  add(
    role: 'guider',
    state: guider.connectionState,
    id: guider.deviceId,
    name: guider.deviceName,
    error: guider.lastError,
  );

  final rotator = ref.read(rotatorStateProvider);
  add(
    role: 'rotator',
    state: rotator.connectionState,
    id: rotator.deviceId,
    name: rotator.deviceName,
    error: rotator.lastError,
  );

  final dome = ref.read(domeStateProvider);
  add(
    role: 'dome',
    state: dome.connectionState,
    id: dome.deviceId,
    name: dome.deviceName,
    error: dome.lastError,
  );

  final weather = ref.read(weatherStateProvider);
  add(
    role: 'weather',
    state: weather.connectionState,
    id: weather.deviceId,
    name: weather.deviceName,
    error: weather.lastError,
  );

  final cover = ref.read(coverCalibratorStateProvider);
  add(
    role: 'cover_calibrator',
    state: cover.connectionState,
    id: cover.deviceId,
    name: cover.deviceName,
    error: cover.lastError,
  );

  final safety = ref.read(safetyMonitorStateProvider);
  add(
    role: 'safety_monitor',
    state: safety.connectionState,
    id: safety.deviceId,
    name: safety.deviceName,
    error: safety.lastError,
  );

  return entries;
}

Future<Map<String, Object?>> _gatherSystemInfo(Ref ref) async {
  // appVersionProvider intentionally throws if not overridden (per its
  // contract). Catch that here so a misconfigured test bench doesn't take
  // down the whole dump — log the failure visibly and fall through to a
  // placeholder so the file path is preserved.
  String? version;
  int? build;
  String? versionError;
  try {
    final v = ref.read(appVersionProvider);
    version = v.version;
    build = v.buildNumber;
  } catch (e) {
    versionError = 'appVersionProvider not overridden: $e';
  }

  Directory? supportDir;
  try {
    supportDir = await resolveSkotiqDataDirectory();
  } on Exception catch (_) {
    // path_provider can fail on unconfigured test harnesses or unusual OS
    // configurations; leave the path null rather than aborting the dump.
  }

  return {
    'collected_at': DateTime.now().toUtc().toIso8601String(),
    'app_version': version,
    'app_build_number': build,
    if (versionError != null) 'app_version_error': versionError,
    'platform': {
      'operating_system': Platform.operatingSystem,
      'operating_system_version': Platform.operatingSystemVersion,
      'locale': Platform.localeName,
      'number_of_processors': Platform.numberOfProcessors,
      'path_separator': Platform.pathSeparator,
      'dart_version': Platform.version,
      'executable': Platform.resolvedExecutable,
      'script_uri': Platform.script.toString(),
    },
    'install_path': supportDir?.path,
  };
}
