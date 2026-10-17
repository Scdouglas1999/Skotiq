part of '../quick_start_service.dart';

// EquipmentSnapshot - Captures equipment state for quick session resumption

/// Represents a snapshot of equipment state at a point in time.
/// Used to restore equipment settings when resuming a session.
class EquipmentSnapshot {
  /// Target temperature for camera cooling (Celsius)
  final double? coolerTargetTemp;

  /// Camera gain setting
  final int? cameraGain;

  /// Camera offset setting
  final int? cameraOffset;

  /// Camera horizontal binning
  final int? cameraBinX;

  /// Camera vertical binning
  final int? cameraBinY;

  /// Filter wheel position (0-indexed)
  final int? filterPosition;

  /// Focuser position in steps
  final int? focuserPosition;

  /// Last used exposure time in seconds
  final double? exposureTime;

  /// When this snapshot was captured
  final DateTime capturedAt;

  const EquipmentSnapshot({
    this.coolerTargetTemp,
    this.cameraGain,
    this.cameraOffset,
    this.cameraBinX,
    this.cameraBinY,
    this.filterPosition,
    this.focuserPosition,
    this.exposureTime,
    required this.capturedAt,
  });

  /// Create a copy with some fields replaced
  EquipmentSnapshot copyWith({
    double? coolerTargetTemp,
    int? cameraGain,
    int? cameraOffset,
    int? cameraBinX,
    int? cameraBinY,
    int? filterPosition,
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
      focuserPosition: focuserPosition ?? this.focuserPosition,
      exposureTime: exposureTime ?? this.exposureTime,
      capturedAt: capturedAt ?? this.capturedAt,
    );
  }

  /// Convert to JSON map for database storage
  Map<String, dynamic> toJson() {
    return {
      'coolerTargetTemp': coolerTargetTemp,
      'cameraGain': cameraGain,
      'cameraOffset': cameraOffset,
      'cameraBinX': cameraBinX,
      'cameraBinY': cameraBinY,
      'filterPosition': filterPosition,
      'focuserPosition': focuserPosition,
      'exposureTime': exposureTime,
      'capturedAt': capturedAt.toIso8601String(),
    };
  }

  /// Create from JSON map (from database)
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

  /// Convert to JSON string for database storage
  String toJsonString() => jsonEncode(toJson());

  /// Create from JSON string (from database)
  factory EquipmentSnapshot.fromJsonString(String jsonStr) {
    final json = decodeJsonObjectString(
      jsonStr,
      context: 'imaging_sessions.equipment_snapshot',
    );
    return EquipmentSnapshot.fromJson(json);
  }

  /// Check if this snapshot has meaningful equipment data
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

// QuickStartContext - Full context for quick session resumption

/// Contains all the information needed to quickly resume a previous session.
/// This includes session details, target info, sequence progress, and equipment state.
class QuickStartContext {
  /// Database ID of the session
  final int sessionId;

  /// User-provided session name
  final String? sessionName;

  /// Equipment profile ID used in this session
  final int? profileId;

  /// Equipment profile name
  final String? profileName;

  /// Target ID being imaged
  final int? targetId;

  /// Target name (e.g., "Orion Nebula")
  final String? targetName;

  /// Target right ascension in decimal hours
  final double? targetRa;

  /// Target declination in decimal degrees
  final double? targetDec;

  /// Sequence ID being executed
  final int? sequenceId;

  /// Sequence name
  final String? sequenceName;

  /// Number of frames completed in the sequence
  final int completedFrames;

  /// Total frames planned in the sequence
  final int totalFrames;

  /// When the session was last active
  final DateTime lastSessionDate;

  /// Captured equipment state
  final EquipmentSnapshot? equipmentSnapshot;

  /// Total integration time accumulated in hours
  final double totalIntegrationHours;

  /// True only when the execution backend has a resumable checkpoint for this
  /// sequence. Historical session progress alone is not a checkpoint.
  final bool canResumeFromCheckpoint;

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
      totalFrames: matches
          ? math.max(totalFrames, checkpoint.completedExposures)
          : totalFrames,
      lastSessionDate: lastSessionDate,
      equipmentSnapshot: equipmentSnapshot,
      totalIntegrationHours: matches
          ? math.max(
              totalIntegrationHours,
              checkpoint.completedIntegrationSecs / 3600.0,
            )
          : totalIntegrationHours,
      canResumeFromCheckpoint: matches,
    );
  }

  /// Calculate the percentage of frames completed
  double get progressPercentage {
    if (totalFrames == 0) return 0.0;
    return (completedFrames / totalFrames * 100).clamp(0.0, 100.0);
  }

  /// Check if the session has meaningful progress
  bool get hasProgress => completedFrames > 0 || totalIntegrationHours > 0;

  /// Check if this context has target coordinates
  bool get hasTargetCoordinates => targetRa != null && targetDec != null;

  /// Check if this context has equipment snapshot
  bool get hasEquipmentSnapshot =>
      equipmentSnapshot != null && equipmentSnapshot!.hasEquipmentData;

  /// Get a display-friendly session description
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
      parts.add('$completedFrames/$totalFrames frames');
    }

    if (totalIntegrationHours > 0) {
      parts.add('${totalIntegrationHours.toStringAsFixed(1)}h');
    }

    return parts.join(' - ');
  }

  /// Get how long ago the session was active
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
