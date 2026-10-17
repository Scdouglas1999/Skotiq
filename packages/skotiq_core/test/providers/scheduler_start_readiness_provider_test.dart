import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

ReadinessReport _report({
  ReadinessLevel critical = ReadinessLevel.ready,
  ReadinessLevel profileDevices = ReadinessLevel.ready,
  ReadinessLevel location = ReadinessLevel.ready,
  ReadinessLevel output = ReadinessLevel.ready,
  ReadinessLevel solver = ReadinessLevel.ready,
}) => ReadinessReport(
  items: [
    ReadinessItem(
      id: ReadinessItemId.criticalDevices,
      title: 'Camera and mount',
      detail: 'test',
      level: critical,
    ),
    ReadinessItem(
      id: ReadinessItemId.profileDevices,
      title: 'Assigned equipment',
      detail: 'test',
      level: profileDevices,
    ),
    ReadinessItem(
      id: ReadinessItemId.location,
      title: 'Location',
      detail: 'test',
      level: location,
    ),
    ReadinessItem(
      id: ReadinessItemId.outputPath,
      title: 'Output',
      detail: 'test',
      level: output,
    ),
    ReadinessItem(
      id: ReadinessItemId.plateSolver,
      title: 'Solver',
      detail: 'test',
      level: solver,
    ),
  ],
);

const _settings = AppSettingsState(
  latitude: 40,
  longitude: -75,
  imageOutputPath: '/captures',
  parkBeforeDawn: true,
);

const _safeWeather = WeatherSafetyState(
  status: WeatherSafetyStatus.safe,
  actions: WeatherSafetyActions.safe,
  currentAlertLevel: AlertLevel.clear,
  monitoringEnabled: true,
);

class _WeatherNotifier extends WeatherSafetyNotifier {
  _WeatherNotifier(super.ref, WeatherSafetyState value) {
    state = value;
  }
}

class _GuiderNotifier extends GuiderStateNotifier {
  _GuiderNotifier(super.ref, GuiderState value) {
    state = value;
  }
}

class _SettingsNotifier extends AppSettingsNotifier {
  _SettingsNotifier(this.value);
  final AppSettingsState value;

  @override
  Future<AppSettingsState> build() async => value;
}

DiskSpaceInfo _defaultDisk() => DiskSpaceInfo(
  path: '/captures',
  totalBytes: 20 * 1024 * 1024 * 1024,
  freeBytes: 12 * 1024 * 1024 * 1024,
  sampledAt: DateTime.utc(2026, 8, 1),
);

ProviderContainer _container({
  ReadinessReport report = const ReadinessReport(items: []),
  WeatherSafetyState weather = _safeWeather,
  DiskSpaceInfo? disk,
  bool diskUnknown = false,
  GuiderState guider = const GuiderState(),
  AppSettingsState settings = _settings,
}) {
  return ProviderContainer(
    overrides: [
      readinessReportProvider.overrideWithValue(report),
      weatherSafetyProvider.overrideWith(
        (ref) => _WeatherNotifier(ref, weather),
      ),
      guiderStateProvider.overrideWith((ref) => _GuiderNotifier(ref, guider)),
      appSettingsProvider.overrideWith(() => _SettingsNotifier(settings)),
      captureDirDiskSpaceProvider.overrideWith((ref) async* {
        yield diskUnknown ? null : (disk ?? _defaultDisk());
      }),
    ],
  );
}

void main() {
  test(
    'generic readiness maps camera, mount, location, output, and solver',
    () {
      final container = _container(
        report: _report(
          critical: ReadinessLevel.blocked,
          location: ReadinessLevel.blocked,
          output: ReadinessLevel.blocked,
          solver: ReadinessLevel.blocked,
        ),
      );
      addTearDown(container.dispose);

      final readiness = container.read(schedulerStartReadinessProvider);
      expect(readiness.blocked, isTrue);
      expect(
        readiness.blockers.map((issue) => issue.id),
        containsAll([
          SchedulerReadinessIssueId.camera,
          SchedulerReadinessIssueId.location,
          SchedulerReadinessIssueId.outputPath,
          SchedulerReadinessIssueId.solver,
        ]),
      );
      expect(
        readiness.blockers
            .singleWhere(
              (issue) => issue.id == SchedulerReadinessIssueId.camera,
            )
            .title,
        'Camera and mount',
      );
      expect(readiness.solverRequired, isTrue);
    },
  );

  test('accessory, weather, guider, and dawn states are surfaced', () {
    final container = _container(
      report: _report(profileDevices: ReadinessLevel.caution),
      weather: const WeatherSafetyState(
        status: WeatherSafetyStatus.unsafe,
        actions: WeatherSafetyActions(
          shouldPause: true,
          reason: 'Rain expected',
        ),
        currentAlertLevel: AlertLevel.warning,
        monitoringEnabled: true,
        failModeWarning: 'Rain expected',
      ),
      guider: const GuiderState(
        deviceId: 'guider-1',
        connectionState: DeviceConnectionState.disconnected,
      ),
      settings: _settings.copyWith(parkBeforeDawn: false),
    );
    addTearDown(container.dispose);

    final readiness = container.read(schedulerStartReadinessProvider);
    expect(
      readiness.blockers.map((issue) => issue.id),
      contains(SchedulerReadinessIssueId.weather),
    );
    expect(
      readiness.warnings.map((issue) => issue.id),
      containsAll([
        SchedulerReadinessIssueId.guider,
        SchedulerReadinessIssueId.dawn,
      ]),
    );
    expect(
      readiness.warnings.singleWhere(
        (issue) => issue.title == 'Assigned accessories',
        orElse: () => throw StateError('missing accessory warning'),
      ),
      isNotNull,
    );
  });

  test(
    'weather disabled is amber while disk states remain deterministic',
    () async {
      final disabledWeather = _container(
        weather: const WeatherSafetyState(
          status: WeatherSafetyStatus.safe,
          actions: WeatherSafetyActions.safe,
          currentAlertLevel: AlertLevel.clear,
          monitoringEnabled: false,
        ),
      );
      addTearDown(disabledWeather.dispose);
      final disabled = disabledWeather.read(schedulerStartReadinessProvider);
      expect(
        disabled.warnings.map((issue) => issue.id),
        contains(SchedulerReadinessIssueId.weather),
      );

      final lowDisk = _container(
        disk: DiskSpaceInfo(
          path: '/captures',
          totalBytes: 10 * 1024 * 1024 * 1024,
          freeBytes: 1024 * 1024 * 1024,
          sampledAt: DateTime.utc(2026, 8, 1),
        ),
      );
      addTearDown(lowDisk.dispose);
      await lowDisk.read(captureDirDiskSpaceProvider.future);
      final low = lowDisk.read(schedulerStartReadinessProvider);
      expect(
        low.blockers
            .singleWhere((issue) => issue.id == SchedulerReadinessIssueId.disk)
            .detail,
        contains('Less than 2 GB'),
      );

      final unknownDisk = _container(diskUnknown: true);
      addTearDown(unknownDisk.dispose);
      await unknownDisk.read(captureDirDiskSpaceProvider.future);
      final unknown = unknownDisk.read(schedulerStartReadinessProvider);
      expect(
        unknown.blockers
            .singleWhere((issue) => issue.id == SchedulerReadinessIssueId.disk)
            .detail,
        contains('no readable free-space snapshot'),
      );
    },
  );
}
