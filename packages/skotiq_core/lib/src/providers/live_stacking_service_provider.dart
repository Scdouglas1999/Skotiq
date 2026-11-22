import 'host_role.dart';
import '../services/live_stacking_service.dart';

/// The live stacker of the imaging host: this process's native one, or the
/// linked host's.
final liveStackingServiceProvider = hostRoleProvider<LiveStackingService>(
  here: LiveStackingService.new,
  linked: (ref, host) => LinkedLiveStackingService(ref, host.liveStack),
);
