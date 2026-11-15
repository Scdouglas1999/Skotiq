import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend_provider.dart';
import '../../models/backend/device_status.dart';

/// Bumped when the host says its list of kept captures changed
/// (`CameraRetainedCapturesChanged`), so the list is read again.
final retainedCapturesRevisionProvider = StateProvider<int>((ref) => 0);

/// The captures cameras are keeping because their download failed. They
/// never stop an exposure; each can be read off its camera on request.
final retainedCapturesProvider = FutureProvider<List<RetainedCapture>>((
  ref,
) async {
  ref.watch(retainedCapturesRevisionProvider);
  return ref.watch(deviceBackendProvider).cameraRetainedCaptures();
});
