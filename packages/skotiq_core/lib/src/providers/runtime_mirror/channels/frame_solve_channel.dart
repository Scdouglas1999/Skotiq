import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/imaging_service.dart' show currentImageProvider;
import '../../current_frame_analysis_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

typedef FrameSolveOnScreen = ({String? path, FrameSolveVm? solve});

final _frameSolveOnScreenProvider = Provider<FrameSolveOnScreen>(
  (ref) => (
    path: ref.watch(currentImageProvider.select((i) => i?.filePath)),
    solve: ref.watch(currentFrameSolveProvider),
  ),
);

/// The host's background solve of the frame on its screen, which positions
/// the catalog overlay. A client showing the same frame takes it rather than
/// asking the host to solve the frame a second time.
class FrameSolveChannel extends RuntimeMirrorChannel<FrameSolveOnScreen> {
  const FrameSolveChannel();

  @override
  String get key => 'frameSolve';

  @override
  get source => _frameSolveOnScreenProvider;

  @override
  Map<String, dynamic>? encode(FrameSolveOnScreen value) {
    final path = value.path;
    final solve = value.solve;
    if (path == null || path.isEmpty || solve == null) return null;
    return {
      'path': path,
      'status': solve.status.name,
      'ra': finiteOrNull(solve.raDegrees),
      'dec': finiteOrNull(solve.decDegrees),
      'rotation': finiteOrNull(solve.rotationDeg),
      'scale': finiteOrNull(solve.pixelScaleArcsec),
      'message': solve.message,
      'saved': solve.fromSavedSolution,
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null || context.networkBackend == null) return;
    final path = jsonString(value['path']);
    if (path == null || path.isEmpty) return;
    final status = FrameSolveStatus.values
        .where((s) => s.name == value['status'])
        .firstOrNull;
    if (status == null) return;
    // Keyed by the host's capture instant here; adopted against this
    // window's copy of the frame, which has its own.
    final solve = FrameSolveVm(
      frameCapturedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      status: status,
      raDegrees: jsonDouble(value['ra']),
      decDegrees: jsonDouble(value['dec']),
      rotationDeg: jsonDouble(value['rotation']),
      pixelScaleArcsec: jsonDouble(value['scale']),
      message: jsonString(value['message']),
      fromSavedSolution: value['saved'] == true,
    );
    final host = context.read(hostFrameSolvesProvider);
    host.byPath[path] = solve;
    if (host.byPath.length > 12) {
      host.byPath.remove(host.byPath.keys.first);
    }
    context.read(frameAutoSolveProvider.notifier).adoptHostSolve(path, solve);
  }
}
