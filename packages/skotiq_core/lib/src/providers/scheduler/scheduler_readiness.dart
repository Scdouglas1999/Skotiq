part of '../scheduler_provider.dart';

/// Host-authoritative state consumed by the scheduler tab on a remote client.
/// Readiness is computed on the scheduler host and sent to remote clients.
/// Scheduler sequences center each target, so a usable plate solver is required.
final schedulerStartReadinessProvider = Provider<SchedulerStartReadiness>((
  ref,
) {
  final report = ref.watch(readinessReportProvider);
  final issues = <SchedulerReadinessIssue>[];
  final critical = report.itemFor(ReadinessItemId.criticalDevices);
  if (critical?.level == ReadinessLevel.blocked) {
    issues.add(
      const SchedulerReadinessIssue(
        id: SchedulerReadinessIssueId.camera,
        severity: SchedulerReadinessSeverity.blocker,
        title: 'Camera and mount',
        detail: 'The camera or mount is not connected.',
      ),
    );
  }
  final location = report.itemFor(ReadinessItemId.location);
  if (location?.level == ReadinessLevel.blocked) {
    issues.add(
      const SchedulerReadinessIssue(
        id: SchedulerReadinessIssueId.location,
        severity: SchedulerReadinessSeverity.blocker,
        title: 'Observing location',
        detail: 'Set the site location before starting unattended.',
      ),
    );
  }
  final output = report.itemFor(ReadinessItemId.outputPath);
  if (output?.level == ReadinessLevel.blocked) {
    issues.add(
      const SchedulerReadinessIssue(
        id: SchedulerReadinessIssueId.outputPath,
        severity: SchedulerReadinessSeverity.blocker,
        title: 'Capture output path',
        detail: 'Choose a writable capture directory.',
      ),
    );
  }
  final accessories = report.itemFor(ReadinessItemId.profileDevices);
  if (accessories?.level != null &&
      accessories!.level != ReadinessLevel.ready) {
    issues.add(
      const SchedulerReadinessIssue(
        id: SchedulerReadinessIssueId.guider,
        severity: SchedulerReadinessSeverity.warning,
        title: 'Assigned accessories',
        detail: 'One or more configured accessories are unavailable.',
      ),
    );
  }
  final solver = report.itemFor(ReadinessItemId.plateSolver);
  if (solver?.level != ReadinessLevel.ready) {
    issues.add(
      const SchedulerReadinessIssue(
        id: SchedulerReadinessIssueId.solver,
        severity: SchedulerReadinessSeverity.blocker,
        title: 'Plate solver',
        detail: 'Configure a working plate solver before unattended centering.',
      ),
    );
  }

  final weather = ref.watch(weatherSafetyProvider);
  if (!weather.monitoringEnabled) {
    issues.add(
      const SchedulerReadinessIssue(
        id: SchedulerReadinessIssueId.weather,
        severity: SchedulerReadinessSeverity.warning,
        title: 'Weather monitoring disabled',
        detail: 'Start requires confirmation without weather protection.',
      ),
    );
  } else if (!weather.isSafe) {
    issues.add(
      SchedulerReadinessIssue(
        id: SchedulerReadinessIssueId.weather,
        severity: SchedulerReadinessSeverity.blocker,
        title: 'Weather safety',
        detail: weather.failModeWarning ?? 'Weather is unsafe or unknown.',
      ),
    );
  }

  final guider = ref.watch(guiderStateProvider);
  if (guider.deviceId != null &&
      guider.connectionState != DeviceConnectionState.connected) {
    issues.add(
      const SchedulerReadinessIssue(
        id: SchedulerReadinessIssueId.guider,
        severity: SchedulerReadinessSeverity.warning,
        title: 'Guider',
        detail: 'The configured guider is not connected.',
      ),
    );
  }

  final disk = ref.watch(captureDirDiskSpaceProvider);
  disk.when(
    loading: () => issues.add(
      const SchedulerReadinessIssue(
        id: SchedulerReadinessIssueId.disk,
        severity: SchedulerReadinessSeverity.warning,
        title: 'Disk space',
        detail: 'Waiting for the capture volume check.',
      ),
    ),
    error: (_, __) => issues.add(
      const SchedulerReadinessIssue(
        id: SchedulerReadinessIssueId.disk,
        severity: SchedulerReadinessSeverity.blocker,
        title: 'Disk space',
        detail: 'The capture volume could not be checked.',
      ),
    ),
    data: (snapshot) {
      if (snapshot == null) {
        issues.add(
          const SchedulerReadinessIssue(
            id: SchedulerReadinessIssueId.disk,
            severity: SchedulerReadinessSeverity.blocker,
            title: 'Disk space',
            detail: 'The capture volume has no readable free-space snapshot.',
          ),
        );
      } else if (snapshot.freeBytes < kSafetyMarginBytes) {
        issues.add(
          const SchedulerReadinessIssue(
            id: SchedulerReadinessIssueId.disk,
            severity: SchedulerReadinessSeverity.blocker,
            title: 'Disk space',
            detail: 'Less than 2 GB remains on the capture volume.',
          ),
        );
      } else if (snapshot.freeBytes < 8 * 1024 * 1024 * 1024) {
        issues.add(
          const SchedulerReadinessIssue(
            id: SchedulerReadinessIssueId.disk,
            severity: SchedulerReadinessSeverity.warning,
            title: 'Disk space',
            detail: 'Less than 8 GB remains on the capture volume.',
          ),
        );
      }
    },
  );

  final settings = ref.watch(appSettingsProvider).valueOrNull;
  if (settings == null || !settings.parkBeforeDawn) {
    issues.add(
      const SchedulerReadinessIssue(
        id: SchedulerReadinessIssueId.dawn,
        severity: SchedulerReadinessSeverity.warning,
        title: 'Dawn policy',
        detail: 'Park before dawn is not confirmed enabled.',
      ),
    );
  }
  return SchedulerStartReadiness(
    issues: issues,
    available: true,
    solverRequired: true,
  );
});
