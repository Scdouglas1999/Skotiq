import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/session/before_you_start_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/conditions_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/equipment_summary_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/guide_series_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/night_log_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_events_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_format.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_stats_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart'
    hide EquipmentStatus, TwilightTimes;
import 'package:skotiq_core/skotiq_core_events.dart' as sk_events;

import 'session_test_support.dart';

SkotiqEvent _guideStep(DateTime at, Map<String, dynamic> data) => SkotiqEvent(
      timestamp: at.millisecondsSinceEpoch,
      severity: EventSeverity.info,
      category: EventCategory.guiding,
      eventType: 'GuideStep',
      data: data,
    );

/// A site near Boston, for the dawn rule.
const AppSettingsState _boston = AppSettingsState(
  latitude: 42.36,
  longitude: -71.06,
  imageOutputPath: '/data',
);

/// The rig of the Ready board: camera, mount and PHD2 connected, PHD2 idle,
/// no weather device, no forecast, solver installed, plenty of disk.
List<Override> _readyRig({
  AppSettingsState settings = _boston,
  Phd2State phd2 = Phd2State.stopped,
}) =>
    <Override>[
      cameraStateProvider.overrideWith(
        (ref) => FixedCamera(
          ref,
          const CameraStateSnapshot(
            connectionState: DeviceConnectionState.connected,
            deviceName: 'ZWO ASI1600MM Pro',
            temperature: -7.4,
            targetTemp: -10,
            isCooling: true,
          ),
        ),
      ),
      mountStateProvider.overrideWith(
        (ref) => FixedMount(
          ref,
          const MountState(
            connectionState: DeviceConnectionState.connected,
            deviceName: 'EQ6-R',
            sideOfPier: 'West',
            isParked: false,
          ),
        ),
      ),
      guiderStateProvider.overrideWith(
        (ref) => FixedGuider(
          ref,
          const GuiderState(
            connectionState: DeviceConnectionState.connected,
            deviceName: 'PHD2',
          ),
        ),
      ),
      phd2StateProvider.overrideWith((ref) => phd2),
      assignedProfileDeviceSlotsProvider.overrideWithValue(
        const <ProfileDeviceSlot>[
          ProfileDeviceSlot.camera,
          ProfileDeviceSlot.mount,
          ProfileDeviceSlot.guider,
        ],
      ),
      appSettingsProvider.overrideWith(() => FixedSettings(settings)),
      nightSolverStatusProvider.overrideWithValue(
        const NightSolverStatus(ready: true, name: 'ASTAP'),
      ),
      nightDiskProjectionProvider.overrideWithValue(null),
      nightCaptureFreeBytesProvider.overrideWithValue(639 * (1 << 30)),
      nightForecastCloudProvider.overrideWithValue(null),
      nightSafetyReadingProvider.overrideWithValue(
        const NightSafetyReading(monitoring: true, safe: true),
      ),
      clockProvider.overrideWithValue(const SystemClock()),
      nightSessionNowProvider.overrideWithValue(DateTime(2026, 10, 19, 18, 36)),
    ];

Future<List<ChecklistItemVm>> _checklist(SessionHarness h) async {
  await h.settle(appSettingsProvider);
  return h.read(nightBeforeYouStartProvider);
}

ChecklistItemVm _item(List<ChecklistItemVm> items, ChecklistItemId id) =>
    items.firstWhere((item) => item.id == id);

void main() {
  group('conditions', () {
    test('no weather device and no forecast: no source, nothing shown',
        () async {
      final h = await sessionHarness(overrides: _readyRig());
      final vm = h.read(nightConditionsProvider);
      expect(vm.source, ConditionsSource.none);
      expect(vm.metrics, isEmpty);
    });

    test('forecast cloud cover alone is labeled as a forecast', () async {
      final h = await sessionHarness(
        overrides: <Override>[
          ..._readyRig(),
          nightForecastCloudProvider.overrideWithValue(12),
        ],
      );
      final vm = h.read(nightConditionsProvider);
      expect(vm.source, ConditionsSource.forecast);
      expect(vm.metrics.single.label.key, 'nightSessionCloudsForecast');
      expect(vm.metrics.single.value, '12%');
    });

    test('a weather device reports only what it measures', () async {
      final h = await sessionHarness(
        overrides: <Override>[
          ..._readyRig(),
          nightForecastCloudProvider.overrideWithValue(80),
          weatherStateProvider.overrideWith(
            (ref) => FixedWeather(
              ref,
              const WeatherState(
                connectionState: DeviceConnectionState.connected,
                humidity: 71,
                dewPoint: 4.1,
                windSpeed: 6 / 3.6,
                temperature: 12,
              ),
            ),
          ),
        ],
      );
      final vm = h.read(nightConditionsProvider);
      expect(vm.source, ConditionsSource.device);
      expect(vm.safe, isTrue);
      expect(
        vm.metrics.map((m) => '${m.label.key} ${m.value}'),
        <String>[
          'nightSessionHumidity 71%',
          'nightSessionDewPoint 4.1 °C',
          'nightSessionWind 6 km/h',
          'nightSessionAmbient 12.0 °C',
        ],
      );
    });
  });

  group('guide series', () {
    test('pixels, and a sample missing an axis is dropped', () async {
      final h = await sessionHarness();
      final keep = h.container.listen(nightGuideSamplesProvider, (_, __) {});
      addTearDown(keep.close);
      final t0 = DateTime(2026, 10, 19, 23, 40);
      h.backend
        ..emitEvent(
          _guideStep(t0, <String, dynamic>{
            'RADistanceRaw': 0.3,
            'DECDistanceRaw': -0.4,
          }),
        )
        // PHD2 sent no Dec distance: not a perfect Dec step.
        ..emitEvent(
          _guideStep(t0.add(const Duration(seconds: 2)), <String, dynamic>{
            'RADistanceRaw': 0.5,
          }),
        )
        ..emitEvent(
          _guideStep(t0.add(const Duration(seconds: 4)), <String, dynamic>{
            'raPx': -0.3,
            'decPx': 0.4,
          }),
        );
      await Future<void>.delayed(Duration.zero);

      final vm = h.read(nightGuideSeriesProvider);
      final ra = vm.lines.firstWhere((l) => l.id == NightSeriesId.guideRa);
      final dec = vm.lines.firstWhere((l) => l.id == NightSeriesId.guideDec);
      expect(ra.points.map((p) => p.y), <double>[0.3, -0.3]);
      expect(dec.points.map((p) => p.y), <double>[-0.4, 0.4]);
      expect(dec.points.every((p) => p.y != 0), isTrue);
      expect(
          vm.legend.every((m) =>
              m.value!.endsWith(' px') ||
              m.label.key == 'nightSessionGuideSnr'),
          isTrue);
      final total =
          vm.legend.firstWhere((m) => m.label.key == 'nightSessionGuideTotal');
      expect(total.value, '0.50 px');
      // No PHD2 frame reported yet: no SNR, rather than SNR 0.
      expect(
        vm.legend.map((m) => m.label.key),
        isNot(contains('nightSessionGuideSnr')),
      );
    });

    test('with the guider\'s pixel scale the chart reads in arcseconds',
        () async {
      final h = await sessionHarness(overrides: [
        guiderStateProvider.overrideWith(
          (ref) => FixedGuider(
            ref,
            const GuiderState(
              connectionState: DeviceConnectionState.connected,
              deviceName: 'PHD2',
              pixelScaleArcsecPerPixel: 2.0,
            ),
          ),
        ),
      ]);
      final keep = h.container.listen(nightGuideSamplesProvider, (_, __) {});
      addTearDown(keep.close);
      final t0 = DateTime(2026, 10, 19, 23, 40);
      h.backend
        ..emitEvent(
          _guideStep(t0, <String, dynamic>{
            'RADistanceRaw': 0.3,
            'DECDistanceRaw': -0.4,
          }),
        )
        ..emitEvent(
          _guideStep(t0.add(const Duration(seconds: 2)), <String, dynamic>{
            'RADistanceRaw': -0.3,
            'DECDistanceRaw': 0.4,
          }),
        );
      await Future<void>.delayed(Duration.zero);

      final vm = h.read(nightGuideSeriesProvider);
      final ra = vm.lines.firstWhere((l) => l.id == NightSeriesId.guideRa);
      expect(ra.points.map((p) => p.y), <double>[0.6, -0.6]);
      final total =
          vm.legend.firstWhere((m) => m.label.key == 'nightSessionGuideTotal');
      expect(total.value, '1.00″');
      expect(vm.legend.any((m) => m.value!.contains('px')), isFalse);
    });

    test('a zero or missing scale is unknown: pixels', () {
      expect(nightGuideDistance(0.5, null), '0.50 px');
      final h = ProviderContainer(overrides: [
        guiderStateProvider.overrideWith(
          (ref) => FixedGuider(
            ref,
            const GuiderState(pixelScaleArcsecPerPixel: 0),
          ),
        ),
      ]);
      addTearDown(h.dispose);
      expect(h.read(nightGuideScaleProvider), isNull);
    });

    test('dither marks land on the guiding chart', () async {
      final h = await sessionHarness();
      final keepSamples =
          h.container.listen(nightGuideSamplesProvider, (_, __) {});
      final keepEvents =
          h.container.listen(nightSessionEventsProvider, (_, __) {});
      addTearDown(keepSamples.close);
      addTearDown(keepEvents.close);
      final t0 = DateTime(2026, 10, 19, 23, 40);
      h.backend
        ..emitEvent(
          _guideStep(t0, <String, dynamic>{
            'RADistanceRaw': 0.1,
            'DECDistanceRaw': 0.1,
          }),
        )
        ..emitEvent(
          SkotiqEvent(
            timestamp:
                t0.add(const Duration(seconds: 3)).millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.guiding,
            eventType: 'DitherStarted',
            data: const <String, dynamic>{'pixels': 1.5},
          ),
        )
        ..emitEvent(
          _guideStep(t0.add(const Duration(seconds: 6)), <String, dynamic>{
            'RADistanceRaw': 0.9,
            'DECDistanceRaw': -0.8,
          }),
        );
      await Future<void>.delayed(Duration.zero);

      final vm = h.read(nightGuideSeriesProvider);
      expect(vm.markers.single.kind, SeriesMarkerKind.dither);
      expect(vm.markers.single.t, t0.add(const Duration(seconds: 3)));
    });

    test('nothing guided yet: empty lines, no legend', () async {
      final h = await sessionHarness();
      final vm = h.read(nightGuideSeriesProvider);
      expect(vm.isEmpty, isTrue);
      expect(vm.legend, isEmpty);
    });
  });

  group('before you start', () {
    test('PHD2 connected but not looping needs a look, with Loop', () async {
      final h = await sessionHarness(overrides: _readyRig());
      final items = await _checklist(h);
      final guider = _item(items, ChecklistItemId.guider);
      expect(guider.state, ChecklistItemState.attention);
      expect(guider.detail!.key, 'nightSessionCheckGuiderIdle');
      expect(guider.detail!.params['name'], 'PHD2');
      expect(guider.actionLabel!.key, 'nightSessionActionLoop');
      // Loop happens in place, not on another screen.
      expect(guider.route, isNull);
    });

    test('a looping guider is fine', () async {
      final h = await sessionHarness(
        overrides: _readyRig(phd2: Phd2State.looping),
      );
      final items = await _checklist(h);
      expect(_item(items, ChecklistItemId.guider).state, ChecklistItemState.ok);
    });

    test('no weather source needs a look', () async {
      final h = await sessionHarness(overrides: _readyRig());
      final items = await _checklist(h);
      final weather = _item(items, ChecklistItemId.weather);
      expect(weather.state, ChecklistItemState.attention);
      expect(weather.detail!.key, 'nightSessionCheckWeatherNone');
      expect(weather.actionLabel!.key, 'nightSessionActionAdd');
      expect(weather.route, '/settings?section=weather-safety');
    });

    test('the board order, and the rest of the rig is ready', () async {
      final h = await sessionHarness(overrides: _readyRig());
      final items = await _checklist(h);
      expect(items.map((i) => i.id), <ChecklistItemId>[
        ChecklistItemId.camera,
        ChecklistItemId.mount,
        ChecklistItemId.guider,
        ChecklistItemId.solver,
        ChecklistItemId.disk,
        ChecklistItemId.weather,
        ChecklistItemId.dawn,
      ]);
      final camera = _item(items, ChecklistItemId.camera);
      expect(camera.state, ChecklistItemState.ok);
      expect(camera.detail!.key, 'nightSessionCheckCameraCooling');
      expect(camera.detail!.params, <String, String>{
        'temp': '−7.4',
        'target': '−10',
      });
      expect(
        _item(items, ChecklistItemId.mount).detail!.key,
        'nightSessionCheckMountIdle',
      );
      expect(
        _item(items, ChecklistItemId.disk).detail!.params['free'],
        '639 GB',
      );
    });

    test('the dawn row names the park time the rule uses', () async {
      final h = await sessionHarness(overrides: _readyRig());
      final items = await _checklist(h);
      final dawn = _item(items, ChecklistItemId.dawn);
      final expected = nightDawnParkTime(
        now: DateTime(2026, 10, 19, 18, 36),
        latitude: 42.36,
        longitude: -71.06,
      )!;
      final dawnUtc = SkyCalculations.computeTwilight(
        noonLocal: DateTime(2026, 10, 19, 12),
        latitudeDegrees: 42.36,
        longitudeDegrees: -71.06,
        kind: TwilightKind.astronomical,
      ).morningStart!;
      expect(expected, dawnUtc.subtract(const Duration(minutes: 30)));
      expect(dawn.state, ChecklistItemState.ok);
      expect(dawn.detail!.key, 'nightSessionCheckDawnPark');
      expect(
        dawn.detail!.params['time'],
        nightClockTime(const SystemClock(), expected),
      );
    });

    test('no site: no dawn rule, and the site row asks for one', () async {
      final h = await sessionHarness(
        overrides: _readyRig(
          settings: const AppSettingsState(imageOutputPath: '/data'),
        ),
      );
      final items = await _checklist(h);
      final dawn = _item(items, ChecklistItemId.dawn);
      expect(dawn.state, ChecklistItemState.attention);
      expect(dawn.detail!.key, 'nightSessionCheckDawnNoSite');
      final site = _item(items, ChecklistItemId.site);
      expect(site.route, '/settings?section=location');
    });

    test('park before dawn off is stated, not hidden', () async {
      final h = await sessionHarness(
        overrides: _readyRig(
          settings: const AppSettingsState(
            latitude: 42.36,
            longitude: -71.06,
            imageOutputPath: '/data',
            parkBeforeDawn: false,
          ),
        ),
      );
      final items = await _checklist(h);
      expect(
        _item(items, ChecklistItemId.dawn).detail!.key,
        'nightSessionCheckDawnOff',
      );
    });

    test('no capture folder blocks the run', () async {
      final h = await sessionHarness(
        overrides: _readyRig(
          settings: const AppSettingsState(latitude: 42.36, longitude: -71.06),
        ),
      );
      final items = await _checklist(h);
      final disk = _item(items, ChecklistItemId.disk);
      expect(disk.state, ChecklistItemState.blocked);
      expect(disk.route, '/settings?section=files-storage');
    });

    test('a disconnected camera blocks the run', () async {
      final h = await sessionHarness(
        overrides: <Override>[
          ..._readyRig(),
          cameraStateProvider.overrideWith(
            (ref) => FixedCamera(ref, const CameraStateSnapshot()),
          ),
        ],
      );
      final items = await _checklist(h);
      final camera = _item(items, ChecklistItemId.camera);
      expect(camera.state, ChecklistItemState.blocked);
      expect(camera.route, '/equipment');
    });
  });

  group('equipment', () {
    test('an idle guider needs a look; an absent rotator reads none', () async {
      final h = await sessionHarness(overrides: _readyRig());
      final rows = h.read(nightEquipmentProvider);
      final guider = rows.firstWhere((r) => r.kind == EquipmentKind.guider);
      expect(guider.status, EquipmentStatus.attention);
      expect(guider.details.first.key, 'nightSessionGuiderNotLooping');
      final rotator = rows.firstWhere((r) => r.kind == EquipmentKind.rotator);
      expect(rotator.status, EquipmentStatus.absent);
      expect(rotator.details, isEmpty);
      final camera = rows.firstWhere((r) => r.kind == EquipmentKind.camera);
      final cooling = camera.details.first;
      expect(cooling.key, 'nightScrCoolingTo');
      expect(cooling.params, <String, String>{
        'temp': '−7.4 °C',
        'target': '−10',
      });
      final mount = rows.firstWhere((r) => r.kind == EquipmentKind.mount);
      expect(
        mount.details.map((d) => d.key),
        <String>['nightSessionMountNotTracking', 'nightSessionPierWest'],
      );
    });
  });

  group('log', () {
    // Live, the camera reports progress five times a second while a frame
    // exposes, and the in-memory history keeps 100 events: read from it,
    // a dither vanished from the log within a minute while older autofocus
    // and frame rows stayed above it.
    test('a feed row outlives the event history it came through', () async {
      final h = await sessionHarness();
      final keep = h.container.listen(nightLogProvider, (_, __) {});
      addTearDown(keep.close);
      final history = h.container.read(eventHistoryProvider.notifier);
      var ms = kNight.millisecondsSinceEpoch;
      sk_events.SkotiqEvent event(sk_events.EventPayload payload,
              sk_events.EventCategory category) =>
          sk_events.SkotiqEvent(
            eventId: BigInt.from(ms),
            timestamp: ms += 200,
            severity: sk_events.EventSeverity.info,
            category: category,
            payload: payload,
          );
      history.addEvent(event(
        const sk_events.EventPayload.guiding(
          sk_events.GuidingEvent.ditherStarted(pixels: 1.5),
        ),
        sk_events.EventCategory.guiding,
      ));
      for (var i = 0; i < 150; i++) {
        history.addEvent(event(
          const sk_events.EventPayload.imaging(
            sk_events.ImagingEvent.exposureProgress(
              progress: 0.5,
              remainingSecs: 45,
            ),
          ),
          sk_events.EventCategory.imaging,
        ));
      }
      expect(
        h.read(eventHistoryProvider).any(
              (e) => e.payload is sk_events.EventPayload_Guiding,
            ),
        isFalse,
        reason: 'the history has moved on',
      );
      final log = h.read(nightLogProvider);
      expect(log, hasLength(1), reason: 'progress ticks are not log lines');
      expect(log.single.message.literal, startsWith('Dither'));
    });

    test('past the cap the oldest lines go, the newest stay', () async {
      final h = await sessionHarness();
      for (var i = 0; i < kNightLogMaxEntries + 5; i++) {
        await h.addFrame(minutes: i, hfr: 2.0);
      }
      final log = await h.settle(nightLogProvider);
      expect(log, hasLength(kNightLogMaxEntries));
      expect(log.first.message.params['n'], '${kNightLogMaxEntries + 5}');
      expect(log.last.message.params['n'], '6');
    });

    test('frames carry their number, filter, verdict and HFR', () async {
      final h = await sessionHarness();
      await h.addFrame(minutes: 0, hfr: 2.10);
      await h.addFrame(minutes: 3, hfr: 3.05, accepted: false);
      final log = await h.settle(nightLogProvider);

      expect(log, hasLength(2));
      expect(log.first.message.key, 'nightSessionLogFrameRejected');
      expect(log.first.tone, MetricTone.bad);
      expect(log.first.message.params['n'], '2');
      expect(log.last.message.params, <String, String>{
        'n': '1',
        'filter': ' Ha',
        'hfr': ' · HFR 2.10',
        'reason': '',
      });
    });
  });
}
