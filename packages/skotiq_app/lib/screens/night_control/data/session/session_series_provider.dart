// The session charts: HFR · stars, temperature · focus, and the cooler.
//
// Per-frame values come from the session's captured_images rows, so the
// charts cover the whole session even after a restart. The sensor line uses
// the camera poller's twelve-hour cooler history when there is one (a point
// a minute, from before the first frame), and the per-frame sensor reading
// otherwise. There is no ambient series: a weather device reports only its
// current value, so the chart leaves ambient out rather than invent a line.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../night_control_contracts.dart';
import 'session_events_provider.dart';
import 'session_format.dart';
import 'session_frames_provider.dart';

/// The x range of the session charts: from the session start (or the first
/// frame) to now while the session runs, or to the last frame after it.
final nightSessionRangeProvider = Provider<({DateTime from, DateTime to})?>((
  ref,
) {
  final rows = ref.watch(nightSessionLightRowsProvider);
  final session = ref.watch(sessionStateProvider);
  final start = session.isActive ? session.startTime : null;
  final from = start ?? (rows.isEmpty ? null : rows.first.capturedAt);
  if (from == null) return null;
  final to = session.isActive
      ? ref.watch(nightSessionNowProvider)
      : (rows.isEmpty ? from : rows.last.capturedAt);
  return (from: from, to: to.isBefore(from) ? from : to);
});

/// HFR and star count per light frame, autofocus, flip and reject marks.
final nightFrameSeriesProvider = Provider<NightSeriesVm>((ref) {
  final rows = ref.watch(nightSessionLightRowsProvider);
  final range = ref.watch(nightSessionRangeProvider);
  final events = ref.watch(nightSessionEventsProvider);

  final hfr = <SeriesPoint>[];
  final stars = <SeriesPoint>[];
  final rejects = <SeriesMarker>[];
  for (final row in rows) {
    final accepted = row.isAccepted;
    hfr.add(SeriesPoint(row.capturedAt, row.hfr, accepted: accepted));
    stars.add(
      SeriesPoint(
        row.capturedAt,
        row.starCount?.toDouble(),
        accepted: accepted,
      ),
    );
    if (!accepted) {
      rejects.add(SeriesMarker(row.capturedAt, SeriesMarkerKind.reject));
    }
  }

  final markers = <SeriesMarker>[
    for (final marker in events.markers)
      if (marker.kind != SeriesMarkerKind.dither &&
          (range == null ||
              (!marker.t.isBefore(range.from) && !marker.t.isAfter(range.to))))
        marker,
    ...rejects,
  ]..sort((a, b) => a.t.compareTo(b.t));

  DbCapturedImage? lastWith(bool Function(DbCapturedImage row) has) {
    for (var i = rows.length - 1; i >= 0; i--) {
      if (rows[i].isAccepted && has(rows[i])) return rows[i];
    }
    return null;
  }

  final lastHfr = lastWith((row) => row.hfr != null)?.hfr;
  final lastStars = lastWith((row) => row.starCount != null)?.starCount;
  double? minHfr;
  for (final row in rows) {
    final value = row.hfr;
    if (!row.isAccepted || value == null) continue;
    if (minHfr == null || value < minHfr) minHfr = value;
  }

  return NightSeriesVm(
    lines: <SeriesLineVm>[
      SeriesLineVm(
        id: NightSeriesId.hfr,
        points: hfr,
        tone: SeriesTone.primary,
      ),
      SeriesLineVm(
        id: NightSeriesId.stars,
        points: stars,
        tone: SeriesTone.secondary,
        secondaryAxis: true,
      ),
    ],
    markers: markers,
    from: range?.from,
    to: range?.to,
    legend: <MetricVm>[
      if (lastHfr != null)
        MetricVm(
          label: const NightText('nightSessionHfr'),
          value: nightFixed(lastHfr, 2),
        ),
      if (minHfr != null)
        MetricVm(
          label: const NightText('nightSessionHfrMin'),
          value: nightFixed(minHfr, 2),
        ),
      if (lastStars != null)
        MetricVm(
          label: const NightText('nightSessionStars'),
          value: '$lastStars',
        ),
    ],
    sampleCount: rows.isEmpty ? null : rows.length,
  );
});

/// Focuser temperature, focuser position (stepped, right axis) and sensor
/// temperature over the session.
final nightTemperatureSeriesProvider = Provider<NightSeriesVm>((ref) {
  final rows = ref.watch(nightSessionLightRowsProvider);
  final range = ref.watch(nightSessionRangeProvider);
  final cooler = ref.watch(temperatureLongHistoryProvider);

  final focuserTemp = <SeriesPoint>[
    for (final row in rows) SeriesPoint(row.capturedAt, row.focuserTemp),
  ];
  final position = <SeriesPoint>[
    for (final row in rows)
      SeriesPoint(row.capturedAt, row.focuserPosition?.toDouble()),
  ];
  final coolerInRange = <TemperaturePoint>[
    for (final point in cooler)
      if (range != null &&
          !point.time.isBefore(range.from) &&
          !point.time.isAfter(range.to))
        point,
  ];
  final sensor = coolerInRange.isNotEmpty
      ? <SeriesPoint>[
          for (final point in coolerInRange)
            SeriesPoint(point.time, point.temperature),
        ]
      : <SeriesPoint>[
          for (final row in rows) SeriesPoint(row.capturedAt, row.sensorTemp),
        ];

  double? latest(List<SeriesPoint> points) {
    for (var i = points.length - 1; i >= 0; i--) {
      final y = points[i].y;
      if (y != null) return y;
    }
    return null;
  }

  final lastFocuserTemp = latest(focuserTemp);
  final lastPosition = latest(position);
  final lastSensor = latest(sensor);

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
    from: range?.from,
    to: range?.to,
    legend: <MetricVm>[
      if (lastFocuserTemp != null)
        MetricVm(
          label: const NightText('nightSessionFocuserTemp'),
          value: nightCelsius(lastFocuserTemp),
        ),
      if (lastPosition != null)
        MetricVm(
          label: const NightText('nightSessionFocuserPosition'),
          value: nightGrouped(lastPosition.round()),
        ),
      if (lastSensor != null)
        MetricVm(
          label: const NightText('nightSessionSensorTemp'),
          value: nightCelsius(lastSensor),
        ),
    ],
    sampleCount: rows.isEmpty ? null : rows.length,
  );
});

/// The Camera tab's cooler graph: up to twelve hours of sensor readings, one
/// a minute. [NightSeriesVm.from] is the oldest reading, for "since 19:20".
/// The legend carries the latest setpoint and cooler power when the camera
/// reported them.
final nightCoolerHistoryProvider = Provider<NightSeriesVm>((ref) {
  final history = ref.watch(temperatureLongHistoryProvider);
  if (history.isEmpty) {
    return const NightSeriesVm(
      lines: <SeriesLineVm>[
        SeriesLineVm(
          id: NightSeriesId.sensorTemp,
          points: <SeriesPoint>[],
          tone: SeriesTone.secondary,
        ),
      ],
    );
  }
  final last = history.last;
  return NightSeriesVm(
    lines: <SeriesLineVm>[
      SeriesLineVm(
        id: NightSeriesId.sensorTemp,
        points: <SeriesPoint>[
          for (final point in history)
            SeriesPoint(point.time, point.temperature),
        ],
        tone: SeriesTone.secondary,
      ),
    ],
    from: history.first.time,
    to: last.time,
    legend: <MetricVm>[
      MetricVm(
        label: const NightText('nightSessionSensorTemp'),
        value: nightCelsius(last.temperature),
      ),
      if (last.targetTemp != null)
        MetricVm(
          label: const NightText('nightSessionSetpoint'),
          value: nightCelsius(last.targetTemp!),
        ),
      if (last.coolerPower != null)
        MetricVm(
          label: const NightText('nightSessionCoolerPower'),
          value: '${last.coolerPower!.round()}%',
        ),
    ],
    sampleCount: history.length,
  );
});
