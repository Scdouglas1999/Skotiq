import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import 'linked_host.dart';
import '../services/post_session_seam.dart';

/// Provider for the production [PostSessionSeam]. Tests override this with a
/// fake so the orchestration services run end-to-end without native code.
///
/// The active backend is passed so [PostSessionSeam.integrationProgress] can
/// filter its event stream for the native `IntegrationProgress` events.
final postSessionSeamProvider = Provider<PostSessionSeam>((ref) {
  return BridgePostSessionSeam(
    backend: ref.watch(backendProvider),
    host: ref.watch(linkedHostPostSessionProvider),
  );
});
