import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../errors/error_text.dart';
import '../guiding_provider.dart' show phd2ControllerProvider;
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
  if (!guider.isGuiding && !guider.isCalibrating) return;
  try {
    await ref.read(phd2ControllerProvider).stopGuiding();
  } catch (e) {
    throw GuidingDidNotStopException(e);
  }
}
