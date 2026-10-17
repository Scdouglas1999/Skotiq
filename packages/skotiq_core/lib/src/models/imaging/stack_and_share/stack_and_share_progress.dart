part of '../stack_and_share_models.dart';

/// Lifecycle phases of a Stack-and-Share run, in execution order.
enum StackAndSharePhase {
  /// No run is in progress.
  idle,

  /// Choosing which light frames to include.
  selectingLights,

  /// Applying dark/flat/bias calibration to selected lights.
  calibrating,

  /// Aligning and integrating frames into the live stack.
  stacking,

  /// Applying the auto-stretch to the integrated result.
  stretching,

  /// Rendering and writing the share artifacts to disk.
  exporting,

  /// The run finished successfully.
  complete,

  /// The run failed; inspect the surfaced error for the cause.
  error,
}

/// Live progress for an in-flight Stack-and-Share run.
class StackAndShareProgress {
  /// The current lifecycle phase.
  final StackAndSharePhase phase;

  /// Total number of frames the run intends to process.
  final int framesTotal;

  /// Number of frames processed so far (accepted into, or rejected from, the
  /// stack — i.e. frames the engine has finished examining).
  final int framesProcessed;

  /// Number of frames rejected during processing (alignment failure, below
  /// quality threshold, or not accepted).
  final int framesRejected;

  /// The file currently being processed, if any.
  final String? currentFile;

  const StackAndShareProgress({
    this.phase = StackAndSharePhase.idle,
    this.framesTotal = 0,
    this.framesProcessed = 0,
    this.framesRejected = 0,
    this.currentFile,
  });

  /// Fraction of the run completed, in the range `[0.0, 1.0]`.
  ///
  /// Returns `0.0` when [framesTotal] is zero (rather than NaN) so progress UI
  /// renders a sane empty bar. The result is clamped to `[0.0, 1.0]` to guard
  /// against [framesProcessed] transiently exceeding [framesTotal].
  double get fraction {
    if (framesTotal <= 0) return 0.0;
    final raw = framesProcessed / framesTotal;
    if (raw < 0.0) return 0.0;
    if (raw > 1.0) return 1.0;
    return raw;
  }

  StackAndShareProgress copyWith({
    StackAndSharePhase? phase,
    int? framesTotal,
    int? framesProcessed,
    int? framesRejected,
    String? currentFile,
  }) {
    return StackAndShareProgress(
      phase: phase ?? this.phase,
      framesTotal: framesTotal ?? this.framesTotal,
      framesProcessed: framesProcessed ?? this.framesProcessed,
      framesRejected: framesRejected ?? this.framesRejected,
      currentFile: currentFile ?? this.currentFile,
    );
  }

  /// Like [copyWith] but allows explicitly clearing [currentFile] back to null
  /// (e.g. when transitioning to a phase with no active file).
  StackAndShareProgress clearCurrentFile() {
    return StackAndShareProgress(
      phase: phase,
      framesTotal: framesTotal,
      framesProcessed: framesProcessed,
      framesRejected: framesRejected,
      currentFile: null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StackAndShareProgress &&
          runtimeType == other.runtimeType &&
          phase == other.phase &&
          framesTotal == other.framesTotal &&
          framesProcessed == other.framesProcessed &&
          framesRejected == other.framesRejected &&
          currentFile == other.currentFile;

  @override
  int get hashCode => Object.hash(
    phase,
    framesTotal,
    framesProcessed,
    framesRejected,
    currentFile,
  );
}

/// A single light frame considered for a Stack-and-Share run.
class StackedFrameSelection {
  /// Database id of the captured image (`captured_images.id`).
  final int imageId;

  /// Absolute path to the frame on disk.
  final String filePath;

  /// Filter the frame was captured through, if known (e.g. `'L'`, `'Ha'`).
  final String? filter;

  /// Per-frame quality score, if computed. Higher is better.
  final double? qualityScore;

  /// Whether this frame is the alignment reference for the stack.
  final bool isReference;

  /// This frame's own exposure length in seconds.
  ///
  /// Carried per-frame because the engine can refuse individual subs: the
  /// integration time a finished stack reports has to be the time that is
  /// actually IN it, which the selection-wide total cannot express once any of
  /// the selected frames are rejected.
  final double exposureSecs;

  const StackedFrameSelection({
    required this.imageId,
    required this.filePath,
    this.filter,
    this.qualityScore,
    this.isReference = false,
    this.exposureSecs = 0,
  });

  StackedFrameSelection copyWith({
    int? imageId,
    String? filePath,
    String? filter,
    double? qualityScore,
    bool? isReference,
    double? exposureSecs,
  }) {
    return StackedFrameSelection(
      imageId: imageId ?? this.imageId,
      filePath: filePath ?? this.filePath,
      filter: filter ?? this.filter,
      qualityScore: qualityScore ?? this.qualityScore,
      isReference: isReference ?? this.isReference,
      exposureSecs: exposureSecs ?? this.exposureSecs,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StackedFrameSelection &&
          runtimeType == other.runtimeType &&
          imageId == other.imageId &&
          filePath == other.filePath &&
          filter == other.filter &&
          qualityScore == other.qualityScore &&
          isReference == other.isReference &&
          exposureSecs == other.exposureSecs;

  @override
  int get hashCode => Object.hash(
    imageId,
    filePath,
    filter,
    qualityScore,
    isReference,
    exposureSecs,
  );
}

/// Summary of which frames were selected for, and which were excluded from, a
/// Stack-and-Share run, with derived per-filter and integration totals.
class StackSelectionSummary {
  /// Frames included in the stack.
  final List<StackedFrameSelection> selected;

  /// Frames excluded from the stack (below quality, wrong filter, rejected).
  final List<StackedFrameSelection> excluded;

  /// Path of the alignment reference frame, if one was chosen.
  final String? referencePath;

  /// Count of selected frames per filter (filter name → frame count).
  final Map<String, int> perFilterCounts;

  /// Total integration time of the selected frames, in seconds.
  final double totalIntegrationSecs;

  /// Name of the target being stacked, if known.
  final String? targetName;

  const StackSelectionSummary({
    this.selected = const [],
    this.excluded = const [],
    this.referencePath,
    this.perFilterCounts = const {},
    this.totalIntegrationSecs = 0,
    this.targetName,
  });

  /// Number of frames selected for the stack.
  int get selectedCount => selected.length;

  /// Number of frames excluded from the stack.
  int get excludedCount => excluded.length;

  StackSelectionSummary copyWith({
    List<StackedFrameSelection>? selected,
    List<StackedFrameSelection>? excluded,
    String? referencePath,
    Map<String, int>? perFilterCounts,
    double? totalIntegrationSecs,
    String? targetName,
  }) {
    return StackSelectionSummary(
      selected: selected ?? this.selected,
      excluded: excluded ?? this.excluded,
      referencePath: referencePath ?? this.referencePath,
      perFilterCounts: perFilterCounts ?? this.perFilterCounts,
      totalIntegrationSecs: totalIntegrationSecs ?? this.totalIntegrationSecs,
      targetName: targetName ?? this.targetName,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StackSelectionSummary &&
          runtimeType == other.runtimeType &&
          _listEquals(selected, other.selected) &&
          _listEquals(excluded, other.excluded) &&
          referencePath == other.referencePath &&
          _mapEquals(perFilterCounts, other.perFilterCounts) &&
          totalIntegrationSecs == other.totalIntegrationSecs &&
          targetName == other.targetName;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(selected),
    Object.hashAll(excluded),
    referencePath,
    Object.hashAll(
      perFilterCounts.entries.map((e) => Object.hash(e.key, e.value)).toList()
        ..sort(),
    ),
    totalIntegrationSecs,
    targetName,
  );
}
