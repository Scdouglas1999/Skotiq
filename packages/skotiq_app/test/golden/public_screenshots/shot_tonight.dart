// Tonight's view models, derived from [ShotNight] tonight: the run is on M31,
// NGC 7331 is done and M1 is next.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_app/screens/night_control/actions/manual_action_gating.dart';
import 'package:skotiq_app/screens/night_control/actions/night_rig_ops.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_events_provider.dart';
import 'package:skotiq_app/screens/night_control/center/frame_stage.dart';
import 'package:skotiq_app/screens/night_control/center/frame_strip.dart';
import 'package:skotiq_app/screens/night_control/center/session_charts_row.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_target_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_timeline_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_progress_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_steps_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/upcoming_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/before_you_start_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/conditions_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/equipment_summary_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/guide_series_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/last_frame_metrics_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/night_log_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_frames_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_series_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_stats_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/camera/camera_panel_vm.dart';
import 'package:skotiq_app/screens/night_control/panel/focus/focus_panel_vm.dart';
import 'package:skotiq_app/screens/night_control/panel/night_right_panel.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/after_run_section.dart';
import 'package:skotiq_app/screens/night_control/panel/panel_ops.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart' show SeriesChartTone;

import '../../screens/night_control/center/center_test_support.dart'
    show FakeNightActionApi;
import '../../screens/night_control/panel/panel_test_support.dart'
    show FakePanelOps;
import '../../screens/night_control/panel/scope_panel_test_support.dart'
    as scope;
import 'shot_night.dart';
import 'shot_rig.dart';

NightText _t(String text) => NightText.literal(text);

ShotNightRun get _night => ShotNight.tonight;
DateTime get _now => ShotNight.now;
ShotTarget get _current => lastFrame.target;

String _hm(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  return h == 0 ? '${m}m' : '${h}h${m.toString().padLeft(2, '0')}';
}

String _thousands(int v) {
  final s = v.toString();
  if (s.length <= 3) return s;
  return '${s.substring(0, s.length - 3)} ${s.substring(s.length - 3)}';
}

NightHeaderVm _header() {
  const enabled = NightControlVm.enabled();
  final targetIndex = ShotNight.targets.indexOf(_current) + 1;
  return NightHeaderVm(
    phase: NightRunPhase.running,
    runStartedAt: _night.start,
    planName: ShotNight.sequenceName,
    targetIndex: targetIndex,
    targetCount: ShotNight.targets.length,
    stepIndex: 2 + (targetIndex - 1) * 6 + 5,
    stepCount: 2 + ShotNight.targets.length * 6 + 3,
    currentFilter: lastFrame.filter,
    currentExposureSecs: lastFrame.exposureSecs,
    framesDone: currentTargetFrames.length,
    framesTotal: _current.plan.framesPerNight,
    plannedDuration: _night.slots.last.end.difference(_night.start),
    pauseResume: enabled,
    skipStep: enabled,
    stop: enabled,
  );
}

NightTimelineVm _timeline() => NightTimelineVm(
      sunset: ShotNight.sunset,
      astroDark: ShotNight.astroDark,
      astroDawn: ShotNight.astroDawn,
      sunrise: ShotNight.sunrise,
      now: _now,
      windows: [
        for (final slot in _night.slots)
          TimelineWindowVm(
            name: slot.target.name,
            start: slot.start,
            end: slot.end,
            estimated: slot.start.isAfter(_now),
            state: slot.end.isBefore(_now)
                ? TimelineWindowState.done
                : slot.start.isAfter(_now)
                    ? TimelineWindowState.planned
                    : TimelineWindowState.active,
          ),
      ],
    );

NightTargetVm _target() {
  final t = _current;
  final (alt, _) = ShotNight.altAz(t, _now);
  final transit = ShotNight.transit(t, 0);
  final (transitAlt, _) = ShotNight.altAz(t, transit);
  DateTime? belowLimit;
  for (var m = 0; m < 12 * 60; m += 5) {
    final at = _now.add(Duration(minutes: m));
    if (ShotNight.altAz(t, at).$1 < 30) {
      belowLimit = at;
      break;
    }
  }
  return NightTargetVm(
    name: t.name,
    nodeId: 'target-${t.folder.toLowerCase()}',
    constellation: t.constellation,
    objectType: t.objectType.toLowerCase(),
    sizeArcmin: t.sizeArcmin,
    raHours: t.raHours,
    decDegrees: t.decDegrees,
    rotationDeg: 0.6,
    altitudeDeg: alt,
    hourAngleHours: ShotNight.hourAngle(t, _now),
    airmass: 1 / math.sin(alt * math.pi / 180),
    horizonLimitDeg: 30,
    altitudeCurve: [
      for (var m = 0; m <= 14 * 60; m += 15)
        SeriesPoint(
          ShotNight.sunset.add(Duration(minutes: m)),
          ShotNight.altAz(t, ShotNight.sunset.add(Duration(minutes: m))).$1,
        ),
    ],
    moonAltitudeCurve: const [],
    moonIlluminationPct: 31,
    transitAt: transit,
    transitAltitudeDeg: transitAlt,
    belowLimitAt: belowLimit,
    flipAt: transit.add(const Duration(minutes: 5)),
  );
}

NightPlanVm _plan() {
  final t = _current;
  final done = <String, int>{};
  for (final f in currentTargetFrames) {
    done[f.filter] = (done[f.filter] ?? 0) + 1;
  }
  final secs = t.plan.exposureSecs.round();
  return NightPlanVm(
    rows: [
      for (final e in t.plan.frames.entries)
        PlanFilterRowVm(
          filter: e.key,
          framesDone: done[e.key] ?? 0,
          framesPlanned: e.value,
          integrated: Duration(seconds: (done[e.key] ?? 0) * secs),
          isCurrent: e.key == lastFrame.filter,
        ),
    ],
    integrated: Duration(seconds: currentTargetFrames.length * secs),
    planned: Duration(seconds: t.plan.framesPerNight * secs),
    eta: _night.slots.firstWhere((s) => s.target.id == t.id).end,
  );
}

List<PlanStepVm> _steps() {
  final steps = <PlanStepVm>[];
  steps.add(PlanStepVm(
    nodeId: 'unpark',
    label: 'Unpark',
    status: PlanStepStatus.done,
    when: StepWhenActual(_night.start.subtract(const Duration(minutes: 9))),
  ));
  steps.add(PlanStepVm(
    nodeId: 'cool',
    label: 'Cool to −10 °C',
    status: PlanStepStatus.done,
    when: StepWhenActual(_night.start.subtract(const Duration(minutes: 8))),
  ));
  for (final slot in _night.slots) {
    final t = slot.target;
    final k = t.folder.toLowerCase();
    final isCurrent = t.id == _current.id;
    final done = slot.end.isBefore(_now);
    final secs = t.plan.exposureSecs.round();
    steps.add(PlanStepVm(
      nodeId: '$k-center',
      label: 'Slew & center ${t.name}',
      status: done || isCurrent ? PlanStepStatus.done : PlanStepStatus.pending,
      when: done || isCurrent
          ? StepWhenActual(slot.start)
          : StepWhenPlanned(slot.start),
    ));
    steps.add(PlanStepVm(
      nodeId: '$k-lrgb',
      label: 'LRGB ${t.plan.framesPerNight} × $secs s',
      status: isCurrent
          ? PlanStepStatus.active
          : done
              ? PlanStepStatus.done
              : PlanStepStatus.pending,
      when: isCurrent
          ? StepWhenProgress(currentTargetFrames.length, t.plan.framesPerNight)
          : done
              ? StepWhenActual(slot.end)
              : StepWhenPlanned(slot.start.add(const Duration(minutes: 6))),
    ));
  }
  steps.add(PlanStepVm(
    nodeId: 'park',
    label: 'Warm up & park',
    status: PlanStepStatus.pending,
    when: StepWhenPlanned(_night.slots.last.end),
  ));
  return steps;
}

List<UpcomingItemVm> _upcoming() {
  final next = _night.slots.firstWhere((s) => s.start.isAfter(_now));
  final flipFor = ShotNight.transit(next.target, 0);
  return [
    UpcomingItemVm(
      kind: UpcomingKind.dither,
      afterFrame:
          currentTargetFrames.length + 10 - currentTargetFrames.length % 10,
    ),
    const UpcomingItemVm(
      kind: UpcomingKind.autofocus,
      everyFrames: 30,
      tempDeltaC: 1,
    ),
    UpcomingItemVm(
      kind: UpcomingKind.targetSwitch,
      at: next.start,
      subject: next.target.name,
    ),
    UpcomingItemVm(
      kind: UpcomingKind.meridianFlip,
      at: flipFor.add(const Duration(minutes: 5)),
    ),
    UpcomingItemVm(kind: UpcomingKind.astroDawn, at: ShotNight.astroDawn),
  ];
}

List<StripFrameVm> _strip() {
  final frames = _night.frames;
  final last = frames.sublist(frames.length - 12);
  return [
    for (final (i, f) in last.indexed)
      StripFrameVm(
        id: ShotNight.frameId(f),
        frameNumber: frames.length - 12 + i + 1,
        capturedAt: f.capturedAt,
        filter: f.filter,
        exposureSecs: f.exposureSecs,
        hfr: f.hfr,
        starCount: f.stars,
        accepted: true,
        isNewest: i == last.length - 1,
      ),
  ];
}

NightSeriesVm _frameSeries() {
  final frames = _night.frames;
  final hfr = [for (final f in frames) SeriesPoint(f.capturedAt, f.hfr)];
  final stars = [
    for (final f in frames) SeriesPoint(f.capturedAt, f.stars.toDouble()),
  ];
  final hfrs = frames.map((f) => f.hfr).toList()..sort();
  final recent = currentTargetFrames.sublist(currentTargetFrames.length - 10);
  return NightSeriesVm(
    lines: [
      SeriesLineVm(
          id: NightSeriesId.hfr, points: hfr, tone: SeriesChartTone.primary),
      SeriesLineVm(
        id: NightSeriesId.stars,
        points: stars,
        tone: SeriesChartTone.secondary,
        secondaryAxis: true,
      ),
    ],
    markers: [
      for (final af in _night.autofocusRuns)
        SeriesMarker(af.at, SeriesMarkerKind.autofocus),
    ],
    from: _night.start,
    to: _now,
    legend: [
      MetricVm(
        label: const NightText('nightSessionHfr'),
        value: lastFrame.hfr.toStringAsFixed(2),
      ),
      MetricVm(
        label: const NightText('nightSessionHfrMin'),
        value: hfrs.first.toStringAsFixed(2),
      ),
      MetricVm(
        label: const NightText('nightSessionStars'),
        value:
            (recent.fold(0, (s, f) => s + f.stars) ~/ recent.length).toString(),
      ),
    ],
    sampleCount: frames.length,
  );
}

/// The last ten minutes of guiding, in guide-camera pixels as the provider
/// reports them, from the same trace the Guiding screen draws.
NightSeriesVm _guideSeries() {
  final end = _now;
  final start = end.subtract(const Duration(minutes: 10));
  final trace = guideTrace.sublist(guideTrace.length - 200);
  final ra = <SeriesPoint>[];
  final dec = <SeriesPoint>[];
  for (final (i, p) in trace.indexed) {
    final t = start.add(Duration(seconds: 3 * i));
    ra.add(SeriesPoint(t, p.ra));
    dec.add(SeriesPoint(t, p.dec));
  }
  String px(double arcsec) =>
      '${(arcsec / guidePixelScale).toStringAsFixed(2)} px';
  return NightSeriesVm(
    lines: [
      SeriesLineVm(
          id: NightSeriesId.guideRa, points: ra, tone: SeriesChartTone.primary),
      SeriesLineVm(
        id: NightSeriesId.guideDec,
        points: dec,
        tone: SeriesChartTone.tertiary,
      ),
    ],
    markers: [
      SeriesMarker(
        start.add(const Duration(minutes: 3)),
        SeriesMarkerKind.dither,
      ),
    ],
    from: start,
    to: end,
    legend: [
      MetricVm(
          label: const NightText('nightSessionGuideRms'),
          value: px(guideRmsTotal)),
      MetricVm(
          label: const NightText('nightSessionGuideRa'), value: px(guideRmsRa)),
      MetricVm(
          label: const NightText('nightSessionGuideDec'),
          value: px(guideRmsDec)),
      MetricVm(
          label: const NightText('nightSessionGuidePeak'), value: px(1.12)),
      const MetricVm(label: NightText('nightSessionGuideSnr'), value: '61'),
    ],
  );
}

NightSeriesVm _temperatureSeries() {
  final frames = _night.frames;
  return NightSeriesVm(
    lines: [
      SeriesLineVm(
        id: NightSeriesId.focuserTemp,
        points: [
          for (final f in frames) SeriesPoint(f.capturedAt, f.focuserTemp)
        ],
        tone: SeriesChartTone.muted,
      ),
      SeriesLineVm(
        id: NightSeriesId.focuserPosition,
        points: [
          for (final f in frames)
            SeriesPoint(f.capturedAt, f.focuserPosition.toDouble()),
        ],
        tone: SeriesChartTone.primary,
        secondaryAxis: true,
        stepped: true,
      ),
      SeriesLineVm(
        id: NightSeriesId.sensorTemp,
        points: [for (final f in frames) SeriesPoint(f.capturedAt, -10)],
        tone: SeriesChartTone.secondary,
        dashed: true,
      ),
    ],
    markers: [
      for (final af in _night.autofocusRuns)
        SeriesMarker(af.at, SeriesMarkerKind.autofocus),
    ],
    from: _night.start,
    to: _now,
    legend: [
      MetricVm(
        label: const NightText('nightSessionFocuserTemp'),
        value: '${lastFrame.focuserTemp.toStringAsFixed(1)} °C',
      ),
      MetricVm(
        label: const NightText('nightSessionFocuserPosition'),
        value: _thousands(lastFrame.focuserPosition),
      ),
      const MetricVm(
        label: NightText('nightSessionSensorTemp'),
        value: '−10.0 °C',
      ),
    ],
  );
}

NightLastFrameVm _lastFrame() {
  final f = lastFrame;
  final prev = currentTargetFrames
      .lastWhere((p) => p.filter == f.filter && p != f, orElse: () => f);
  String delta(double d, int digits) =>
      '${d >= 0 ? '+' : '−'}${d.abs().toStringAsFixed(digits)}';
  return NightLastFrameVm(
    frameNumber: _night.frames.length,
    metrics: [
      MetricVm(
        label: _t('HFR'),
        value: f.hfr.toStringAsFixed(2),
        delta: delta(f.hfr - prev.hfr, 2),
      ),
      MetricVm(
        label: _t('FWHM'),
        value: '${f.fwhmArcsec.toStringAsFixed(1)}"',
        delta: delta(f.fwhmArcsec - prev.fwhmArcsec, 1),
      ),
      MetricVm(label: _t('Ecc'), value: f.eccentricity.toStringAsFixed(2)),
      MetricVm(
        label: _t('Stars'),
        value: f.stars.toString(),
        delta: delta((f.stars - prev.stars).toDouble(), 0),
      ),
      MetricVm(label: _t('Median'), value: f.background.round().toString()),
      MetricVm(label: _t('Bg noise'), value: f.noise.toStringAsFixed(1)),
      MetricVm(label: _t('SNR'), value: '41.8'),
      MetricVm(label: _t('Solve'), value: '0.6"', delta: 'off'),
    ],
    histogram: [
      for (var i = 0; i < 256; i++)
        (4200 * math.exp(-math.pow(i - 26, 2) / 46) +
                180 * math.exp(-math.pow(i - 90, 2) / 900))
            .round(),
    ],
  );
}

NightSessionVm _session() {
  final frames = _night.frames;
  final remaining = _night.slots.last.end.difference(_now);
  return NightSessionVm(
    frameCount: frames.length,
    elapsed: _now.difference(_night.start),
    metrics: [
      MetricVm(label: _t('Accepted'), value: '${frames.length}'),
      MetricVm(label: _t('Rejected'), value: '0'),
      MetricVm(
        label: _t('Integration'),
        value: _hm(Duration(seconds: _night.integrationSecs.round())),
      ),
      MetricVm(label: _t('Remaining'), value: _hm(remaining)),
      MetricVm(
        label: _t('Autofocus'),
        value: '${_night.autofocusRuns.length} runs',
      ),
      MetricVm(label: _t('Dithers'), value: '${_night.dithers}'),
      MetricVm(label: _t('Disk'), value: '1.3 TB'),
      MetricVm(label: _t('Flips'), value: '${_night.meridianFlips}'),
    ],
  );
}

List<EquipmentRowVm> _equipment() {
  final (alt, az) = ShotNight.altAz(_current, _now);
  return [
    EquipmentRowVm(
      kind: EquipmentKind.camera,
      status: EquipmentStatus.ok,
      deviceName: ShotNight.camera,
      details: [
        _t('−10.0 °C'),
        _t('${lastFrame.coolerPower.round()}%'),
        _t('g${ShotNight.gain} o${ShotNight.offset}'),
        _t('1×1'),
      ],
    ),
    EquipmentRowVm(
      kind: EquipmentKind.filterWheel,
      status: EquipmentStatus.ok,
      deviceName: 'ZWO EFW',
      details: [
        _t('${lastFrame.filter} '
            '(${ShotNight.filters.indexOf(lastFrame.filter) + 1} of 7)'),
      ],
    ),
    EquipmentRowVm(
      kind: EquipmentKind.focuser,
      status: EquipmentStatus.ok,
      deviceName: ShotNight.focuser,
      details: [
        _t(_thousands(lastFrame.focuserPosition)),
        _t('${lastFrame.focuserTemp.toStringAsFixed(1)} °C'),
      ],
    ),
    EquipmentRowVm(
      kind: EquipmentKind.mount,
      status: EquipmentStatus.ok,
      deviceName: 'NYX-101',
      details: [
        _t('tracking'),
        _t(az < 180 ? 'pier W' : 'pier E'),
        _t('alt ${alt.toStringAsFixed(1)}°'),
      ],
    ),
    EquipmentRowVm(
      kind: EquipmentKind.guider,
      status: EquipmentStatus.ok,
      deviceName: 'PHD2',
      details: [_t('guiding'), _t('${guideRmsTotal.toStringAsFixed(2)}" RMS')],
    ),
  ];
}

NightConditionsVm _conditions() {
  final ambient = ShotNight.ambientAt(0, _now);
  return NightConditionsVm(
    source: ConditionsSource.device,
    safe: true,
    metrics: [
      MetricVm(label: _t('Clouds'), value: '0%'),
      MetricVm(label: _t('Humidity'), value: '64%'),
      MetricVm(
        label: _t('Dew point'),
        value: '${(ambient - 6.8).toStringAsFixed(1)} °C',
      ),
      MetricVm(label: _t('Wind'), value: '5 km/h'),
      MetricVm(label: _t('SQM'), value: '21.4'),
      MetricVm(label: _t('Ambient'), value: '${ambient.toStringAsFixed(1)} °C'),
    ],
  );
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

List<NightLogEntryVm> _log() {
  final frames = currentTargetFrames;
  final entries = <NightLogEntryVm>[];
  for (var i = frames.length - 1; i >= frames.length - 5; i--) {
    final f = frames[i];
    entries.add(NightLogEntryVm(
      at: f.capturedAt,
      message: _t('#${_night.frames.indexOf(f) + 1} ${f.filter} accepted · '
          'HFR ${f.hfr.toStringAsFixed(2)}'),
    ));
    if (f.frameNumber % 10 == 0) {
      entries.add(NightLogEntryVm(
        at: f.capturedAt.add(const Duration(seconds: 2)),
        message: _t('Dither 1.5 px · settled 8 s'),
      ));
    }
  }
  final lastAf = _night.autofocusRuns.last;
  entries.add(NightLogEntryVm(
    at: lastAf.at,
    message: _t('Autofocus ${_thousands(lastAf.position)} · '
        'HFR ${lastAf.hfr.toStringAsFixed(2)}'),
  ));
  final flip = ShotNight.transit(_current, 0).add(const Duration(minutes: 5));
  if (flip.isBefore(_now)) {
    entries.add(NightLogEntryVm(
      at: flip,
      message: _t('Meridian flip · recentered 4" · guiding resumed'),
    ));
  }
  entries.sort((a, b) => b.at.compareTo(a.at));
  assert(_clock(_now).isNotEmpty);
  return entries.take(9).toList();
}

List<ManualActionVm> _actions() {
  ManualActionVm a(ManualActionId id, String label,
          {String? sub, String? disabledReason}) =>
      ManualActionVm(
        id: id,
        label: _t(label),
        sub: sub == null ? null : _t(sub),
        enabled: disabledReason == null,
        disabledReason: disabledReason == null ? null : _t(disabledReason),
      );
  return [
    a(ManualActionId.snapshot, 'Snapshot', sub: '5 s'),
    a(ManualActionId.loop, 'Loop'),
    a(ManualActionId.autofocus, 'Autofocus', sub: lastFrame.filter),
    a(ManualActionId.solveSync, 'Solve & sync'),
    a(ManualActionId.center, 'Center', sub: _current.name),
    a(ManualActionId.dither, 'Dither'),
  ];
}

NightCameraPanelVm _camera() {
  final secs = lastFrame.exposureSecs.round();
  return NightCameraPanelVm(
    canCommand: true,
    runLive: true,
    connected: true,
    deviceName: 'ASI1600MM-Cool',
    coolerState: NightCoolerState.atSetpoint,
    sensorTemp: -10,
    setpoint: -10,
    coolerPower: lastFrame.coolerPower.roundToDouble(),
    defaultSetpoint: -10,
    step: NightCaptureValues(
      exposureSecs: secs.toDouble(),
      gain: ShotNight.gain,
      offset: ShotNight.offset,
      frameType: FrameType.light,
      binning: 1,
      filter: lastFrame.filter,
    ),
    stepNodeId: '${_current.folder.toLowerCase()}-lrgb',
    stepLabel: 'LRGB ${_current.plan.framesPerNight} × $secs s',
    stepIndex: 9,
    filters: NightFilterSlotsVm(
      connected: true,
      names: ShotNight.filters,
      current: ShotNight.filters.indexOf(lastFrame.filter),
      offsets: const {'L': 0, 'R': 12, 'G': 9, 'B': 21},
      referenceFilter: 'L',
    ),
    sensorSpecs: '${ShotNight.sensorWidth} × ${ShotNight.sensorHeight} · '
        '${ShotNight.pixelSizeUm.toStringAsFixed(2)} µm',
    savesTo: 'D:\\Astro\\Skotiq\\${_current.folder}\\${lastFrame.filter}',
    diskFreeBytes: 1312 * 1024 * 1024 * 1024,
    nightsOfSpace: 140,
  );
}

NightSeriesVm _coolerHistory() {
  final from = _night.start.subtract(const Duration(minutes: 8));
  return NightSeriesVm(
    lines: [
      SeriesLineVm(
        id: NightSeriesId.sensorTemp,
        tone: SeriesChartTone.secondary,
        points: [
          for (var m = 0; m <= _now.difference(from).inMinutes; m += 5)
            SeriesPoint(
              from.add(Duration(minutes: m)),
              m < 10 ? 9 - 19 * m / 10 : -10,
            ),
        ],
      ),
    ],
    from: from,
    to: _now,
  );
}

/// The last autofocus run tonight as a nine-point V-curve.
NightFocusPanelVm _focus() {
  final runs = _night.autofocusRuns;
  final last = runs.last;
  const step = 60;
  // A hyperbola through the best focus, measured: each point carries a
  // little seeing noise, and the fitted minimum sits between two samples.
  const noise = [0.04, -0.03, 0.05, -0.02, 0.01, 0.03, -0.04, 0.02, 0.06];
  double hfrAt(int i) =>
      math.sqrt(last.hfr * last.hfr + math.pow(0.65 * (i - 0.2), 2)) +
      noise[i + 4];
  final points = <VCurvePoint>[
    for (var i = -4; i <= 4; i++)
      VCurvePoint(
        position: last.position - 12 + i * step,
        hfr: double.parse(hfrAt(i).toStringAsFixed(2)),
      ),
  ];
  final stars = [
    for (var i = -4; i <= 4; i++)
      (lastFrame.stars * math.pow(last.hfr / hfrAt(i), 1.6) +
              (i * 37 % 60) -
              30)
          .round(),
  ];
  return NightFocusPanelVm(
    canCommand: true,
    runLive: true,
    status: NightAutofocusStatus.done,
    focuserConnected: true,
    point: 9,
    totalPoints: 9,
    points: points,
    starCounts: stars,
    bestPosition: last.position,
    bestHfr: last.hfr,
    fitQuality: 0.97,
    focuserName: 'EAF',
    position: lastFrame.focuserPosition,
    maxPosition: 600000,
    focuserTemp: lastFrame.focuserTemp,
    recentRuns: [
      for (final run in runs.reversed.take(4))
        NightAutofocusRun(
          at: run.at,
          position: run.position,
          hfr: run.hfr,
          duration: const Duration(minutes: 2, seconds: 40),
        ),
    ],
  );
}

class _GuideSamples extends NightGuideSamplesNotifier {
  _GuideSamples(super.ref) {
    final t0 = _now.subtract(const Duration(minutes: 10)).toUtc();
    final trace = guideTrace.sublist(guideTrace.length - 200);
    state = [
      for (final (i, p) in trace.indexed)
        NightGuideSample(
          t0.add(Duration(seconds: 3 * i)),
          p.ra,
          p.dec,
        ),
    ];
  }
}

/// Every Tonight provider for the run at [ShotNight.now], with [tab] open.
List<Override> tonightOverrides({NightPanelTab tab = NightPanelTab.overview}) =>
    <Override>[
      nightPanelTabProvider.overrideWith((ref) => tab),
      nightNowProvider.overrideWithValue(_now.toUtc()),
      nightRunPhaseProvider.overrideWithValue(NightRunPhase.running),
      nightHeaderProvider.overrideWithValue(_header()),
      nightTimelineProvider.overrideWithValue(_timeline()),
      nightTargetProvider.overrideWithValue(_target()),
      nightPlanProgressProvider.overrideWithValue(_plan()),
      nightPlanStepsProvider.overrideWithValue(_steps()),
      nightUpcomingProvider.overrideWithValue(_upcoming()),
      nightSessionFramesProvider.overrideWithValue(_strip()),
      nightFrameSeriesProvider.overrideWithValue(_frameSeries()),
      nightGuideSeriesProvider.overrideWithValue(_guideSeries()),
      nightTemperatureSeriesProvider.overrideWithValue(_temperatureSeries()),
      nightCoolerHistoryProvider.overrideWithValue(_coolerHistory()),
      nightManualActionsProvider.overrideWithValue(_actions()),
      nightActionStateProvider.overrideWithValue(ManualActionState.idle),
      nightActionApiProvider.overrideWithValue(FakeNightActionApi()),
      nightStageImageProvider.overrideWithValue(capturedFrame),
      nightStageExposureProvider.overrideWithValue(
        NightExposureVm(
          elapsed: (lastFrame.exposureSecs * 0.58).roundToDouble(),
          total: lastFrame.exposureSecs,
        ),
      ),
      nightStageAutofocusProvider.overrideWithValue(null),
      nightStageSolveProvider.overrideWithValue(null),
      nightStageStretchProvider.overrideWithValue(false),
      nightLastSessionProvider.overrideWithValue(null),
      nightLastAutofocusProvider.overrideWithValue(null),
      nightGuiderIdleProvider.overrideWithValue(
        const NightGuiderIdleVm(
          connected: true,
          canCommand: true,
          state: Phd2State.guiding,
        ),
      ),
      stretchedImageProvider.overrideWith((ref) async => null),
      isRemoteModeProvider.overrideWithValue(false),
      nightLastFrameProvider.overrideWithValue(_lastFrame()),
      nightSessionStatsProvider.overrideWithValue(_session()),
      nightEquipmentProvider.overrideWithValue(_equipment()),
      nightConditionsProvider.overrideWithValue(_conditions()),
      nightLogProvider.overrideWithValue(_log()),
      nightBeforeYouStartProvider.overrideWithValue(const []),
      nightAfterRunProvider.overrideWithValue(
        NightAfterRunVm(
          sessionId: _night.sessionId,
          mountUnparked: true,
          coolerOn: true,
        ),
      ),
      nightCameraPanelProvider.overrideWithValue(_camera()),
      nightFocusPanelProvider.overrideWithValue(_focus()),
      nightPanelOpsProvider.overrideWithValue(FakePanelOps()),
      nightFocusActiveProvider.overrideWithValue(false),
      nightGuideAlertProvider.overrideWithValue(false),
      mountCapabilitiesProvider('nyx101')
          .overrideWith((_) async => scope.kFullMount),
      nightActionInputsProvider.overrideWithValue(
        NightActionInputs(
          canCommand: true,
          runState: SequenceExecutionState.running,
          action: ManualActionState.idle,
          cameraConnected: true,
          mountConnected: true,
          focuserConnected: true,
          guiderConnected: true,
          isGuiding: true,
          mountParked: false,
          mountTracking: true,
          hasTarget: true,
          hasFrame: true,
          targetName: _current.name,
          solverMissing: false,
        ),
      ),
      nightCenterTargetProvider.overrideWithValue(
        NightCenterTarget(
          name: _current.name,
          raHours: _current.raHours,
          decDegrees: _current.decDegrees,
        ),
      ),
      nightGuideSamplesProvider.overrideWith(_GuideSamples.new),
    ];
