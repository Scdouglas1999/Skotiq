// View models reproducing the approved Tonight boards
// (docs/design/night-control-boards/*.dc.html): the running night
// (Tonight.dc.html), the ready state before a run (TonightReady.dc.html) and
// a manual autofocus holding the run (TonightFocus.dc.html).
//
// The boards also show values the screen cannot know (seeing, power, guide
// star size). The fixtures leave those out, the way the providers will, so a
// widget test sees what the app will really render.
//
// Usage:
//   final night = NightFixtures.running();
//   overrides: [nightHeaderProvider.overrideWithValue(night.header), ...]
import 'dart:math' as math;

import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';

/// Every view model one board needs.
class NightBoard {
  const NightBoard({
    required this.phase,
    required this.header,
    required this.timeline,
    required this.target,
    required this.plan,
    required this.steps,
    required this.upcoming,
    required this.frames,
    required this.frameSeries,
    required this.guideSeries,
    required this.temperatureSeries,
    required this.lastFrame,
    required this.session,
    required this.equipment,
    required this.conditions,
    required this.log,
    required this.checklist,
    required this.actions,
    required this.actionState,
  });

  final NightRunPhase phase;
  final NightHeaderVm header;
  final NightTimelineVm? timeline;
  final NightTargetVm? target;
  final NightPlanVm? plan;
  final List<PlanStepVm> steps;
  final List<UpcomingItemVm> upcoming;
  final List<StripFrameVm> frames;
  final NightSeriesVm frameSeries;
  final NightSeriesVm guideSeries;
  final NightSeriesVm temperatureSeries;
  final NightLastFrameVm? lastFrame;
  final NightSessionVm session;
  final List<EquipmentRowVm> equipment;
  final NightConditionsVm conditions;
  final List<NightLogEntryVm> log;
  final List<ChecklistItemVm> checklist;
  final List<ManualActionVm> actions;
  final ManualActionState actionState;
}

/// Builders for the three boards. Times are local, on the night of
/// 2026-10-17 into the 18th.
abstract final class NightFixtures {
  /// A local time on the board's night: hours before noon fall on the 18th.
  static DateTime at(int hour, int minute, [int second = 0]) =>
      DateTime(2026, 10, hour < 12 ? 18 : 17, hour, minute, second);

  static NightText _t(String text) => NightText.literal(text);

  /// Tonight.dc.html: running 4 h 04 m, Ha 44/60, now 23:52.
  static NightBoard running() => NightBoard(
        phase: NightRunPhase.running,
        header: header(NightRunPhase.running),
        timeline: timeline(now: at(23, 52), running: true),
        target: target(),
        plan: plan(),
        steps: steps(running: true),
        upcoming: comingUp(),
        frames: strip(),
        frameSeries: frameSeries(),
        guideSeries: guideSeries(),
        temperatureSeries: temperatureSeries(),
        lastFrame: lastFrame(),
        session: session(),
        equipment: equipment(),
        conditions: conditions(),
        log: log(),
        checklist: const <ChecklistItemVm>[],
        actions: runningActions(),
        actionState: ManualActionState.idle,
      );

  /// TonightReady.dc.html: plan loaded, now 18:36, dark in 1 h 12 m.
  static NightBoard ready() => NightBoard(
        phase: NightRunPhase.ready,
        header: header(NightRunPhase.ready),
        timeline: timeline(now: at(18, 36), running: false),
        target: target(),
        plan: readyPlan(),
        steps: steps(running: false),
        upcoming: theNight(),
        frames: const <StripFrameVm>[],
        frameSeries: const NightSeriesVm(lines: <SeriesLineVm>[]),
        guideSeries: const NightSeriesVm(lines: <SeriesLineVm>[]),
        temperatureSeries: const NightSeriesVm(lines: <SeriesLineVm>[]),
        lastFrame: null,
        session: const NightSessionVm(metrics: <MetricVm>[]),
        equipment: readyEquipment(),
        conditions: NightConditionsVm(
          source: ConditionsSource.none,
          metrics: <MetricVm>[
            MetricVm(label: _t('Moon'), value: 'set 23:09'),
          ],
        ),
        log: readyLog(),
        checklist: beforeYouStart(),
        actions: readyActions(),
        actionState: ManualActionState.idle,
      );

  /// TonightFocus.dc.html: the operator's autofocus holds the run at point
  /// 6 of 9.
  static NightBoard autofocus() {
    final base = running();
    return NightBoard(
      phase: NightRunPhase.pausedForAction,
      header: header(
        NightRunPhase.pausedForAction,
        pausedFor: ManualActionId.autofocus,
      ),
      timeline: base.timeline,
      target: base.target,
      plan: base.plan,
      steps: base.steps,
      upcoming: base.upcoming,
      frames: base.frames,
      frameSeries: base.frameSeries,
      guideSeries: base.guideSeries,
      temperatureSeries: base.temperatureSeries,
      lastFrame: base.lastFrame,
      session: base.session,
      equipment: base.equipment,
      conditions: base.conditions,
      log: base.log,
      checklist: base.checklist,
      actions: autofocusActions(),
      actionState: const ManualActionState(
        phase: ManualActionPhase.running,
        active: ManualActionId.autofocus,
        startedRunPause: true,
      ),
    );
  }

  // -- Header and timeline --------------------------------------------------

  static NightHeaderVm header(
    NightRunPhase phase, {
    ManualActionId? pausedFor,
  }) {
    const enabled = NightControlVm.enabled();
    final runLoaded = phase == NightRunPhase.running ||
        phase == NightRunPhase.pausedByUser ||
        phase == NightRunPhase.pausedForAction;
    return NightHeaderVm(
      phase: phase,
      pausedFor: pausedFor,
      runStartedAt: runLoaded ? at(19, 48) : null,
      planName: 'M74 Plan',
      targetIndex: runLoaded ? 1 : null,
      targetCount: 2,
      stepIndex: runLoaded ? 7 : null,
      stepCount: 12,
      currentFilter: runLoaded ? 'Ha' : null,
      currentExposureSecs: runLoaded ? 180 : null,
      framesDone: runLoaded ? 44 : null,
      framesTotal: runLoaded ? 60 : null,
      plannedDuration: const Duration(hours: 7),
      pauseResume: runLoaded ? enabled : null,
      skipStep: runLoaded ? enabled : null,
      stop: runLoaded ? enabled : null,
      startNow: runLoaded ? null : enabled,
      startAtDark: runLoaded ? null : enabled,
    );
  }

  static NightTimelineVm timeline({
    required DateTime now,
    required bool running,
  }) =>
      NightTimelineVm(
        sunset: at(18, 18),
        astroDark: at(19, 48),
        astroDawn: at(5, 44),
        sunrise: at(7, 14),
        now: now,
        windows: <TimelineWindowVm>[
          TimelineWindowVm(
            name: 'M74',
            start: at(19, 48),
            end: at(3, 40),
            estimated: true,
            state: running
                ? TimelineWindowState.active
                : TimelineWindowState.planned,
          ),
          TimelineWindowVm(
            name: 'NGC 891',
            start: at(3, 40),
            end: at(5, 30),
            estimated: true,
            state: TimelineWindowState.planned,
          ),
        ],
      );

  // -- Left column ----------------------------------------------------------

  static NightTargetVm target() => NightTargetVm(
        name: 'M74',
        nodeId: 'target-m74',
        constellation: 'Psc',
        objectType: 'galaxy',
        sizeArcmin: 9.9,
        raHours: 1 + 36 / 60 + 42 / 3600,
        decDegrees: 15 + 47 / 60 + 1 / 3600,
        rotationDeg: 0.4,
        altitudeDeg: 62.8,
        hourAngleHours: -59 / 60,
        airmass: 1.12,
        horizonLimitDeg: 30,
        altitudeCurve: _altitudeCurve(),
        moonAltitudeCurve: _moonCurve(),
        moonIlluminationPct: 44,
        moonSet: at(23, 9),
        transitAt: at(0, 51),
        transitAltitudeDeg: 66,
        belowLimitAt: at(4, 20),
        flipAt: at(1, 58),
      );

  static List<SeriesPoint> _altitudeCurve() => <SeriesPoint>[
        for (var m = 0; m <= 13 * 60; m += 20)
          SeriesPoint(
            at(18, 18).add(Duration(minutes: m)),
            // Peaks at 66° at 00:51 (393 minutes after sunset).
            66 - 0.0016 * math.pow(m - 393, 2).toDouble(),
          ),
      ];

  static List<SeriesPoint> _moonCurve() => <SeriesPoint>[
        for (var m = 0; m <= 300; m += 20)
          SeriesPoint(at(18, 18).add(Duration(minutes: m)), 35 - m * 0.13),
      ];

  static NightPlanVm plan() => NightPlanVm(
        rows: const <PlanFilterRowVm>[
          PlanFilterRowVm(
            filter: 'L',
            framesDone: 60,
            framesPlanned: 60,
            integrated: Duration(hours: 3),
            isCurrent: false,
          ),
          PlanFilterRowVm(
            filter: 'R',
            framesDone: 20,
            framesPlanned: 20,
            integrated: Duration(hours: 1),
            isCurrent: false,
          ),
          PlanFilterRowVm(
            filter: 'G',
            framesDone: 20,
            framesPlanned: 20,
            integrated: Duration(hours: 1),
            isCurrent: false,
          ),
          PlanFilterRowVm(
            filter: 'B',
            framesDone: 12,
            framesPlanned: 20,
            integrated: Duration(minutes: 36),
            isCurrent: false,
          ),
          PlanFilterRowVm(
            filter: 'Ha',
            framesDone: 43,
            framesPlanned: 60,
            integrated: Duration(hours: 2, minutes: 9),
            isCurrent: true,
          ),
        ],
        integrated: const Duration(hours: 5, minutes: 10),
        planned: const Duration(hours: 7),
        eta: at(5, 30),
      );

  static NightPlanVm readyPlan() => NightPlanVm(
        rows: <PlanFilterRowVm>[
          for (final (filter, planned) in const <(String, int)>[
            ('L', 60),
            ('R', 20),
            ('G', 20),
            ('B', 20),
            ('Ha', 60),
          ])
            PlanFilterRowVm(
              filter: filter,
              framesDone: 0,
              framesPlanned: planned,
              integrated: Duration.zero,
              isCurrent: false,
            ),
        ],
        integrated: Duration.zero,
        planned: const Duration(hours: 7),
        eta: at(5, 30),
      );

  static const List<String> _stepLabels = <String>[
    'Cool to −10 °C',
    'Slew & center M74',
    'Start guiding',
    'Autofocus (L)',
    'L 60 × 180 s',
    'RGB 20 × 180 s each',
    'Ha 60 × 180 s, dither 3',
    'Slew & center NGC 891',
    'L 30 × 180 s',
    'Warm up & stop guiding',
  ];

  static List<PlanStepVm> steps({required bool running}) {
    final done = <DateTime>[
      at(19, 40),
      at(19, 52),
      at(19, 55),
      at(19, 57),
      at(20, 1),
      at(21, 40),
    ];
    final planned = <DateTime>[
      ...done,
      at(23, 20),
      at(3, 40),
      at(3, 46),
      at(5, 30),
    ];
    return <PlanStepVm>[
      for (var i = 0; i < _stepLabels.length; i++)
        PlanStepVm(
          nodeId: 'step-${i + 1}',
          label: _stepLabels[i],
          status: !running
              ? PlanStepStatus.pending
              : i < 6
                  ? PlanStepStatus.done
                  : i == 6
                      ? PlanStepStatus.active
                      : PlanStepStatus.pending,
          when: !running
              ? StepWhenPlanned(planned[i])
              : i < 6
                  ? StepWhenActual(done[i])
                  : i == 6
                      ? const StepWhenProgress(44, 60)
                      : StepWhenPlanned(planned[i]),
        ),
    ];
  }

  static List<UpcomingItemVm> comingUp() => <UpcomingItemVm>[
        const UpcomingItemVm(kind: UpcomingKind.dither, afterFrame: 45),
        const UpcomingItemVm(
          kind: UpcomingKind.autofocus,
          everyFrames: 6,
          tempDeltaC: 1,
        ),
        UpcomingItemVm(
          kind: UpcomingKind.meridianFlip,
          at: at(1, 58),
          tone: MetricTone.warning,
        ),
        UpcomingItemVm(
          kind: UpcomingKind.targetSwitch,
          at: at(3, 40),
          subject: 'NGC 891',
        ),
        UpcomingItemVm(kind: UpcomingKind.astroDawn, at: at(5, 44)),
      ];

  static List<UpcomingItemVm> theNight() => <UpcomingItemVm>[
        UpcomingItemVm(kind: UpcomingKind.sunset, at: at(18, 18), passed: true),
        UpcomingItemVm(kind: UpcomingKind.astroDark, at: at(19, 48)),
        UpcomingItemVm(
          kind: UpcomingKind.moon,
          at: at(23, 9),
          moonIlluminationPct: 44,
        ),
        UpcomingItemVm(
          kind: UpcomingKind.meridianFlip,
          at: at(1, 58),
          tone: MetricTone.warning,
        ),
        UpcomingItemVm(kind: UpcomingKind.astroDawn, at: at(5, 44)),
      ];

  // -- Center column --------------------------------------------------------

  static const List<double> _stripHfr = <double>[
    2.21, 2.18, 2.40, 2.16, 2.14, 3.05, //
    2.12, 2.15, 2.11, 2.13, 2.10, 2.13,
  ];

  /// #32 to #43; #37 (HFR 3.05) was rejected, #43 is the newest.
  static List<StripFrameVm> strip() => <StripFrameVm>[
        for (var i = 0; i < _stripHfr.length; i++)
          StripFrameVm(
            id: 1000 + 32 + i,
            frameNumber: 32 + i,
            capturedAt: at(23, 49, 12)
                .subtract(Duration(minutes: 3 * (_stripHfr.length - 1 - i))),
            filter: 'Ha',
            exposureSecs: 180,
            hfr: _stripHfr[i],
            starCount: _stripHfr[i] > 3 ? 412 : 1150 + i * 3,
            accepted: _stripHfr[i] <= 3,
            isNewest: i == _stripHfr.length - 1,
          ),
      ];

  /// 87 frames from 20:01, one every 160 s, with the two autofocus runs and
  /// one rejected frame.
  static NightSeriesVm frameSeries() {
    final start = at(20, 1);
    final hfr = <SeriesPoint>[];
    final stars = <SeriesPoint>[];
    for (var i = 0; i < 87; i++) {
      final t = start.add(Duration(seconds: 160 * i));
      final rejected = i == 80;
      hfr.add(
        SeriesPoint(
          t,
          rejected ? 3.05 : 2.1 + 0.08 * math.sin(i / 5) + (i % 30) * 0.004,
          accepted: !rejected,
        ),
      );
      stars.add(
        SeriesPoint(
          t,
          rejected ? 412 : 1150 + 40 * math.cos(i / 6),
          accepted: !rejected,
        ),
      );
    }
    return NightSeriesVm(
      lines: <SeriesLineVm>[
        SeriesLineVm(
            id: NightSeriesId.hfr, points: hfr, tone: SeriesTone.primary),
        SeriesLineVm(
          id: NightSeriesId.stars,
          points: stars,
          tone: SeriesTone.secondary,
          secondaryAxis: true,
        ),
      ],
      markers: <SeriesMarker>[
        SeriesMarker(at(21, 40), SeriesMarkerKind.autofocus),
        SeriesMarker(at(23, 10), SeriesMarkerKind.autofocus),
        SeriesMarker(hfr[80].t, SeriesMarkerKind.reject),
      ],
      from: start,
      to: at(23, 52),
      legend: <MetricVm>[
        MetricVm(label: _t('HFR'), value: '2.13 (min 1.98)'),
        MetricVm(label: _t('stars'), value: '1184'),
      ],
      sampleCount: 87,
    );
  }

  /// The last ten minutes of guiding in pixels, one dither at minute six.
  static NightSeriesVm guideSeries() {
    final end = at(23, 52);
    final start = end.subtract(const Duration(minutes: 10));
    final ra = <SeriesPoint>[];
    final dec = <SeriesPoint>[];
    for (var s = 0; s <= 600; s += 2) {
      final t = start.add(Duration(seconds: s));
      final kick = (s >= 360 && s < 372) ? 0.9 : 0.0;
      ra.add(SeriesPoint(t, 0.22 * math.sin(s / 7) + kick));
      dec.add(SeriesPoint(t, 0.2 * math.cos(s / 9) - kick));
    }
    return NightSeriesVm(
      lines: <SeriesLineVm>[
        SeriesLineVm(
            id: NightSeriesId.guideRa, points: ra, tone: SeriesTone.primary),
        SeriesLineVm(
          id: NightSeriesId.guideDec,
          points: dec,
          tone: SeriesTone.tertiary,
        ),
      ],
      markers: <SeriesMarker>[
        SeriesMarker(
            start.add(const Duration(minutes: 6)), SeriesMarkerKind.dither),
      ],
      from: start,
      to: end,
      legend: <MetricVm>[
        MetricVm(label: _t('RA'), value: '0.31″'),
        MetricVm(label: _t('Dec'), value: '0.28″'),
        MetricVm(label: _t('total'), value: '0.42″'),
        MetricVm(label: _t('SNR'), value: '42'),
      ],
    );
  }

  /// Focuser temperature stands in for ambient (labeled as such), the
  /// focuser position steps in after each autofocus, the sensor holds −10.
  static NightSeriesVm temperatureSeries() {
    final start = at(19, 48);
    final focuserTemp = <SeriesPoint>[];
    final position = <SeriesPoint>[];
    final sensor = <SeriesPoint>[];
    for (var m = 0; m <= 244; m += 4) {
      final t = start.add(Duration(minutes: m));
      focuserTemp.add(SeriesPoint(t, 16 - 4 * m / 244));
      position.add(
        SeriesPoint(
          t,
          // Unknown until the first autofocus at 19:57, then each run's
          // result: 45 610, 45 502 (21:40), 45 484 (23:10).
          m < 9
              ? null
              : m < 112
                  ? 45610
                  : m < 202
                      ? 45502
                      : 45484,
        ),
      );
      sensor.add(SeriesPoint(t, -10));
    }
    return NightSeriesVm(
      lines: <SeriesLineVm>[
        SeriesLineVm(
          id: NightSeriesId.focuserTemp,
          points: focuserTemp,
          tone: SeriesTone.muted,
        ),
        SeriesLineVm(
          id: NightSeriesId.focuserPosition,
          points: position,
          tone: SeriesTone.primary,
          secondaryAxis: true,
          stepped: true,
        ),
        SeriesLineVm(
          id: NightSeriesId.sensorTemp,
          points: sensor,
          tone: SeriesTone.secondary,
          dashed: true,
        ),
      ],
      from: start,
      to: at(23, 52),
      legend: <MetricVm>[
        MetricVm(label: _t('focuser'), value: '12.0 °C'),
        MetricVm(label: _t('position'), value: '45 484'),
        MetricVm(label: _t('sensor'), value: '−10.0 °C'),
      ],
    );
  }

  // -- Right panel ----------------------------------------------------------

  static NightLastFrameVm lastFrame() => NightLastFrameVm(
        frameNumber: 43,
        metrics: <MetricVm>[
          MetricVm(
            label: _t('HFR'),
            value: '2.13',
            delta: '−0.04',
            deltaTone: MetricTone.good,
          ),
          MetricVm(
            label: _t('FWHM'),
            value: '3.4″',
            delta: '−0.1',
            deltaTone: MetricTone.good,
          ),
          MetricVm(label: _t('Ecc'), value: '0.31', delta: '+0.02'),
          MetricVm(
            label: _t('Stars'),
            value: '1184',
            delta: '+36',
            deltaTone: MetricTone.good,
          ),
          MetricVm(label: _t('Median'), value: '528', delta: '+4'),
          MetricVm(
            label: _t('Bg σ'),
            value: '11.2',
            delta: '−0.3',
            deltaTone: MetricTone.good,
          ),
          MetricVm(
            label: _t('SNR'),
            value: '38.6',
            delta: '+1.2',
            deltaTone: MetricTone.good,
          ),
          MetricVm(label: _t('Solve'), value: '0.8″', delta: 'off'),
        ],
        histogram: <int>[
          for (var i = 0; i < 256; i++)
            (4000 * math.exp(-math.pow(i - 30, 2) / 40)).round(),
        ],
      );

  static NightSessionVm session() => NightSessionVm(
        frameCount: 87,
        elapsed: const Duration(hours: 4, minutes: 21),
        metrics: <MetricVm>[
          MetricVm(label: _t('Accepted'), value: '84'),
          MetricVm(
            label: _t('Rejected'),
            value: '3',
            valueTone: MetricTone.bad,
          ),
          MetricVm(label: _t('Integration'), value: '4h12'),
          MetricVm(label: _t('Remaining'), value: '1h50'),
          MetricVm(label: _t('Autofocus'), value: '3 runs'),
          MetricVm(label: _t('Dithers'), value: '28'),
          MetricVm(label: _t('Disk'), value: '639 GB'),
          MetricVm(label: _t('Dropouts'), value: '0'),
        ],
      );

  static List<EquipmentRowVm> equipment() => <EquipmentRowVm>[
        EquipmentRowVm(
          kind: EquipmentKind.camera,
          status: EquipmentStatus.ok,
          deviceName: 'ZWO ASI1600MM Pro',
          details: <NightText>[
            _t('−10.0 °C'),
            _t('20%'),
            _t('g139 o21'),
            _t('1×1'),
          ],
        ),
        EquipmentRowVm(
          kind: EquipmentKind.filterWheel,
          status: EquipmentStatus.ok,
          deviceName: 'ZWO EFW',
          details: <NightText>[_t('Ha (5 of 8)'), _t('offset +40')],
        ),
        EquipmentRowVm(
          kind: EquipmentKind.focuser,
          status: EquipmentStatus.ok,
          deviceName: 'ZWO EAF',
          details: <NightText>[_t('45 484'), _t('12.0 °C'), _t('TC on')],
        ),
        EquipmentRowVm(
          kind: EquipmentKind.mount,
          status: EquipmentStatus.ok,
          deviceName: 'EQ6-R',
          details: <NightText>[_t('tracking'), _t('pier W'), _t('alt 62.8°')],
        ),
        EquipmentRowVm(
          kind: EquipmentKind.guider,
          status: EquipmentStatus.ok,
          deviceName: 'PHD2',
          details: <NightText>[_t('guiding'), _t('mass 8.2k')],
        ),
        const EquipmentRowVm(
          kind: EquipmentKind.rotator,
          status: EquipmentStatus.absent,
        ),
      ];

  static List<EquipmentRowVm> readyEquipment() => <EquipmentRowVm>[
        EquipmentRowVm(
          kind: EquipmentKind.camera,
          status: EquipmentStatus.ok,
          deviceName: 'ZWO ASI1600MM Pro',
          details: <NightText>[
            _t('−7.4 °C → −10'),
            _t('64%'),
            _t('g139 o21'),
          ],
        ),
        EquipmentRowVm(
          kind: EquipmentKind.filterWheel,
          status: EquipmentStatus.ok,
          deviceName: 'ZWO EFW',
          details: <NightText>[_t('L (1 of 8)')],
        ),
        EquipmentRowVm(
          kind: EquipmentKind.focuser,
          status: EquipmentStatus.ok,
          deviceName: 'ZWO EAF',
          details: <NightText>[_t('45 484'), _t('12.0 °C'), _t('TC on')],
        ),
        EquipmentRowVm(
          kind: EquipmentKind.mount,
          status: EquipmentStatus.ok,
          deviceName: 'EQ6-R',
          details: <NightText>[_t('idle'), _t('not tracking'), _t('pier W')],
        ),
        EquipmentRowVm(
          kind: EquipmentKind.guider,
          status: EquipmentStatus.attention,
          deviceName: 'PHD2',
          details: <NightText>[_t('connected'), _t('not looping')],
        ),
        const EquipmentRowVm(
          kind: EquipmentKind.rotator,
          status: EquipmentStatus.absent,
        ),
      ];

  /// A weather device is connected on the running board. Seeing is left out:
  /// no source in the app reports it.
  static NightConditionsVm conditions() => NightConditionsVm(
        source: ConditionsSource.device,
        safe: true,
        metrics: <MetricVm>[
          MetricVm(label: _t('Clouds'), value: '0%'),
          MetricVm(label: _t('Humidity'), value: '71%'),
          MetricVm(label: _t('Dew point'), value: '4.1 °C'),
          MetricVm(label: _t('Wind'), value: '6 km/h'),
          MetricVm(label: _t('SQM'), value: '19.4'),
          MetricVm(label: _t('Moon'), value: 'set 23:09'),
          MetricVm(label: _t('Ambient'), value: '12.0 °C'),
        ],
      );

  static List<NightLogEntryVm> log() => <NightLogEntryVm>[
        NightLogEntryVm(
          at: at(23, 49),
          message: _t('#43 Ha accepted · HFR 2.13'),
        ),
        NightLogEntryVm(
          at: at(23, 46),
          message: _t('#42 Ha accepted · HFR 2.10'),
        ),
        NightLogEntryVm(
          at: at(23, 43),
          message: _t('Dither 1.5 px · settled 9 s'),
        ),
        NightLogEntryVm(
          at: at(23, 40),
          message: _t('#41 Ha rejected · HFR 3.05'),
          tone: MetricTone.bad,
        ),
        NightLogEntryVm(
          at: at(23, 10),
          message: _t('Autofocus 45 484 · HFR 1.98 · 2 m 40 s'),
        ),
        NightLogEntryVm(at: at(23, 9), message: _t('Moon set')),
        NightLogEntryVm(
          at: at(22, 58),
          message: _t('Guide star lost 4 s · recovered'),
          tone: MetricTone.warning,
        ),
        NightLogEntryVm(
          at: at(21, 40),
          message: _t('Autofocus 45 502 · HFR 2.02'),
        ),
      ];

  static List<NightLogEntryVm> readyLog() => <NightLogEntryVm>[
        NightLogEntryVm(
          at: at(18, 31),
          message: _t('Snapshot L 5 s · solved 0.4′ from M74'),
        ),
        NightLogEntryVm(
          at: at(18, 29),
          message: _t('Slew to M74 · settled 3 s'),
        ),
        NightLogEntryVm(
          at: at(18, 22),
          message: _t('Cooler on · target −10 °C'),
        ),
        NightLogEntryVm(at: at(18, 21), message: _t('PHD2 connected')),
        NightLogEntryVm(
          at: at(18, 21),
          message: _t('Mount, camera, focuser, filter wheel connected'),
        ),
        NightLogEntryVm(at: at(18, 20), message: _t('Profile 10″ Newt loaded')),
      ];

  static List<ChecklistItemVm> beforeYouStart() => <ChecklistItemVm>[
        ChecklistItemVm(
          id: ChecklistItemId.camera,
          state: ChecklistItemState.ok,
          title: _t('Camera'),
          detail: _t('connected · cooling −7.4 → −10 °C'),
        ),
        ChecklistItemVm(
          id: ChecklistItemId.filterWheel,
          state: ChecklistItemState.ok,
          title: _t('Filter'),
          detail: _t('EFW · 8 slots · L'),
        ),
        ChecklistItemVm(
          id: ChecklistItemId.focuser,
          state: ChecklistItemState.ok,
          title: _t('Focuser'),
          detail: _t('45 484 · plan autofocuses first'),
        ),
        ChecklistItemVm(
          id: ChecklistItemId.mount,
          state: ChecklistItemState.ok,
          title: _t('Mount'),
          detail: _t('unparked · not tracking · pier W'),
        ),
        ChecklistItemVm(
          id: ChecklistItemId.guider,
          state: ChecklistItemState.attention,
          title: _t('Guider'),
          detail: _t('PHD2 connected, not looping'),
          actionLabel: _t('Loop'),
        ),
        ChecklistItemVm(
          id: ChecklistItemId.solver,
          state: ChecklistItemState.ok,
          title: _t('Solver'),
          detail: _t('ASTAP · D50 · last solve 0.4′ off'),
        ),
        ChecklistItemVm(
          id: ChecklistItemId.disk,
          state: ChecklistItemState.ok,
          title: _t('Disk'),
          detail: _t('639 GB free · plan needs 2.6 GB'),
        ),
        ChecklistItemVm(
          id: ChecklistItemId.weather,
          state: ChecklistItemState.attention,
          title: _t('Weather'),
          detail: _t('no source · safety cannot react'),
          actionLabel: _t('Add'),
          route: '/settings/weather',
        ),
        ChecklistItemVm(
          id: ChecklistItemId.dawn,
          state: ChecklistItemState.ok,
          title: _t('Dawn'),
          detail: _t('park at 05:14 if still running'),
        ),
      ];

  // -- Action bar -----------------------------------------------------------

  static ManualActionVm _action(
    ManualActionId id,
    String label, {
    String? sub,
    String? disabledReason,
    bool running = false,
  }) =>
      ManualActionVm(
        id: id,
        label: _t(label),
        sub: sub == null ? null : _t(sub),
        enabled: disabledReason == null,
        disabledReason: disabledReason == null ? null : _t(disabledReason),
        running: running,
      );

  /// Flip now is disabled during a run (plan section 3, P2): the board drew
  /// it enabled, the contract does not.
  static List<ManualActionVm> runningActions() => <ManualActionVm>[
        _action(ManualActionId.snapshot, 'Snapshot', sub: '5 s'),
        _action(ManualActionId.loop, 'Loop'),
        _action(ManualActionId.autofocus, 'Autofocus', sub: 'Ha'),
        _action(ManualActionId.solveSync, 'Solve & sync'),
        _action(ManualActionId.center, 'Center', sub: 'M74'),
        _action(ManualActionId.dither, 'Dither'),
        _action(
          ManualActionId.flip,
          'Flip now',
          disabledReason: "The run's meridian trigger owns flips",
        ),
      ];

  static List<ManualActionVm> readyActions() => <ManualActionVm>[
        _action(ManualActionId.snapshot, 'Snapshot', sub: '5 s'),
        _action(ManualActionId.loop, 'Loop'),
        _action(ManualActionId.autofocus, 'Autofocus', sub: 'L'),
        _action(ManualActionId.solveSync, 'Solve & sync'),
        _action(ManualActionId.center, 'Center', sub: 'M74'),
        _action(ManualActionId.tracking, 'Track', sub: 'sidereal'),
        _action(ManualActionId.cooler, 'Cooler', sub: '−10 °C'),
      ];

  static List<ManualActionVm> autofocusActions() {
    const busy = 'Autofocus is running';
    return <ManualActionVm>[
      _action(ManualActionId.snapshot, 'Snapshot',
          sub: '5 s', disabledReason: busy),
      _action(ManualActionId.loop, 'Loop', disabledReason: busy),
      _action(
        ManualActionId.autofocus,
        'Autofocus',
        sub: 'running',
        running: true,
      ),
      _action(ManualActionId.solveSync, 'Solve & sync', disabledReason: busy),
      _action(ManualActionId.center, 'Center',
          sub: 'M74', disabledReason: busy),
      _action(ManualActionId.dither, 'Dither', disabledReason: busy),
      _action(
        ManualActionId.flip,
        'Flip now',
        disabledReason: "The run's meridian trigger owns flips",
      ),
    ];
  }
}
