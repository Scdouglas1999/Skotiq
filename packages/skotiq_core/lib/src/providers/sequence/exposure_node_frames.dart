import '../../models/sequence/exposure_progress_vocabulary.dart';
import '../../models/sequence/instruction_progress_detail.dart';
import '../../models/sequence/sequence_models.dart' show NodeStatus;
import 'node_exposure_tally.dart';

/// An exposure step's frames, as every surface that counts them reads them.
class ExposureNodeFrames {
  const ExposureNodeFrames({
    required this.captured,
    required this.planned,
    this.inFlight = 0,
    int? named,
  }) : named = named ?? captured;

  /// Frames the step has captured in its current pass.
  final int captured;

  /// Frames the step plans for the pass, or null when nothing says.
  final int? planned;

  /// The 1-based frame exposing now, or 0 when none is.
  final int inFlight;

  /// The frame number the step's own report names: the frames captured, or
  /// the frame a "Frame n/m" line says is exposing.
  final int named;

  @override
  bool operator ==(Object other) =>
      other is ExposureNodeFrames &&
      other.captured == captured &&
      other.planned == planned &&
      other.inFlight == inFlight &&
      other.named == named;

  @override
  int get hashCode => Object.hash(captured, planned, inFlight, named);

  @override
  String toString() =>
      'ExposureNodeFrames($captured/$planned, inFlight $inFlight, '
      'named $named)';
}

/// The rules on which the surfaces that count frames still differ.
class ExposureFramesRules {
  const ExposureFramesRules({
    this.successMeansAll = false,
    this.statusWhenSilent = false,
  });

  /// A step whose status is success, or whose last line reports its final
  /// frame captured, has captured every planned frame.
  final bool successMeansAll;

  /// With no report at all, the status answers against the step's own count:
  /// success is every planned frame, a started step none; a pending step has
  /// no frames to show.
  final bool statusWhenSilent;
}

/// The frames an exposure step has captured, planned and is exposing, from
/// what the run reported for it, in one order: the per-step [tally], then
/// the typed Exposure report [typed], then the step's progress [line], then
/// its [status]. The typed report's `frame` is the number of frames
/// captured: the native executor sends it after each frame is saved. [plannedFallback] is the step's own count, used when the
/// report names no total. Null when nothing reports any frames.
ExposureNodeFrames? exposureNodeFrames({
  NodeExposureTally? tally,
  InstructionProgressDetail? typed,
  String? line,
  NodeStatus? status,
  int? plannedFallback,
  ExposureFramesRules rules = const ExposureFramesRules(),
}) {
  final running = status == NodeStatus.running;
  int exposingAfter(int captured, int planned) =>
      running && captured < planned ? captured + 1 : 0;

  if (tally != null) {
    final captured = tally.captured.clamp(0, tally.planned);
    return ExposureNodeFrames(
      captured: captured,
      planned: tally.planned,
      inFlight: exposingAfter(captured, tally.planned),
    );
  }

  if (typed is ExposureInstructionProgressDetail && typed.total > 0) {
    final total = typed.total;
    if (rules.successMeansAll && status == NodeStatus.success) {
      return ExposureNodeFrames(captured: total, planned: total);
    }
    final captured = typed.frame.clamp(0, total);
    return ExposureNodeFrames(
      captured: captured,
      planned: total,
      inFlight: exposingAfter(captured, total),
    );
  }

  final parsed = line == null ? null : parseExposureProgressDetail(line);
  if (parsed != null) {
    final planned = parsed.total > 0 ? parsed.total : plannedFallback;
    final landed = parsed.frameCompleted;
    final finished =
        rules.successMeansAll &&
        planned != null &&
        (status == NodeStatus.success || (landed && parsed.frame >= planned));
    if (finished) {
      return ExposureNodeFrames(captured: planned, planned: planned);
    }
    final captured = landed ? parsed.frame : parsed.frame - 1;
    return ExposureNodeFrames(
      captured: planned == null
          ? (captured < 0 ? 0 : captured)
          : captured.clamp(0, planned),
      planned: planned,
      inFlight: landed ? 0 : parsed.frame,
      named: parsed.frame,
    );
  }

  final planned = plannedFallback;
  if (!rules.statusWhenSilent || planned == null) return null;
  return switch (status) {
    NodeStatus.success => ExposureNodeFrames(
      captured: planned,
      planned: planned,
    ),
    NodeStatus.running ||
    NodeStatus.failure ||
    NodeStatus.skipped ||
    NodeStatus.cancelled => ExposureNodeFrames(captured: 0, planned: planned),
    NodeStatus.pending || null => null,
  };
}
