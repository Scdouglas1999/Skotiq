part of '../quick_start_service.dart';

/// Represents a snapshot of equipment state at a point in time.
/// Used to restore equipment settings when resuming a session.
class EquipmentSnapshot {
  /// Target temperature for camera cooling (Celsius)
  final double? coolerTargetTemp;

  final int? cameraGain;

  final int? cameraOffset;

  final int? cameraBinX;

  final int? cameraBinY;

  /// Filter wheel position (0-indexed)
  final int? filterPosition;

  /// The name of the filter at [filterPosition] when it was recorded.
  final String? filterName;

  /// Focuser position in steps
  final int? focuserPosition;

  /// Last used exposure time in seconds
  final double? exposureTime;

  final DateTime capturedAt;

  const EquipmentSnapshot({
    this.coolerTargetTemp,
    this.cameraGain,
    this.cameraOffset,
    this.cameraBinX,
    this.cameraBinY,
    this.filterPosition,
    this.filterName,
    this.focuserPosition,
    this.exposureTime,
    required this.capturedAt,
  });

  EquipmentSnapshot copyWith({
    double? coolerTargetTemp,
    int? cameraGain,
    int? cameraOffset,
    int? cameraBinX,
    int? cameraBinY,
    int? filterPosition,
    String? filterName,
    int? focuserPosition,
    double? exposureTime,
    DateTime? capturedAt,
  }) {
    return EquipmentSnapshot(
      coolerTargetTemp: coolerTargetTemp ?? this.coolerTargetTemp,
      cameraGain: cameraGain ?? this.cameraGain,
      cameraOffset: cameraOffset ?? this.cameraOffset,
      cameraBinX: cameraBinX ?? this.cameraBinX,
      cameraBinY: cameraBinY ?? this.cameraBinY,
      filterPosition: filterPosition ?? this.filterPosition,
      filterName: filterName ?? this.filterName,
      focuserPosition: focuserPosition ?? this.focuserPosition,
      exposureTime: exposureTime ?? this.exposureTime,
      capturedAt: capturedAt ?? this.capturedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'coolerTargetTemp': coolerTargetTemp,
      'cameraGain': cameraGain,
      'cameraOffset': cameraOffset,
      'cameraBinX': cameraBinX,
      'cameraBinY': cameraBinY,
      'filterPosition': filterPosition,
      'filterName': filterName,
      'focuserPosition': focuserPosition,
      'exposureTime': exposureTime,
      'capturedAt': capturedAt.toIso8601String(),
    };
  }

  factory EquipmentSnapshot.fromJson(Map<String, dynamic> json) {
    return EquipmentSnapshot(
      coolerTargetTemp: jsonDouble(
        json['coolerTargetTemp'],
        context: 'equipment_snapshot.coolerTargetTemp',
      ),
      cameraGain: jsonInt(
        json['cameraGain'],
        context: 'equipment_snapshot.cameraGain',
      ),
      cameraOffset: jsonInt(
        json['cameraOffset'],
        context: 'equipment_snapshot.cameraOffset',
      ),
      cameraBinX: jsonInt(
        json['cameraBinX'],
        context: 'equipment_snapshot.cameraBinX',
      ),
      cameraBinY: jsonInt(
        json['cameraBinY'],
        context: 'equipment_snapshot.cameraBinY',
      ),
      filterPosition: jsonInt(
        json['filterPosition'],
        context: 'equipment_snapshot.filterPosition',
      ),
      filterName: jsonString(
        json['filterName'],
        context: 'equipment_snapshot.filterName',
      ),
      focuserPosition: jsonInt(
        json['focuserPosition'],
        context: 'equipment_snapshot.focuserPosition',
      ),
      exposureTime: jsonDouble(
        json['exposureTime'],
        context: 'equipment_snapshot.exposureTime',
      ),
      capturedAt:
          jsonDateTime(
            json['capturedAt'],
            context: 'equipment_snapshot.capturedAt',
          ) ??
          DateTime.now(),
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory EquipmentSnapshot.fromJsonString(String jsonStr) {
    final json = decodeJsonObjectString(
      jsonStr,
      context: 'imaging_sessions.equipment_snapshot',
    );
    return EquipmentSnapshot.fromJson(json);
  }

  bool get hasEquipmentData {
    return coolerTargetTemp != null ||
        cameraGain != null ||
        cameraOffset != null ||
        cameraBinX != null ||
        cameraBinY != null ||
        filterPosition != null ||
        focuserPosition != null ||
        exposureTime != null;
  }

  @override
  String toString() {
    return 'EquipmentSnapshot('
        'coolerTargetTemp: $coolerTargetTemp, '
        'cameraGain: $cameraGain, '
        'cameraOffset: $cameraOffset, '
        'cameraBinX: $cameraBinX, '
        'cameraBinY: $cameraBinY, '
        'filterPosition: $filterPosition, '
        'focuserPosition: $focuserPosition, '
        'exposureTime: $exposureTime, '
        'capturedAt: $capturedAt)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EquipmentSnapshot &&
        other.coolerTargetTemp == coolerTargetTemp &&
        other.cameraGain == cameraGain &&
        other.cameraOffset == cameraOffset &&
        other.cameraBinX == cameraBinX &&
        other.cameraBinY == cameraBinY &&
        other.filterPosition == filterPosition &&
        other.focuserPosition == focuserPosition &&
        other.exposureTime == exposureTime &&
        other.capturedAt == capturedAt;
  }

  @override
  int get hashCode {
    return Object.hash(
      coolerTargetTemp,
      cameraGain,
      cameraOffset,
      cameraBinX,
      cameraBinY,
      filterPosition,
      focuserPosition,
      exposureTime,
      capturedAt,
    );
  }
}

/// Contains all the information needed to quickly resume a previous session.
/// This includes session details, target info, sequence progress, and equipment state.
class QuickStartContext {
  final int sessionId;

  /// User-provided session name
  final String? sessionName;

  final int? profileId;

  final String? profileName;

  final int? targetId;

  /// Target name (e.g., "Orion Nebula")
  final String? targetName;

  /// Target right ascension in decimal hours
  final double? targetRa;

  /// Target declination in decimal degrees
  final double? targetDec;

  final int? sequenceId;

  final String? sequenceName;

  /// Number of frames completed in the sequence
  final int completedFrames;

  /// Total frames planned in the sequence
  final int totalFrames;

  final DateTime lastSessionDate;

  final EquipmentSnapshot? equipmentSnapshot;

  /// Total integration time accumulated in hours
  final double totalIntegrationHours;

  /// True only when the execution backend has a resumable checkpoint for this
  /// sequence. Historical session progress alone is not a checkpoint.
  final bool canResumeFromCheckpoint;

  /// True when the operator stopped the run (keeping its resume point);
  /// false when it was interrupted, by a crash or a closed app.
  final bool stoppedByOperator;

  const QuickStartContext({
    required this.sessionId,
    this.sessionName,
    this.profileId,
    this.profileName,
    this.targetId,
    this.targetName,
    this.targetRa,
    this.targetDec,
    this.sequenceId,
    this.sequenceName,
    this.completedFrames = 0,
    this.totalFrames = 0,
    required this.lastSessionDate,
    this.equipmentSnapshot,
    this.totalIntegrationHours = 0.0,
    this.canResumeFromCheckpoint = false,
    this.stoppedByOperator = false,
  });

  /// Decorate this historical context with the backend's current checkpoint.
  /// A name match is the strongest identity available in the checkpoint wire
  /// model; mismatches remain load-only quick starts.
  QuickStartContext withCheckpointInfo(CheckpointInfo? checkpoint) {
    final matches =
        checkpoint != null &&
        checkpoint.canResume &&
        sequenceName != null &&
        checkpoint.sequenceName.trim() == sequenceName!.trim();
    return QuickStartContext(
      sessionId: sessionId,
      sessionName: sessionName,
      profileId: profileId,
      profileName: profileName,
      targetId: targetId,
      targetName: targetName,
      targetRa: targetRa,
      targetDec: targetDec,
      sequenceId: sequenceId,
      sequenceName: sequenceName,
      completedFrames: matches
          ? math.max(completedFrames, checkpoint.completedExposures)
          : completedFrames,
      // The plan's total, never the frames taken: a total equal to the
      // frames taken read as a finished run, and the prompt then offered
      // nothing for a run stopped with its resume point kept.
      totalFrames: totalFrames,
      lastSessionDate: lastSessionDate,
      equipmentSnapshot: equipmentSnapshot,
      totalIntegrationHours: matches
          ? math.max(
              totalIntegrationHours,
              checkpoint.completedIntegrationSecs / 3600.0,
            )
          : totalIntegrationHours,
      canResumeFromCheckpoint: matches,
      stoppedByOperator: stoppedByOperator,
    );
  }

  double get progressPercentage {
    if (totalFrames == 0) return 0.0;
    return (completedFrames / totalFrames * 100).clamp(0.0, 100.0);
  }

  bool get hasProgress => completedFrames > 0 || totalIntegrationHours > 0;

  bool get hasTargetCoordinates => targetRa != null && targetDec != null;

  bool get hasEquipmentSnapshot =>
      equipmentSnapshot != null && equipmentSnapshot!.hasEquipmentData;

  String get displayDescription {
    final parts = <String>[];

    if (targetName != null) {
      parts.add(targetName!);
    } else if (sessionName != null) {
      parts.add(sessionName!);
    } else {
      parts.add('Session #$sessionId');
    }

    if (completedFrames > 0) {
      parts.add(
        totalFrames > 0
            ? '$completedFrames/$totalFrames frames'
            : '$completedFrames frames',
      );
    }

    if (totalIntegrationHours > 0) {
      parts.add('${totalIntegrationHours.toStringAsFixed(1)}h');
    }

    return parts.join(' - ');
  }

  Duration get timeSinceLastSession {
    return DateTime.now().difference(lastSessionDate);
  }

  /// Check if this is a recent session (within 7 days)
  bool get isRecent {
    return timeSinceLastSession.inDays <= 7;
  }

  /// Check if this session was from tonight (within 12 hours)
  bool get isFromTonight {
    return timeSinceLastSession.inHours <= 12;
  }

  @override
  String toString() {
    return 'QuickStartContext('
        'sessionId: $sessionId, '
        'sessionName: $sessionName, '
        'targetName: $targetName, '
        'completedFrames: $completedFrames/$totalFrames, '
        'lastSessionDate: $lastSessionDate)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is QuickStartContext &&
        other.sessionId == sessionId &&
        other.sessionName == sessionName &&
        other.profileId == profileId &&
        other.profileName == profileName &&
        other.targetId == targetId &&
        other.targetName == targetName &&
        other.targetRa == targetRa &&
        other.targetDec == targetDec &&
        other.sequenceId == sequenceId &&
        other.sequenceName == sequenceName &&
        other.completedFrames == completedFrames &&
        other.totalFrames == totalFrames &&
        other.lastSessionDate == lastSessionDate &&
        other.equipmentSnapshot == equipmentSnapshot &&
        other.totalIntegrationHours == totalIntegrationHours &&
        other.canResumeFromCheckpoint == canResumeFromCheckpoint;
  }

  @override
  int get hashCode {
    return Object.hash(
      sessionId,
      sessionName,
      profileId,
      profileName,
      targetId,
      targetName,
      targetRa,
      targetDec,
      sequenceId,
      sequenceName,
      completedFrames,
      totalFrames,
      lastSessionDate,
      equipmentSnapshot,
      totalIntegrationHours,
      canResumeFromCheckpoint,
    );
  }
}
