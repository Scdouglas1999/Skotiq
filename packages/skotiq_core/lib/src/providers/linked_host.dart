import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import 'host_role.dart';

// What only a linked client has: the halves of the imaging host that have no
// counterpart in this process's own database or drivers. Each is null where
// the imaging host is this process.
//
// A card, banner or action that exists only for a linked host watches its
// half and builds nothing on null. A class that does the host's work itself
// where the host is this process is handed its half by its provider.
// Data both sides keep is a `hostRoleProvider`, never a null test on a half.

final linkedHostLinkProvider = linkedOnlyProvider((host) => host.link);

final linkedHostCalibrationToolsProvider = linkedOnlyProvider(
  (host) => host.calibrationTools,
);

final linkedHostImagingRecordsProvider = linkedOnlyProvider(
  (host) => host.imagingRecords,
);

final linkedHostDevicesProvider = linkedOnlyProvider((host) => host.devices);

final linkedHostFilesProvider = linkedOnlyProvider((host) => host.files);

final linkedHostFocusModelsProvider = linkedOnlyProvider(
  (host) => host.focusModels,
);

final linkedHostProfilesProvider = linkedOnlyProvider((host) => host.profiles);

final linkedHostBackupsProvider = linkedOnlyProvider((host) => host.backups);

final linkedHostCatalogsProvider = linkedOnlyProvider((host) => host.catalogs);

final linkedHostCloudSyncProvider = linkedOnlyProvider(
  (host) => host.cloudSync,
);

final linkedHostLogsProvider = linkedOnlyProvider((host) => host.logs);

final linkedHostNotificationsProvider = linkedOnlyProvider(
  (host) => host.notifications,
);

final linkedHostJobsProvider = linkedOnlyProvider((host) => host.jobs);

final linkedHostUpdatesProvider = linkedOnlyProvider((host) => host.updates);

final linkedHostTransientsProvider = linkedOnlyProvider(
  (host) => host.transients,
);

final linkedHostControlProvider = linkedOnlyProvider((host) => host.control);

final linkedHostNightProvider = linkedOnlyProvider((host) => host.night);

final linkedHostLiveStackProvider = linkedOnlyProvider(
  (host) => host.liveStack,
);

final linkedHostPlanningProvider = linkedOnlyProvider((host) => host.planning);

final linkedHostPostSessionProvider = linkedOnlyProvider(
  (host) => host.postSession,
);

final linkedHostSequencesProvider = linkedOnlyProvider(
  (host) => host.sequences,
);

final linkedHostPointingProvider = linkedOnlyProvider((host) => host.pointing);

final linkedHostRigSettingsProvider = linkedOnlyProvider(
  (host) => host.rigSettings,
);

final linkedHostRunStateProvider = linkedOnlyProvider((host) => host.runState);

final linkedHostCalibrationFramesProvider = linkedOnlyProvider(
  (host) => host.calibrationFrames,
);

final linkedHostWeatherProvider = linkedOnlyProvider((host) => host.weather);

/// Everything the host announces to this client, as a stream opened when
/// called.
final linkedHostEventsProvider = linkedOnlyProvider(
  (host) =>
      () => host.events,
);

/// Names the linked host among the hosts this client has linked to, for
/// preferences kept per host; null where the imaging host is this process.
final linkedHostIdentityProvider = Provider<String?>(
  (ref) => ref.watch(linkedHostLinkProvider)?.identity,
);
