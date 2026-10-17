import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/images_dao.dart';
import '../database/daos/sessions_dao.dart';
import '../database/daos/targets_dao.dart';
import '../database/database.dart';
import '../models/imaging/stack_and_share_models.dart';
import '../providers/database_provider.dart';

/// Thrown by [StackLightSelector] when a selection run finds **zero** light
/// frames that satisfy the [StackAndShareConfig] gates (frame-type, accepted,
/// and quality threshold).
///
/// Surfaced by the UI rather than producing an empty stack: a Stack-and-Share
/// run with nothing to stack is a user-visible problem (wrong session selected,
/// quality threshold too aggressive, all frames rejected), not a no-op.
class NoLightsToStackException implements Exception {
  /// Human-readable scope of the failed selection, e.g.
  /// `'session 42'` or `'target 7'`.
  final String scope;

  /// Total number of frames examined before gating (all frame types).
  final int framesExamined;

  /// Number of frames that were light frames but were dropped by a gate
  /// (not accepted, or below the quality threshold).
  final int lightsExcluded;

  const NoLightsToStackException({
    required this.scope,
    required this.framesExamined,
    required this.lightsExcluded,
  });

  @override
  String toString() {
    final buf = StringBuffer(
      'NoLightsToStackException: no light frames qualify for stacking in '
      '$scope.',
    );
    buf.write(
      ' Examined $framesExamined frame${framesExamined == 1 ? '' : 's'}',
    );
    if (lightsExcluded > 0) {
      buf.write(
        '; $lightsExcluded light frame${lightsExcluded == 1 ? '' : 's'} '
        '${lightsExcluded == 1 ? 'was' : 'were'} excluded by the accepted / '
        'quality gates — relax the quality threshold or re-accept frames.',
      );
    } else {
      buf.write(' but none were light frames.');
    }
    return buf.toString();
  }
}

/// Reason a candidate light frame was excluded from the stack. Surfaced in
/// [StackedFrameSelection]-adjacent excluded lists so the UI can explain to the
/// operator *why* a frame was dropped (rather than silently omitting it).
enum StackExclusionReason {
  /// The frame's [CapturedImage.qualityScore] is below
  /// [StackAndShareConfig.minQualityScore].
  lowQuality,

  /// The frame was marked not-accepted (`isAccepted == false`) and
  /// [StackAndShareConfig.rejectUnaccepted] is true.
  rejected,
}

extension StackExclusionReasonLabel on StackExclusionReason {
  /// Short, user-facing label for the exclusion reason.
  String get label {
    switch (this) {
      case StackExclusionReason.lowQuality:
        return 'low quality';
      case StackExclusionReason.rejected:
        return 'rejected';
    }
  }
}

/// Pure selection logic for the **Stack-and-Share Loop** (component C5).
///
/// Decides *which* captured light frames feed a live-stack run and *which* one
/// is the alignment reference — it does not stack, calibrate, or touch the
/// renderer. It reads existing DAO queries ([ImagesDao.getImagesForSession] /
/// [ImagesDao.getImagesForTarget]), applies the [StackAndShareConfig] gates,
/// and returns a [StackSelectionSummary] the downstream stacking pipeline (and
/// the UI) consume.
///
/// Selection rules (applied in order):
///  1. Keep only `frameType == 'light'` frames.
///  2. If [StackAndShareConfig.rejectUnaccepted], drop `isAccepted == false`.
///  3. Drop frames whose `qualityScore` is non-null and below
///     [StackAndShareConfig.minQualityScore]. (A null score is admitted — the
///     grader simply didn't run for that frame; we never silently invent a
///     score.)
///  4. Group survivors by `filter` (null → `'(none)'`) for per-filter counts.
///  5. Pick the alignment **reference**: the highest-`qualityScore` survivor,
///     tie-broken by lowest `hfr`, then most-recent `capturedAt`. The reference
///     defines the registration coordinate system for the whole stack.
///  6. Sum `exposureDuration` across survivors for total integration seconds.
///
/// Throws [NoLightsToStackException] when no light frame survives — there is no
/// "empty stack" success path.
class StackLightSelector {
  final ImagesDao _imagesDao;
  final SessionsDao _sessionsDao;
  final TargetsDao _targetsDao;

  StackLightSelector({
    required ImagesDao imagesDao,
    required SessionsDao sessionsDao,
    required TargetsDao targetsDao,
  }) : _imagesDao = imagesDao,
       _sessionsDao = sessionsDao,
       _targetsDao = targetsDao;

  /// Filter-bucket name used for frames captured without a filter recorded.
  static const String noFilterBucket = '(none)';

  /// Select the light frames for the given imaging [sessionId].
  ///
  /// Resolves the target name (for the share card / metadata) via the session's
  /// `targetId` through [TargetsDao]; leaves it null when the session has no
  /// target or the target row is missing.
  Future<StackSelectionSummary> selectForSession({
    required int sessionId,
    required StackAndShareConfig config,
  }) async {
    final session = await _sessionsDao.getSessionById(sessionId);
    if (session == null) {
      throw StateError('Imaging session $sessionId not found');
    }
    final frames = await _imagesDao.getImagesForSession(sessionId);
    final targetName = await _resolveTargetName(session.targetId);
    return _select(
      frames: frames,
      config: config,
      scope: 'session $sessionId',
      targetName: targetName,
    );
  }

  /// Select the light frames for the given [targetId], across every session
  /// that imaged it. The target name resolves directly from [targetId].
  Future<StackSelectionSummary> selectForTarget({
    required int targetId,
    required StackAndShareConfig config,
  }) async {
    final target = await _targetsDao.getTargetById(targetId);
    if (target == null) {
      throw StateError('Target $targetId not found');
    }
    final frames = await _imagesDao.getImagesForTarget(targetId);
    return _select(
      frames: frames,
      config: config,
      scope: 'target $targetId',
      targetName: target.name,
    );
  }

  Future<String?> _resolveTargetName(int? targetId) async {
    if (targetId == null) return null;
    final target = await _targetsDao.getTargetById(targetId);
    return target?.name;
  }

  /// Core, side-effect-free selection over an already-loaded frame list.
  StackSelectionSummary _select({
    required List<CapturedImage> frames,
    required StackAndShareConfig config,
    required String scope,
    required String? targetName,
  }) {
    final selected = <StackedFrameSelection>[];
    final excluded = <StackedFrameSelection>[];
    final perFilterCounts = <String, int>{};
    var totalIntegrationSecs = 0.0;
    var lightsExcluded = 0;

    // Track the running best reference candidate among accepted survivors.
    CapturedImage? referenceRow;

    for (final frame in frames) {
      if (frame.frameType != 'light') {
        continue;
      }

      final filterBucket = _filterBucket(frame.filter);

      // Gate 1: accepted.
      if (config.rejectUnaccepted && !frame.isAccepted) {
        lightsExcluded++;
        excluded.add(_toSelection(frame, isReference: false));
        continue;
      }

      // Gate 2: quality threshold. A null score means "not graded" — admit it
      // rather than fabricate a score; the threshold only rejects measured,
      // genuinely-low scores.
      final score = frame.qualityScore;
      if (score != null && score < config.minQualityScore) {
        lightsExcluded++;
        excluded.add(_toSelection(frame, isReference: false));
        continue;
      }

      // Survivor.
      selected.add(_toSelection(frame, isReference: false));
      perFilterCounts[filterBucket] = (perFilterCounts[filterBucket] ?? 0) + 1;
      totalIntegrationSecs += frame.exposureDuration;

      if (referenceRow == null ||
          _isBetterReference(candidate: frame, current: referenceRow)) {
        referenceRow = frame;
      }
    }

    if (selected.isEmpty) {
      throw NoLightsToStackException(
        scope: scope,
        framesExamined: frames.length,
        lightsExcluded: lightsExcluded,
      );
    }

    // Stamp the chosen reference onto the matching selection entry. The
    // reference is guaranteed non-null here because `selected` is non-empty and
    // every survivor is a reference candidate.
    final referenceId = referenceRow!.id;
    String? referencePath;
    for (var i = 0; i < selected.length; i++) {
      if (selected[i].imageId == referenceId) {
        selected[i] = selected[i].copyWith(isReference: true);
        referencePath = selected[i].filePath;
        break;
      }
    }

    return StackSelectionSummary(
      selected: List.unmodifiable(selected),
      excluded: List.unmodifiable(excluded),
      referencePath: referencePath,
      perFilterCounts: Map.unmodifiable(perFilterCounts),
      totalIntegrationSecs: totalIntegrationSecs,
      targetName: targetName,
    );
  }

  StackedFrameSelection _toSelection(
    CapturedImage frame, {
    required bool isReference,
  }) {
    return StackedFrameSelection(
      imageId: frame.id,
      filePath: frame.filePath,
      filter: frame.filter,
      qualityScore: frame.qualityScore,
      isReference: isReference,
      exposureSecs: frame.exposureDuration,
    );
  }

  String _filterBucket(String? filter) {
    if (filter == null) return noFilterBucket;
    final trimmed = filter.trim();
    return trimmed.isEmpty ? noFilterBucket : trimmed;
  }

  /// True when [candidate] is a strictly better alignment reference than
  /// [current]. Ranking, in priority order:
  ///  1. Higher `qualityScore` (a graded frame beats an ungraded one).
  ///  2. Lower `hfr` (tighter stars → better registration template).
  ///  3. More-recent `capturedAt` (freshest focus/conditions).
  ///
  /// A null `qualityScore` ranks below any non-null score; a null `hfr` ranks
  /// below any non-null hfr. Frames with neither metric fall through to the
  /// timestamp tie-break, so a usable reference is always chosen.
  bool _isBetterReference({
    required CapturedImage candidate,
    required CapturedImage current,
  }) {
    final cmpQuality = _compareNullableDesc(
      candidate.qualityScore,
      current.qualityScore,
    );
    if (cmpQuality != 0) return cmpQuality > 0;

    // Lower HFR is better → invert the ascending comparison.
    final cmpHfr = _compareNullableAsc(candidate.hfr, current.hfr);
    if (cmpHfr != 0) return cmpHfr > 0;

    return candidate.capturedAt.isAfter(current.capturedAt);
  }

  /// Compares two nullable values where **higher is better**. Returns a
  /// positive number when [a] outranks [b], negative when [b] outranks [a],
  /// and 0 when neither is preferable. A non-null value always outranks null.
  int _compareNullableDesc(double? a, double? b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    return a.compareTo(b);
  }

  /// Compares two nullable values where **lower is better**. Returns a positive
  /// number when [a] outranks [b] (i.e. is smaller), negative when [b] outranks
  /// [a], and 0 when neither is preferable. A non-null value always outranks
  /// null (an unmeasured HFR is the worst case for a registration template).
  int _compareNullableAsc(double? a, double? b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    // Smaller is better → flip the sign so smaller yields a positive result.
    return b.compareTo(a);
  }

  /// Derive *why* a given light [frame] would be excluded under [config], or
  /// null if it would be selected. Pure and stateless — the selector keeps no
  /// per-frame reason state of its own, so the UI labels each entry of
  /// [StackSelectionSummary.excluded] by re-deriving the reason here against the
  /// same config it passed to [selectForSession] / [selectForTarget].
  ///
  /// Returns null for non-light frames too (they are never candidates, so
  /// "excluded" doesn't apply). The check mirrors the gate order used by
  /// [_select] exactly: accepted first, then quality.
  static StackExclusionReason? exclusionReasonFor(
    CapturedImage frame,
    StackAndShareConfig config,
  ) {
    if (frame.frameType != 'light') return null;
    if (config.rejectUnaccepted && !frame.isAccepted) {
      return StackExclusionReason.rejected;
    }
    final score = frame.qualityScore;
    if (score != null && score < config.minQualityScore) {
      return StackExclusionReason.lowQuality;
    }
    return null;
  }
}

/// Provider for the [StackLightSelector]. Reads the image / session / target
/// DAOs from the shared database providers so it transparently follows the same
/// Drift instance the rest of the app uses.
final stackLightSelectorProvider = Provider<StackLightSelector>((ref) {
  return StackLightSelector(
    imagesDao: ref.watch(imagesDaoProvider),
    sessionsDao: ref.watch(sessionsDaoProvider),
    targetsDao: ref.watch(targetsDaoProvider),
  );
});
