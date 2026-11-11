// The night so far, from the imaging host.
//
// Tonight's guide chart, its autofocus, dither and flip marks, the Solve
// tab's recent solves and the cooler history are gathered from live events by whichever app shows
// them, so a client that connected after the run started (or restarted
// during it) showed "No guide data yet" and "No autofocus run yet" while the
// host showed the night's. The host serves what it gathered
// (`GET /api/runtime/night-history`); a client adds the part from before it
// connected and keeps its own live events from then on.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../panel/solve/recent_solves_provider.dart';
import 'guide_series_provider.dart';
import 'session_events_provider.dart';

/// What a host's Tonight gathered tonight, as `GET /api/runtime/night-history`
/// serves it. Times are milliseconds since the epoch.
Map<String, dynamic> encodeNightHistory({
  required List<NightGuideSample> guideSamples,
  required NightSessionEvents events,
  required List<NightSolveRecord> solves,
  List<TemperaturePoint> cooler = const <TemperaturePoint>[],
}) {
  double? finite(double? v) => v == null || !v.isFinite ? null : v;
  int ms(DateTime t) => t.millisecondsSinceEpoch;
  return {
    // [t, ra, dec] rows keep a night of guide steps small.
    'guideSamples': [
      for (final s in guideSamples)
        if (s.raPx.isFinite && s.decPx.isFinite) [ms(s.t), s.raPx, s.decPx],
    ],
    'autofocusRuns': [
      for (final run in events.autofocusRuns)
        {
          'at': ms(run.at),
          'position': run.position,
          'hfr': finite(run.hfr),
          'durationMs': run.duration?.inMilliseconds,
        },
    ],
    'dithers': [
      for (final d in events.dithers)
        {'at': ms(d.at), 'pixels': finite(d.pixels)},
    ],
    'flips': [for (final t in events.flips) ms(t)],
    'starLost': [for (final t in events.starLost) ms(t)],
    // [t, sensor, setpoint, power] rows, one a minute.
    'cooler': [
      for (final p in cooler)
        if (p.temperature.isFinite)
          [
            ms(p.time),
            p.temperature,
            finite(p.targetTemp),
            finite(p.coolerPower),
          ],
    ],
    'solves': [
      for (final s in solves)
        {
          'at': ms(s.at),
          'kind': s.kind.name,
          'success': s.success,
          'raDegrees': finite(s.raDegrees),
          'decDegrees': finite(s.decDegrees),
          'offsetArcsec': finite(s.offsetArcsec),
          'iterations': s.iterations,
          'durationMs': s.duration?.inMilliseconds,
        },
    ],
  };
}

/// [encodeNightHistory]'s payload, read back. Entries that do not parse are
/// left out rather than drawn with invented values.
class NightHistory {
  const NightHistory({
    this.guideSamples = const <NightGuideSample>[],
    this.events = const NightSessionEvents(),
    this.solves = const <NightSolveRecord>[],
    this.cooler = const <TemperaturePoint>[],
  });

  factory NightHistory.fromJson(Map<String, dynamic> json) {
    DateTime? at(Object? v) =>
        v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
    double? number(Object? v) => v is num ? v.toDouble() : null;
    Duration? duration(Object? v) =>
        v is num ? Duration(milliseconds: v.toInt()) : null;
    List<Map<Object?, Object?>> maps(String key) => [
          for (final item in json[key] is List ? json[key] as List : const [])
            if (item is Map) item,
        ];
    List<DateTime> times(String key) => [
          for (final item in json[key] is List ? json[key] as List : const [])
            if (at(item) case final DateTime t) t,
        ];

    final samples = <NightGuideSample>[];
    final rawSamples = json['guideSamples'];
    if (rawSamples is List) {
      for (final row in rawSamples) {
        if (row is! List || row.length != 3) continue;
        final t = at(row[0]);
        final ra = number(row[1]);
        final dec = number(row[2]);
        if (t == null || ra == null || dec == null) continue;
        samples.add(NightGuideSample(t, ra, dec));
      }
    }

    final cooler = <TemperaturePoint>[];
    final rawCooler = json['cooler'];
    if (rawCooler is List) {
      for (final row in rawCooler) {
        if (row is! List || row.length != 4) continue;
        final t = at(row[0]);
        final temperature = number(row[1]);
        if (t == null || temperature == null) continue;
        cooler.add(
          TemperaturePoint(
            temperature: temperature,
            targetTemp: number(row[2]),
            coolerPower: number(row[3]),
            time: t,
          ),
        );
      }
    }

    return NightHistory(
      guideSamples: samples,
      cooler: cooler,
      events: NightSessionEvents(
        autofocusRuns: [
          for (final run in maps('autofocusRuns'))
            if (at(run['at']) case final DateTime t)
              NightAutofocusRun(
                at: t,
                position: (run['position'] as num?)?.toInt(),
                hfr: number(run['hfr']),
                duration: duration(run['durationMs']),
              ),
        ],
        dithers: [
          for (final d in maps('dithers'))
            if (at(d['at']) case final DateTime t)
              NightDither(at: t, pixels: number(d['pixels'])),
        ],
        flips: times('flips'),
        starLost: times('starLost'),
      ),
      solves: [
        for (final s in maps('solves'))
          if ((at(s['at']), NightSolveKind.values.asNameMap()[s['kind']])
              case (final DateTime t, final NightSolveKind kind))
            NightSolveRecord(
              at: t.toUtc(),
              kind: kind,
              success: s['success'] == true,
              raDegrees: number(s['raDegrees']),
              decDegrees: number(s['decDegrees']),
              offsetArcsec: number(s['offsetArcsec']),
              iterations: (s['iterations'] as num?)?.toInt(),
              duration: duration(s['durationMs']),
            ),
      ],
    );
  }

  final List<NightGuideSample> guideSamples;
  final NightSessionEvents events;

  /// Newest first, as the Solve tab lists them.
  final List<NightSolveRecord> solves;

  /// The camera's cooler readings, one a minute, oldest first.
  final List<TemperaturePoint> cooler;
}

/// The host's night so far, read once per link to a host; null on the host
/// itself, from a host that predates the endpoint, or when the read failed
/// (the charts then start from the first live event, as before).
final hostNightHistoryProvider = FutureProvider<NightHistory?>((ref) async {
  final backend = ref.watch(backendProvider);
  final linkedHost = backend.remoteHost;
  if (linkedHost == null) return null;
  try {
    final json = await linkedHost.night.getHostNightHistory();
    if (json == null) return null;
    final history = NightHistory.fromJson(json);
    // The cooler history lives in the camera poller, which every screen
    // shares; it takes the host's readings here rather than in a notifier of
    // its own.
    ref.read(temperatureHistoryProvider.notifier).addEarlier(history.cooler);
    return history;
  } on Object catch (e) {
    ref.read(loggingServiceProvider).debug(
          'Night history not read from the host: $e',
          source: 'NightHistory',
        );
    return null;
  }
});

/// The part of [host] (oldest first) from before [local]'s first entry: the
/// host's list holds the live entries this app already has as well.
List<T> nightHistoryBefore<T>(
  List<T> host,
  List<T> local,
  DateTime Function(T) timeOf,
) {
  if (local.isEmpty) return host;
  final first = timeOf(local.first);
  return [
    for (final item in host)
      if (timeOf(item).isBefore(first)) item,
  ];
}
