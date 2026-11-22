import '../../../models/imaging/plate_solve_wire.dart';
import '../../../services/plate_solve_service.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// The host's plate-solve state: whether a solve is running and the last
/// result, which the Tonight Solve tab, the frame stage and the recent-solves
/// list read.
///
/// Host to client only. A solve a client starts already runs on the host
/// (`POST /api/plate-solve` goes through the host's [PlateSolveService]), so the
/// host's own state records it without a report.
class PlateSolveChannel extends RuntimeMirrorChannel<PlateSolveState> {
  const PlateSolveChannel();

  @override
  String get key => 'plateSolve';

  @override
  get source => plateSolveStateProvider;

  @override
  Map<String, dynamic>? encode(PlateSolveState value) {
    final result = value.lastResult;
    if (!value.isSolving && result == null) return null;
    return {
      'isSolving': value.isSolving,
      if (value.currentImage != null) 'currentImage': value.currentImage,
      if (result != null) 'result': plateSolveResultToJson(result),
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    final controller = context.read(plateSolveStateProvider.notifier);
    if (value == null) {
      controller.state = const PlateSolveState();
      return;
    }
    final current = controller.state;
    final raw = value['result'];
    final decoded = raw is Map
        ? plateSolveResultFromJson(Map<String, dynamic>.from(raw))
        : null;
    // The same outcome keeps the object already held, so listeners that key on
    // identity (the recent-solves list) do not record one solve twice when the
    // client's own result and the host's broadcast of it both arrive.
    final lastResult =
        decoded != null &&
            current.lastResult != null &&
            samePlateSolveOutcome(current.lastResult!, decoded)
        ? current.lastResult
        : decoded ?? current.lastResult;
    controller.state = PlateSolveState(
      isSolving: value['isSolving'] == true,
      lastResult: lastResult,
      currentImage: jsonString(value['currentImage']) ?? current.currentImage,
    );
  }
}
