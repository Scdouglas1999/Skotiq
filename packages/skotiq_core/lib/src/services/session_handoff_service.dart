import 'dart:convert';

import '../database/daos/images_dao.dart';
import '../database/daos/sessions_dao.dart';
import '../database/daos/targets_dao.dart';
import '../database/database.dart' show CapturedImage, ImagingSession, Target;
import '../models/sequence/sequence_models.dart';
import 'quick_start_service.dart';

/// Thrown when carry-over cannot be determined at all, as opposed to being
/// determined to be nothing.
///
/// A service built with neither DAOs nor host snapshots has no history to
/// read; returning an empty list would tell the caller the operator banked no
/// integration on this target, which restarts a multi-night budget at zero.
class SessionCarryOverUnavailable implements Exception {
  final String message;

  const SessionCarryOverUnavailable(this.message);

  @override
  String toString() => 'SessionCarryOverUnavailable: $message';
}

/// One unfinished previous-session carry-over for a target.
///
/// "Last night you got 4h12m on M31 toward an 8h budget. Resume?"
///
/// The values reflect data that already lives in the database: the most
/// recent session for the target plus the per-filter integration totals
/// from `captured_images`. We do not persist any handoff state of our
/// own — the carry-over is recomputed every time the user opens the
/// sequence so it stays in sync with whatever the operator deleted or
/// regraded in the gallery.
class SessionCarryOver {
  /// Foreign key into `targets`.
  final int targetId;

  /// Display name of the target (matches `TargetHeaderNode.targetName`
  /// when the sequence references the same target row).
  final String targetName;

  /// Most recent session id that captured frames for this target.
  final int? previousSessionId;

  /// Wall-clock start time of the previous session.
  final DateTime? previousSessionStartedAt;

  /// Accepted-frame count from the previous session for this target.
  final int previousAcceptedFrames;

  /// Accepted-frame integration time (seconds) carried over from
  /// previous sessions for this target.
  final double previousIntegrationSecs;

  /// Cumulative accepted-frame integration time across **all** prior
  /// sessions for this target — used by the multi-night campaign
  /// resume path so the budget tracker knows the full history, not
  /// just the most recent night.
  final double campaignIntegrationSecs;

  /// Total integration budget the operator has configured on the
  /// `TargetHeaderNode` for this run, in seconds. Null when the
  /// sequence has no budget set — the resume dialog still surfaces the
  /// carry-over so the user can decide manually.
  final double? budgetSecs;

  /// Per-filter integration totals carried over, keyed by lowercased
  /// filter name. The UI renders one row per filter so users with
  /// LRGB campaigns can see how much of each channel they have already
  /// banked.
  final Map<String, double> perFilterIntegrationSecs;

  const SessionCarryOver({
    required this.targetId,
    required this.targetName,
    required this.previousSessionId,
    required this.previousSessionStartedAt,
    required this.previousAcceptedFrames,
    required this.previousIntegrationSecs,
    required this.campaignIntegrationSecs,
    required this.budgetSecs,
    required this.perFilterIntegrationSecs,
  });

  /// Convenience: remaining seconds against the configured budget.
  /// `null` when no budget is configured.
  double? get remainingSecs {
    if (budgetSecs == null || budgetSecs! <= 0) return null;
    final r = budgetSecs! - campaignIntegrationSecs;
    return r < 0 ? 0 : r;
  }

  /// True when the previous session captured at least one frame for
  /// this target. Drives the "Resume / Restart / Continue New" prompt.
  bool get hasCarryOver => previousAcceptedFrames > 0;

  Map<String, dynamic> toJson() => {
    'targetId': targetId,
    'targetName': targetName,
    'previousSessionId': previousSessionId,
    'previousSessionStartedAt': previousSessionStartedAt?.toIso8601String(),
    'previousAcceptedFrames': previousAcceptedFrames,
    'previousIntegrationSecs': previousIntegrationSecs,
    'campaignIntegrationSecs': campaignIntegrationSecs,
    'budgetSecs': budgetSecs,
    'perFilterIntegrationSecs': perFilterIntegrationSecs,
  };
}

/// Three-way operator choice for the carry-over banner.
enum SessionHandoffDecision {
  /// Reuse carry-over: the IntegrationBudget tracker treats the
  /// pre-existing frames as already-counted toward the budget.
  resume,

  /// Ignore carry-over: capture goes fresh from zero this session.
  restart,

  /// Acknowledge the carry-over but neither reuse nor wipe it. The
  /// sequence proceeds with whatever budget it has, leaving the
  /// historical frames where they are. Used for "I'm intentionally
  /// imaging the same target without expecting it to count."
  continueNew,
}

class SessionHandoffBundle {
  final String version;
  final DateTime exportedAt;
  final int sessionId;
  final String? sessionName;
  final String? targetName;
  final double? targetRa;
  final double? targetDec;
  final int completedFrames;
  final int totalFrames;
  final double totalIntegrationHours;
  final EquipmentSnapshot? equipmentSnapshot;
  final String? sequenceName;

  const SessionHandoffBundle({
    required this.version,
    required this.exportedAt,
    required this.sessionId,
    required this.sessionName,
    required this.targetName,
    required this.targetRa,
    required this.targetDec,
    required this.completedFrames,
    required this.totalFrames,
    required this.totalIntegrationHours,
    required this.equipmentSnapshot,
    required this.sequenceName,
  });

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'exportedAt': exportedAt.toIso8601String(),
      'sessionId': sessionId,
      'sessionName': sessionName,
      'targetName': targetName,
      'targetRa': targetRa,
      'targetDec': targetDec,
      'completedFrames': completedFrames,
      'totalFrames': totalFrames,
      'totalIntegrationHours': totalIntegrationHours,
      'equipmentSnapshot': equipmentSnapshot?.toJson(),
      'sequenceName': sequenceName,
    };
  }

  factory SessionHandoffBundle.fromJson(Map<String, dynamic> json) {
    return SessionHandoffBundle(
      version: json['version'] as String? ?? '1',
      exportedAt: DateTime.parse(json['exportedAt'] as String),
      sessionId: json['sessionId'] as int,
      sessionName: json['sessionName'] as String?,
      targetName: json['targetName'] as String?,
      targetRa: (json['targetRa'] as num?)?.toDouble(),
      targetDec: (json['targetDec'] as num?)?.toDouble(),
      completedFrames: json['completedFrames'] as int? ?? 0,
      totalFrames: json['totalFrames'] as int? ?? 0,
      totalIntegrationHours:
          (json['totalIntegrationHours'] as num?)?.toDouble() ?? 0,
      equipmentSnapshot: json['equipmentSnapshot'] is Map<String, dynamic>
          ? EquipmentSnapshot.fromJson(
              json['equipmentSnapshot'] as Map<String, dynamic>,
            )
          : null,
      sequenceName: json['sequenceName'] as String?,
    );
  }

  String encode() => jsonEncode(toJson());

  factory SessionHandoffBundle.decode(String jsonText) {
    return SessionHandoffBundle.fromJson(
      jsonDecode(jsonText) as Map<String, dynamic>,
    );
  }
}

/// Serializes the current session state so another device can resume it.
///
/// Also detects multi-night carry-over (was the same target
/// imaged on a prior session?) so the pre-flight dialog can offer a
/// Resume / Restart / Continue choice.
class SessionHandoffService {
  final SessionsDao? _sessionsDao;
  final ImagesDao? _imagesDao;
  final TargetsDao? _targetsDao;

  const SessionHandoffService({
    SessionsDao? sessionsDao,
    ImagesDao? imagesDao,
    TargetsDao? targetsDao,
  }) : _sessionsDao = sessionsDao,
       _imagesDao = imagesDao,
       _targetsDao = targetsDao;

  /// Build a list of [SessionCarryOver] entries for the
  /// targets referenced by the supplied sequence.
  ///
  /// Targets are matched by **catalog id first, then case-insensitive
  /// name**. The sequence model stores only the display name on
  /// `TargetHeaderNode`, so when an operator has a Drift target row
  /// named "M31 - Andromeda" but the sequence node says "M31", we
  /// fall back to the catalog id (`M31`) before giving up.
  ///
  /// The lookback window is `recentSessionWithinDays` days. The
  /// rationale: a 3-month-old session for the same target is not the
  /// "previous night" — it's a different campaign sortie and should
  /// surface only via the campaign rollup, not the resume banner.
  ///
  /// Returns an empty list when the sequence has no target headers or no
  /// matching prior-session frames exist.
  ///
  /// Throws [SessionCarryOverUnavailable] when neither DAOs nor the
  /// [libraryTargets] / [capturedImages] / [sessions] snapshot trio were
  /// supplied: with no history to read, "none found" would be a claim this
  /// service cannot make.
  Future<List<SessionCarryOver>> detectCarryOver({
    required Sequence sequence,
    List<Target>? libraryTargets,
    List<CapturedImage>? capturedImages,
    List<ImagingSession>? sessions,
    DateTime? now,
    int recentSessionWithinDays = 14,
  }) async {
    final useHostSnapshot =
        libraryTargets != null && capturedImages != null && sessions != null;
    if (!useHostSnapshot &&
        (_sessionsDao == null || _imagesDao == null || _targetsDao == null)) {
      throw const SessionCarryOverUnavailable(
        'No session/image/target source: pass the DAOs or a full '
        'libraryTargets + capturedImages + sessions snapshot.',
      );
    }

    final headers = sequence.targetHeaders;
    if (headers.isEmpty) return const <SessionCarryOver>[];

    final allTargets = libraryTargets ?? await _targetsDao!.getAllTargets();
    final byCatalog = <String, Target>{};
    final byName = <String, Target>{};
    for (final t in allTargets) {
      final catalog = t.catalogId;
      if (catalog != null && catalog.isNotEmpty) {
        byCatalog[catalog.toLowerCase()] = t;
      }
      byName[t.name.toLowerCase()] = t;
    }

    final nowOrDefault = now ?? DateTime.now();
    final cutoff = nowOrDefault.subtract(
      Duration(days: recentSessionWithinDays.clamp(1, 365)),
    );

    final out = <SessionCarryOver>[];
    for (final header in headers) {
      final lookup = header.targetName.toLowerCase();
      final target = byCatalog[lookup] ?? byName[lookup];
      if (target == null) continue;

      final sessionsForTarget = useHostSnapshot
          ? sessions
                .where((s) => s.targetId == target.id)
                .toList(growable: false)
          : await _sessionsDao!.getSessionsForTarget(target.id);
      // Find the most recent session, regardless of cutoff — the
      // campaign integration still counts pre-cutoff frames; we only
      // gate the "carry-over banner" on whether the most recent
      // session falls inside the recency window.
      ImagingSession? mostRecent;
      for (final s in sessionsForTarget) {
        if (mostRecent == null || s.startTime.isAfter(mostRecent.startTime)) {
          mostRecent = s;
        }
      }

      final images = useHostSnapshot
          ? capturedImages
                .where((i) => i.targetId == target.id)
                .toList(growable: false)
          : await _imagesDao!.getImagesForTarget(target.id);
      final lightFrames = images
          .where((i) => i.frameType == 'light' && i.isAccepted)
          .toList(growable: false);

      // Per-filter integration across ALL prior sessions.
      final perFilter = <String, double>{};
      var campaignSecs = 0.0;
      for (final f in lightFrames) {
        final key = (f.filter == null || f.filter!.isEmpty)
            ? 'unfiltered'
            : f.filter!.toLowerCase();
        perFilter[key] = (perFilter[key] ?? 0.0) + f.exposureDuration;
        campaignSecs += f.exposureDuration;
      }

      // Previous-session-only counts.
      var prevFrames = 0;
      var prevSecs = 0.0;
      if (mostRecent != null) {
        for (final f in lightFrames) {
          if (f.sessionId == mostRecent.id) {
            prevFrames++;
            prevSecs += f.exposureDuration;
          }
        }
      }

      // Skip targets that have no prior frames at all — there is no
      // carry-over to offer in that case.
      if (campaignSecs <= 0 && prevFrames <= 0) continue;

      // Surface the banner only when the most recent session falls
      // within the lookback window. Older campaigns still feed the
      // campaign rollup but don't fire the resume prompt.
      final recent = mostRecent != null && mostRecent.startTime.isAfter(cutoff);
      if (!recent) continue;

      out.add(
        SessionCarryOver(
          targetId: target.id,
          targetName: target.name,
          previousSessionId: mostRecent.id,
          previousSessionStartedAt: mostRecent.startTime,
          previousAcceptedFrames: prevFrames,
          previousIntegrationSecs: prevSecs,
          campaignIntegrationSecs: campaignSecs,
          budgetSecs: (header.integrationBudget?.totalSecs ?? 0) > 0
              ? header.integrationBudget!.totalSecs
              : null,
          perFilterIntegrationSecs: perFilter,
        ),
      );
    }

    return out;
  }

  SessionHandoffBundle exportBundle(QuickStartContext context) {
    return SessionHandoffBundle(
      version: '1',
      exportedAt: DateTime.now(),
      sessionId: context.sessionId,
      sessionName: context.sessionName,
      targetName: context.targetName,
      targetRa: context.targetRa,
      targetDec: context.targetDec,
      completedFrames: context.completedFrames,
      totalFrames: context.totalFrames,
      totalIntegrationHours: context.totalIntegrationHours,
      equipmentSnapshot: context.equipmentSnapshot,
      sequenceName: context.sequenceName,
    );
  }

  String describe(SessionHandoffBundle bundle) {
    final buffer = StringBuffer();
    buffer.write(bundle.sessionName ?? 'Session ${bundle.sessionId}');
    if (bundle.targetName != null) {
      buffer.write(' on ${bundle.targetName}');
    }
    if (bundle.totalFrames > 0) {
      buffer.write(' (${bundle.completedFrames}/${bundle.totalFrames} frames)');
    }
    if (bundle.totalIntegrationHours > 0) {
      buffer.write(
        ' ${bundle.totalIntegrationHours.toStringAsFixed(1)}h integrated',
      );
    }
    return buffer.toString();
  }
}
