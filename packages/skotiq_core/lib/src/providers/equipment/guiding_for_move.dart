import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../errors/error_text.dart';
import '../../models/equipment/equipment_models.dart';
import '../../models/phd2_models.dart';
import '../async_scope.dart';
import '../guiding_provider.dart'
    show phd2ControllerProvider, phd2StateFromAppState;
import 'guider_state_provider.dart';

/// Guiding could not be stopped before a mount move, so the move must not go.
class GuidingDidNotStopException implements Exception {
  const GuidingDidNotStopException(this.cause);

  final Object cause;

  @override
  String toString() =>
      'Guiding did not stop, so the mount was not moved: '
      '${userFacingError(cause)}';
}

/// Stops guiding before a mount move this app starts (a GoTo, a park, a home,
/// a centering run): a guider left running chases the move and loses its
/// star. Guiding is not restarted afterwards; guiding started outside a run is
/// the operator's to restart. Throws [GuidingDidNotStopException] when
/// guiding did not stop, and the mount must then stay where it is.
Future<void> stopGuidingForMove(Ref ref) async {
  final guider = ref.read(guiderStateProvider);
  if (guider.connectionState != DeviceConnectionState.connected &&
      !guider.isGuiding &&
      !guider.isCalibrating) {
    return;
  }
  final scope = ref.backendScope();
  final controller = ref.read(phd2ControllerProvider);
  try {
    if (!guider.isGuiding && !guider.isCalibrating) {
      // Lost lock and paused sessions can resume issuing corrections without
      // a new Start. The live status distinguishes them from an idle guider.
      final status = await scope.value.guiderGetStatus();
      scope.ensureCurrent('checking guiding before moving the mount');
      if (!status.connected) return;
      final state = phd2StateFromAppState(status.state) ?? Phd2State.unknown;
      if (!state.inGuideSession) return;
    }
    await controller.stopGuiding();
    scope.ensureCurrent('stopping guiding before moving the mount');
  } catch (e) {
    throw GuidingDidNotStopException(e);
  }
}
