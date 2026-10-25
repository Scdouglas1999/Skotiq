/// What the Targets tab shows about each imaged target: its nights sub by
/// sub, its masters and what is new since them.
///
/// Pure derivations over database rows, so the rules are tested without a
/// widget tree.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:skotiq_core/skotiq_core.dart';

/// A sub further than this from the target's catalog position, by the
/// mount's reported pointing, is drawn as off target. Guided tracking lets the
/// reported pointing wander a few arcminutes on a good night, so the limit
/// sits well above that.
const double darkroomOffTargetArcmin = 15;

/// A gap between subs longer than this many typical cadences, and at least
/// [darkroomPauseMinimum], is drawn as a pause.
const double darkroomPauseCadences = 3;
const Duration darkroomPauseMinimum = Duration(minutes: 10);

/// Consecutive rejected subs that lost their stars before the run is marked.
const int darkroomStarLossRun = 3;

/// Filters in the order the Darkroom lists them; others follow by name.
const List<String> darkroomFilterOrder = [
  'L',
  'R',
  'G',
  'B',
  'Ha',
  'OIII',
  'SII',
];

int compareDarkroomFilters(String a, String b) {
  int rank(String f) {
    final i = darkroomFilterOrder.indexWhere(
      (o) => o.toLowerCase() == f.toLowerCase(),
    );
    return i < 0 ? darkroomFilterOrder.length : i;
  }

  final byRank = rank(a).compareTo(rank(b));
  return byRank != 0 ? byRank : a.compareTo(b);
}

/// The filter a light was taken through, as the build service names it.
String darkroomFilterOf(DbCapturedImage f) =>
    f.filter?.trim().isNotEmpty == true ? f.filter!.trim() : 'NoFilter';

/// Letters and digits only, upper case: `NGC 891`, `ngc0891` and `NGC_891`
/// stay distinct only where their characters differ.
String normalizeDarkroomTargetName(String name) =>
    name.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// One sub on the nights strip.
class DarkroomSub {
  const DarkroomSub({
    required this.imageId,
    required this.time,
    required this.filter,
    required this.exposureSeconds,
    required this.kept,
    required this.offTarget,
    this.side,
    this.reason,
  });

  final int imageId;
  final DateTime time;
  final String filter;
  final double exposureSeconds;

  /// Accepted at capture and not since rejected.
  final bool kept;

  /// Pointing was further than [darkroomOffTargetArcmin] from the target.
  final bool offTarget;
  final String? side;
  final String? reason;

  bool get lostStars {
    final r = reason?.toLowerCase() ?? '';
    return !kept && (r.contains('star count') || r.contains('no stars'));
  }
}

/// A stretch of a night with no subs.
class DarkroomPause {
  const DarkroomPause(this.start, this.end);
  final DateTime start;
  final DateTime end;
}

/// A labeled moment on a night: a meridian flip, or where the stars went.
class DarkroomNightMark {
  const DarkroomNightMark(this.at, this.label);
  final DateTime at;
  final String label;
}

/// How much of a night the current masters already hold.
enum DarkroomNightUse { none, partly, all }

/// One observing night of one target, noon to noon.
class DarkroomNight {
  const DarkroomNight({
    required this.key,
    required this.evening,
    required this.subs,
    required this.pauses,
    required this.marks,
    required this.use,
    this.inMasters = 0,
    this.used = 0,
  });

  /// The evening date, `yyyy-mm-dd`, as `observingNight` writes it.
  final String key;

  /// Local midnight at the start of the evening date.
  final DateTime evening;

  /// Every light of the night, oldest first.
  final List<DarkroomSub> subs;
  final List<DarkroomPause> pauses;
  final List<DarkroomNightMark> marks;
  final DarkroomNightUse use;

  /// Kept subs a build of the current masters was given.
  final int inMasters;

  /// Kept subs the current masters were integrated from; a build can skip a
  /// sub it was given.
  final int used;

  int get kept => subs.where((s) => s.kept).length;
  int get offTarget => subs.where((s) => s.offTarget).length;
  int get rejected => subs.where((s) => !s.kept).length;
  DateTime get first => subs.first.time;
  DateTime get last => subs.last.time;
  double get keptSeconds => subs
      .where((s) => s.kept)
      .fold<double>(0, (sum, s) => sum + s.exposureSeconds);

  /// Filters taken this night, in Darkroom order.
  List<String> get filters =>
      {for (final s in subs) s.filter}.toList()..sort(compareDarkroomFilters);

  /// A night with kept subs and none of them in the current masters.
  bool get isNew => kept > 0 && use == DarkroomNightUse.none;

  /// Kept subs the current masters do not hold.
  int get notInMasters => kept - inMasters;

  /// The one thing worth knowing about how the night went.
  String get note {
    final flip = marks.where((m) => m.label == 'flip').firstOrNull;
    if (flip != null) return 'Flip at ${hhmm(flip.at)}';
    final lost = marks.where((m) => m.label != 'flip').firstOrNull;
    if (lost != null) return 'Stars lost ${hhmm(lost.at)}';
    return 'Ended ${hhmm(last)}';
  }
}

/// A filter of a target: its newest master, and the light captured for it.
class DarkroomChannel {
  const DarkroomChannel({
    required this.filter,
    required this.keptSubs,
    required this.keptSeconds,
    this.master,
  });

  final String filter;
  final IntegratedMaster? master;
  final int keptSubs;
  final double keptSeconds;
}

/// Everything the Targets tab knows about one target.
class DarkroomTarget {
  const DarkroomTarget({
    required this.key,
    required this.frames,
    required this.nights,
    required this.masters,
    required this.channels,
    this.row,
  });

  /// The name `loadDarkroomTargets` lists it under; the build plan's target.
  final String key;
  final DbTarget? row;

  /// Every light, any night, any grade.
  final List<DbCapturedImage> frames;

  /// Newest night first.
  final List<DarkroomNight> nights;

  /// This target's registered images, newest first.
  final List<IntegratedMaster> masters;

  /// One per filter imaged or mastered, in Darkroom order.
  final List<DarkroomChannel> channels;

  /// The newest color image, when one is registered.
  IntegratedMaster? get color =>
      masters.where((m) => m.channels >= 3).firstOrNull;

  /// The image the hero card shows: the color image, else the luminance
  /// master, else the newest master.
  IntegratedMaster? get heroMaster {
    final c = color;
    if (c != null) return c;
    for (final ch in channels) {
      if (ch.filter.toUpperCase() == 'L' && ch.master != null) {
        return ch.master;
      }
    }
    return masters.firstOrNull;
  }

  /// The newest master of each filter, plus the newest color image.
  List<IntegratedMaster> get latestMasters => [
        for (final ch in channels)
          if (ch.master != null) ch.master!,
        if (color != null) color!,
      ];

  int get newNights => nights.where((n) => n.isNew).length;

  /// Kept subs from nights the masters hold only part of.
  int get newSubsInBuiltNights => nights
      .where((n) => n.use == DarkroomNightUse.partly)
      .fold(0, (sum, n) => sum + n.notInMasters);

  /// Whether anything kept is missing from the current masters.
  bool get hasNewLight => newNights > 0 || newSubsInBuiltNights > 0;
  double get keptSeconds =>
      nights.fold<double>(0, (sum, n) => sum + n.keptSeconds);
  DateTime? get lastImaged => nights.isEmpty ? null : nights.first.last;
  List<String> get filters => [for (final c in channels) c.filter];
}

String two(int v) => v.toString().padLeft(2, '0');

/// Local wall-clock time, `HH:MM`.
String hhmm(DateTime t) {
  final l = t.toLocal();
  return '${two(l.hour)}:${two(l.minute)}';
}

/// Degrees between two equatorial positions, RA in hours.
double darkroomSeparationDeg(
  double ra1Hours,
  double dec1Deg,
  double ra2Hours,
  double dec2Deg,
) {
  const rad = math.pi / 180;
  final a1 = ra1Hours * 15 * rad, d1 = dec1Deg * rad;
  final a2 = ra2Hours * 15 * rad, d2 = dec2Deg * rad;
  final cosSep = math.sin(d1) * math.sin(d2) +
      math.cos(d1) * math.cos(d2) * math.cos(a1 - a2);
  return math.acos(cosSep.clamp(-1.0, 1.0)) / rad;
}

/// The nights of [frames], newest first. [folded] holds the image ids a
/// build of the current masters was given, [used] those it integrated.
List<DarkroomNight> buildDarkroomNights(
  List<DbCapturedImage> frames, {
  Set<int> folded = const {},
  Set<int>? used,
  DbTarget? target,
}) {
  final byNight = <String, List<DbCapturedImage>>{};
  for (final f in frames) {
    byNight.putIfAbsent(observingNight(f.capturedAt), () => []).add(f);
  }
  final nights = <DarkroomNight>[];
  for (final entry in byNight.entries) {
    final list = [...entry.value]
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    final subs = [
      for (final f in list)
        DarkroomSub(
          imageId: f.id,
          time: f.capturedAt,
          filter: darkroomFilterOf(f),
          exposureSeconds: f.exposureDuration,
          kept: f.isAccepted,
          offTarget: _offTarget(f, target),
          side: _side(f.pierSide),
          reason: f.rejectionReason,
        ),
    ];
    final keptIds = [
      for (final s in subs)
        if (s.kept) s.imageId
    ];
    final inMasters = keptIds.where(folded.contains).length;
    final parts = entry.key.split('-').map(int.parse).toList();
    nights.add(
      DarkroomNight(
        key: entry.key,
        evening: DateTime(parts[0], parts[1], parts[2]),
        subs: subs,
        pauses: _pauses(subs),
        marks: _marks(subs),
        use: keptIds.isEmpty || inMasters == 0
            ? DarkroomNightUse.none
            : (inMasters == keptIds.length
                ? DarkroomNightUse.all
                : DarkroomNightUse.partly),
        inMasters: inMasters,
        used: keptIds.where((used ?? folded).contains).length,
      ),
    );
  }
  nights.sort((a, b) => b.key.compareTo(a.key));
  return nights;
}

String? _side(String? raw) {
  final s = raw?.trim().toLowerCase();
  if (s == null || s.isEmpty) return null;
  if (s.contains('east')) return 'East';
  if (s.contains('west')) return 'West';
  return null;
}

bool _offTarget(DbCapturedImage f, DbTarget? target) {
  final ra = f.mountRa, dec = f.mountDec;
  if (target == null || ra == null || dec == null) return false;
  return darkroomSeparationDeg(ra, dec, target.ra, target.dec) * 60 >
      darkroomOffTargetArcmin;
}

List<DarkroomPause> _pauses(List<DarkroomSub> subs) {
  if (subs.length < 2) return const [];
  final gaps = <Duration>[
    for (var i = 1; i < subs.length; i++)
      subs[i].time.difference(subs[i - 1].time),
  ]..sort();
  final cadence = gaps[gaps.length ~/ 2];
  final limitMs = math.max(
    (cadence.inMilliseconds * darkroomPauseCadences).round(),
    darkroomPauseMinimum.inMilliseconds,
  );
  final pauses = <DarkroomPause>[];
  for (var i = 1; i < subs.length; i++) {
    final gap = subs[i].time.difference(subs[i - 1].time);
    if (gap.inMilliseconds > limitMs) {
      final start = subs[i - 1].time.add(
            Duration(
              milliseconds: (subs[i - 1].exposureSeconds * 1000).round(),
            ),
          );
      pauses.add(DarkroomPause(start, subs[i].time));
    }
  }
  return pauses;
}

List<DarkroomNightMark> _marks(List<DarkroomSub> subs) {
  final marks = <DarkroomNightMark>[];
  String? side;
  for (final s in subs) {
    if (s.side == null) continue;
    if (side != null && s.side != side) {
      marks.add(DarkroomNightMark(s.time, 'flip'));
    }
    side = s.side;
  }
  var run = 0;
  for (var i = 0; i < subs.length; i++) {
    if (subs[i].lostStars) {
      run++;
      if (run == darkroomStarLossRun) {
        marks.add(
          DarkroomNightMark(subs[i - darkroomStarLossRun + 1].time, 'no stars'),
        );
      }
    } else {
      run = 0;
    }
  }
  marks.sort((a, b) => a.at.compareTo(b.at));
  return marks;
}

/// Whether [master] belongs to the target listed as [key] with row [row].
bool darkroomMasterBelongsTo(
  IntegratedMaster master,
  String key, {
  DbTarget? row,
  Set<int> frameIds = const {},
  Set<int> foldedIds = const {},
}) {
  if (master.targetId != null && row != null) {
    return master.targetId == row.id;
  }
  if (frameIds.isNotEmpty && foldedIds.any(frameIds.contains)) return true;
  try {
    final settings = jsonDecode(master.settingsJson);
    if (settings is Map && settings['target'] is String) {
      return settings['target'] == key;
    }
  } on FormatException {
    // Not a build plan; fall back to the name.
  }
  final name = normalizeDarkroomTargetName(master.name);
  final wanted = normalizeDarkroomTargetName(key);
  return wanted.isNotEmpty && name.startsWith(wanted);
}

/// The Targets tab's list: every target with lights or masters, the most
/// recently imaged first.
List<DarkroomTarget> buildDarkroomTargets({
  required Map<String, List<DbCapturedImage>> framesByTarget,
  required List<IntegratedMaster> masters,
  required List<DbTarget> targetRows,
  required Map<int, Set<int>> foldedByMaster,
  Map<int, Set<int>>? usedByMaster,
}) {
  final rowsByName = {for (final t in targetRows) t.name: t};
  final result = <DarkroomTarget>[];
  for (final entry in framesByTarget.entries) {
    final key = entry.key;
    final frames = entry.value;
    final row = rowsByName[key];
    final frameIds = {for (final f in frames) f.id};
    final own = [
      for (final m in masters)
        if (darkroomMasterBelongsTo(
          m,
          key,
          row: row,
          frameIds: frameIds,
          foldedIds: foldedByMaster[m.id] ?? const {},
        ))
          m,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final newestByFilter = <String, IntegratedMaster>{};
    for (final m in own) {
      if (m.channels >= 3) continue;
      final filter = m.filter?.trim();
      if (filter == null || filter.isEmpty) continue;
      newestByFilter.putIfAbsent(filter, () => m);
    }
    final folded = <int>{
      for (final m in [...newestByFilter.values]) ...?foldedByMaster[m.id],
    };
    final used = <int>{
      for (final m in [...newestByFilter.values])
        ...?(usedByMaster ?? foldedByMaster)[m.id],
    };
    final nights = buildDarkroomNights(
      frames,
      folded: folded,
      used: used,
      target: row,
    );
    final filters = <String>{
      for (final f in frames) darkroomFilterOf(f),
      ...newestByFilter.keys,
    }.toList()
      ..sort(compareDarkroomFilters);
    final channels = [
      for (final filter in filters)
        DarkroomChannel(
          filter: filter,
          master: newestByFilter[filter],
          keptSubs: frames
              .where((f) => f.isAccepted && darkroomFilterOf(f) == filter)
              .length,
          keptSeconds: frames
              .where((f) => f.isAccepted && darkroomFilterOf(f) == filter)
              .fold<double>(0, (s, f) => s + f.exposureDuration),
        ),
    ];
    result.add(
      DarkroomTarget(
        key: key,
        row: row,
        frames: frames,
        nights: nights,
        masters: own,
        channels: channels,
      ),
    );
  }
  result.sort((a, b) {
    final la = a.lastImaged, lb = b.lastImaged;
    if (la == null || lb == null) return a.key.compareTo(b.key);
    return lb.compareTo(la);
  });
  return result;
}
