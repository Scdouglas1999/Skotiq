import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/night_end/night_end_run.dart';
import '../../services/night_end/night_end_runner.dart';
import '../../services/darkroom_build_jobs.dart';
import '../calibration_backlog_service_provider.dart';
import '../darkroom_autopilot/guided_build_delivery_provider.dart';
import '../darkroom_build_jobs_provider.dart';
import '../darkroom_build_service_provider.dart';
import '../darkroom_state_store_provider.dart';
import '../database_provider.dart';
import '../logging_service_provider.dart';
import '../notification_service_provider.dart';

/// The saved night-end runs, newest first.
class NightEndRuns extends Notifier<List<NightEndRun>> {
  @override
  List<NightEndRun> build() => const [];

  void _set(List<NightEndRun> runs) => state = List.unmodifiable(runs);
}

final nightEndRunsProvider = NotifierProvider<NightEndRuns, List<NightEndRun>>(
  NightEndRuns.new,
);

final nightEndRunnerProvider = Provider<NightEndRunner>((ref) {
  final runner = NightEndRunner(
    jobs: () => ref.read(darkroomBuildJobsProvider.notifier),
    currentBuild: () => ref.read(darkroomBuildJobsProvider),
    recentBuilds: () => ref.read(darkroomRecentBuildsProvider),
    runs: () => ref.read(nightEndRunsProvider),
    setRuns: (runs) => ref.read(nightEndRunsProvider.notifier)._set(runs),
    stateStore: () => ref.read(darkroomStateStoreProvider),
    log: () => ref.read(loggingServiceProvider),
    settingsDao: () => ref.read(settingsDaoProvider),
    imagesDao: () => ref.read(imagesDaoProvider),
    database: () => ref.read(databaseProvider),
    prepareFlats: (lights) =>
        ref.read(calibrationBacklogProvider.notifier).prepareForLights(lights),
    buildService: () => ref.read(darkroomBuildServiceProvider),
    delivery: () => ref.read(guidedBuildDeliveryProvider),
    notifications: () => ref.read(notificationServiceProvider),
  );
  ref.onDispose(runner.dispose);
  return runner;
});
