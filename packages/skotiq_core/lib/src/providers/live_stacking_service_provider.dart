import 'host_role.dart';
import 'logging_service_provider.dart';
import '../services/live_stacking_service.dart';

/// The live stacker of the imaging host: this process's native one, or the
/// linked host's.
final liveStackingServiceProvider = hostRoleProvider<LiveStackingService>(
  here: (ref) => LiveStackingService(ref.read(loggingServiceProvider)),
  linked: (ref, host) => LinkedLiveStackingService(
    ref.read(loggingServiceProvider),
    host.liveStack,
  ),
);
