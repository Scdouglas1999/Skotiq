import 'dart:convert';

import '../../../models/plate_solver.dart';
import '../../plate_solver_provider.dart';
import '../runtime_mirror_channel.dart';

/// The host's plate solvers: what it detected on its disk and the solver its
/// operator chose, which the Plate Solving settings page and the "solver not
/// set up" banners read.
///
/// Host to client only. A rescan or a save on a client runs on the host
/// (`/api/plate-solver/detect` and `/config`), whose handlers refresh the
/// host's own providers, so every client hears of it here.
class PlateSolverSetupChannel extends RuntimeMirrorChannel<PlateSolverSetup> {
  const PlateSolverSetupChannel();

  static const channelKey = 'plateSolverSetup';

  @override
  String get key => channelKey;

  @override
  get source => plateSolverSetupShownProvider;

  @override
  Map<String, dynamic>? encode(PlateSolverSetup value) {
    final detection = value.detection;
    final preference = value.preference;
    if (detection == null && preference == null) return null;
    return {
      if (detection != null) 'detection': detection.toJson(),
      if (preference != null) 'preference': preference.toJson(),
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    final told = context.read(hostPlateSolverSetupProvider.notifier);
    if (value == null) {
      told.state = null;
      return;
    }
    final detection = value['detection'];
    final preference = value['preference'];
    final next = (
      detection: detection is Map
          ? PlateSolverDetection.fromJson(Map<String, dynamic>.from(detection))
          : null,
      preference: preference is Map
          ? PlateSolverPreference.fromJson(
              Map<String, dynamic>.from(preference),
            )
          : null,
    );
    // The host's broadcast of this client's own rescan or save repeats what
    // the client already shows; writing it again would reload the page.
    final current = told.state;
    if (current != null && jsonEncode(encode(current)) == jsonEncode(value)) {
      return;
    }
    told.state = next;
  }
}
