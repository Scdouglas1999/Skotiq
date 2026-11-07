import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/imaging/imaging_models.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// The manual Loop as the host runs it.
///
/// A loop runs on the host, whichever window started it: a client's Loop
/// and Stop are commands to the host (`POST /api/runtime/manual-loop`), so
/// there is one loop and one state, and either window can stop it.
@immutable
class ManualLoopStatus {
  const ManualLoopStatus({
    this.looping = false,
    this.stopping = false,
    this.frames = 0,
    this.lastError,
    this.errorCount = 0,
  });

  static const idle = ManualLoopStatus();

  /// A loop is running.
  final bool looping;

  /// Stop was asked for and the exposure in flight is being aborted.
  final bool stopping;

  /// Frames the current (or last) loop delivered.
  final int frames;

  /// The newest capture failure, cleaned for the operator.
  final String? lastError;

  /// How many failures the current loop has had, so the same message twice
  /// still reads as a new failure.
  final int errorCount;

  ManualLoopStatus copyWith({
    bool? looping,
    bool? stopping,
    int? frames,
    String? lastError,
    int? errorCount,
  }) => ManualLoopStatus(
    looping: looping ?? this.looping,
    stopping: stopping ?? this.stopping,
    frames: frames ?? this.frames,
    lastError: lastError ?? this.lastError,
    errorCount: errorCount ?? this.errorCount,
  );

  @override
  bool operator ==(Object other) =>
      other is ManualLoopStatus &&
      other.looping == looping &&
      other.stopping == stopping &&
      other.frames == frames &&
      other.lastError == lastError &&
      other.errorCount == errorCount;

  @override
  int get hashCode =>
      Object.hash(looping, stopping, frames, lastError, errorCount);
}

/// The host's loop. Written by the host's capture controller; on a client,
/// by this channel.
final manualLoopStatusProvider = StateProvider<ManualLoopStatus>(
  (ref) => ManualLoopStatus.idle,
);

/// The host's manual Loop, shown the same in every window: Stop on both
/// ends, Snapshot and Loop held on both ends while it runs.
class ManualLoopChannel extends RuntimeMirrorChannel<ManualLoopStatus> {
  const ManualLoopChannel();

  @override
  String get key => 'manualLoop';

  @override
  get source => manualLoopStatusProvider;

  @override
  Map<String, dynamic>? encode(ManualLoopStatus value) => {
    'looping': value.looping,
    'stopping': value.stopping,
    'frames': value.frames,
    if (value.lastError != null) 'lastError': value.lastError,
    'errorCount': value.errorCount,
  };

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    context.read(manualLoopStatusProvider.notifier).state = value == null
        ? ManualLoopStatus.idle
        : ManualLoopStatus(
            looping: value['looping'] == true,
            stopping: value['stopping'] == true,
            frames: requireInt(value, 'frames'),
            lastError: jsonString(value['lastError']),
            errorCount: requireInt(value, 'errorCount'),
          );
  }
}

/// What a client asks the host's Loop to use: the exposure settings, target
/// and "save loop frames" choice as the client's operator sees them.
Map<String, dynamic> manualLoopRequestJson({
  required ExposureSettings settings,
  required bool saveFrames,
  String? targetName,
}) => {
  'settings': {
    'exposureTime': finiteOrNull(settings.exposureTime),
    'gain': settings.gain,
    'offset': settings.offset,
    'binningX': settings.binningX,
    'binningY': settings.binningY,
    if (settings.filter != null) 'filter': settings.filter,
    'frameType': settings.frameType.name,
    'fastReadout': settings.fastReadout,
    if (settings.readoutModeIndex != null)
      'readoutModeIndex': settings.readoutModeIndex,
  },
  'saveFrames': saveFrames,
  if (targetName != null) 'targetName': targetName,
};

/// The settings of a [manualLoopRequestJson] request. Throws
/// [FormatException] when the request has none, or no exposure time.
ExposureSettings manualLoopSettingsFromJson(Map<dynamic, dynamic> request) {
  final raw = request['settings'];
  if (raw is! Map) throw const FormatException('Loop request has no settings');
  return ExposureSettings(
    exposureTime: requireDouble(raw, 'exposureTime'),
    gain: requireInt(raw, 'gain'),
    offset: requireInt(raw, 'offset'),
    binningX: jsonInt(raw['binningX']) ?? 1,
    binningY: jsonInt(raw['binningY']) ?? 1,
    filter: jsonString(raw['filter']),
    frameType: FrameType.values.firstWhere(
      (t) => t.name == raw['frameType'],
      orElse: () => FrameType.light,
    ),
    fastReadout: raw['fastReadout'] == true,
    readoutModeIndex: jsonInt(raw['readoutModeIndex']),
  );
}
