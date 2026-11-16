// The observing run every public screenshot depicts, held in one place so the
// screens agree with each other: the site, the rig, the three targets, the
// nights already in the database and tonight's run in progress.
//
// Tonight is the evening of the day the capture runs (before noon, the
// evening before), and "now" on the screens is 23:47 on it. NGC 7331, M31
// and M1 cross the meridian at about 19:20, 21:25 and 02:15 local time in
// mid-November at this site, so they are imaged in that order.
//
// Positions, altitudes and transit times are computed, not typed. Frame
// statistics (HFR, stars, guiding, temperatures) are generated from a seeded
// random walk so the charts look like a real night and the run is
// reproducible; they are illustrative.
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:skotiq_core/database.dart';

/// A target of the run.
class ShotTarget {
  const ShotTarget({
    required this.id,
    required this.name,
    required this.catalogId,
    required this.objectType,
    required this.raHours,
    required this.decDegrees,
    required this.magnitude,
    required this.constellation,
    required this.sizeArcmin,
    required this.plan,
  });

  final int id;
  final String name;

  /// The OpenNGC id, as a target saved from the catalog carries it.
  final String catalogId;
  final String objectType;
  final double raHours;
  final double decDegrees;
  final double magnitude;
  final String constellation;
  final double sizeArcmin;

  /// Frames per filter and the sub length, per night.
  final ShotFilterPlan plan;

  /// The capture folder name.
  String get folder => name.replaceAll(' ', '');
}

class ShotFilterPlan {
  const ShotFilterPlan({
    required this.exposureSecs,
    required this.frames,
    required this.goalFrames,
  });

  final double exposureSecs;

  /// Frames per filter in one night's plan, in the order the run rotates.
  final Map<String, int> frames;

  /// The integration goal, as frames per filter.
  final Map<String, int> goalFrames;

  int get framesPerNight => frames.values.fold(0, (a, b) => a + b);
}

/// One target's slot on one night.
class ShotSlot {
  const ShotSlot(this.target, this.start, this.end);
  final ShotTarget target;
  final DateTime start;
  final DateTime end;
}

/// One frame as the database stores it.
class ShotFrame {
  ShotFrame({
    required this.target,
    required this.filter,
    required this.exposureSecs,
    required this.capturedAt,
    required this.hfr,
    required this.fwhmArcsec,
    required this.eccentricity,
    required this.stars,
    required this.background,
    required this.noise,
    required this.guideRa,
    required this.guideDec,
    required this.altitude,
    required this.azimuth,
    required this.focuserPosition,
    required this.focuserTemp,
    required this.sensorTemp,
    required this.coolerPower,
    required this.pierSide,
    required this.frameNumber,
  });

  final ShotTarget target;
  final String filter;
  final double exposureSecs;
  final DateTime capturedAt;
  final double hfr;
  final double fwhmArcsec;
  final double eccentricity;
  final int stars;
  final double background;
  final double noise;
  final double guideRa;
  final double guideDec;
  final double altitude;
  final double azimuth;
  final int focuserPosition;
  final double focuserTemp;
  final double sensorTemp;
  final double coolerPower;
  final String pierSide;
  final int frameNumber;

  double get guideTotal => math.sqrt(guideRa * guideRa + guideDec * guideDec);
}

/// One night of the run.
class ShotNightRun {
  ShotNightRun({
    required this.dayOffset,
    required this.slots,
    required this.frames,
    required this.autofocusRuns,
    required this.sessionId,
  });

  /// 0 is tonight, -1 last night.
  final int dayOffset;
  final List<ShotSlot> slots;
  final List<ShotFrame> frames;
  final List<ShotAutofocus> autofocusRuns;
  final int sessionId;

  DateTime get start => slots.first.start;

  /// The sequence the night ran.
  String get runName {
    final names = [for (final s in slots) s.target];
    if (names.every(ShotNight.targets.contains)) return ShotNight.sequenceName;
    final narrowband = names.first.plan.frames.containsKey('Ha');
    return '${names.map((t) => t.name).join(' + ')} '
        '${narrowband ? 'SHO' : 'LRGB'}';
  }

  DateTime get end => frames.last.capturedAt;
  double get integrationSecs =>
      frames.fold(0.0, (sum, f) => sum + f.exposureSecs);

  /// Meridian flips: each target that crossed the meridian during its slot.
  int get meridianFlips => slots.where((s) {
        final t = ShotNight.transit(s.target, dayOffset);
        return t.isAfter(s.start) && t.isBefore(end) && t.isBefore(s.end);
      }).length;

  int get dithers => frames.length ~/ 3;

  /// The run record's statistics, as the executor writes them.
  Map<String, Object?> get stats {
    final breakdown = <String, Map<String, Map<String, Object?>>>{};
    for (final f in frames) {
      final byFilter = breakdown.putIfAbsent(f.target.name, () => {});
      final row = byFilter.putIfAbsent(
        f.filter,
        () => {'captured': 0, 'rejected': 0, 'integrationSecs': 0.0},
      );
      row['captured'] = (row['captured']! as int) + 1;
      row['integrationSecs'] =
          (row['integrationSecs']! as double) + f.exposureSecs;
    }
    final wall = end.difference(start).inSeconds.toDouble();
    return {
      'wallClockSecs': wall,
      'integrationSecs': integrationSecs,
      'overheadSecs': wall - integrationSecs,
      'framesCaptured': frames.length,
      'framesRejected': 0,
      'triggerFires': autofocusRuns.length + meridianFlips,
      'autofocusRuns': autofocusRuns.length,
      'meridianFlips': meridianFlips,
      'ditherCount': dithers,
      'targetBreakdown': breakdown,
    };
  }
}

class ShotAutofocus {
  const ShotAutofocus(this.at, this.position, this.hfr, this.temperature);
  final DateTime at;
  final int position;
  final double hfr;
  final double temperature;
}

abstract final class ShotNight {
  /// A dark-sky site in the Eastern time zone, so the captures read right when
  /// the test runs under `TZ=America/New_York`.
  static const double latitude = 38.7;
  static const double longitude = -79.53;
  static const double elevation = 1400;
  static const String siteName = 'Spruce Knob';
  static const String timezone = 'America/New_York';

  static const String profileName = 'Esprit 100 · 2600MM';
  static const String sequenceName = 'Autumn galaxies + M1';
  static const String camera = 'ZWO ASI2600MM Pro';
  static const String mount = 'Sky-Watcher EQ6-R Pro';
  static const String focuser = 'ZWO EAF';
  static const String filterWheel = 'ZWO EFW 7x36 II';
  static const String guider = 'PHD2';
  static const String telescope = 'Sky-Watcher Esprit 100ED';
  static const double focalLength = 550;
  static const double aperture = 100;
  static const double pixelSizeUm = 3.76;
  static const int sensorWidth = 6248;
  static const int sensorHeight = 4176;
  static const int gain = 100;
  static const int offset = 50;
  static const double setpoint = -10;
  static const List<String> filters = ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'];

  /// Image scale in arcseconds per pixel.
  static double get pixelScale => 206.265 * pixelSizeUm / focalLength;

  static const ngc7331 = ShotTarget(
    id: 1,
    name: 'NGC 7331',
    catalogId: 'NGC7331',
    objectType: 'Galaxy',
    raHours: 22 + 37 / 60 + 4.1 / 3600,
    decDegrees: 34 + 24 / 60 + 56 / 3600,
    magnitude: 9.5,
    constellation: 'Peg',
    sizeArcmin: 10.5,
    plan: ShotFilterPlan(
      exposureSecs: 180,
      frames: {'L': 20, 'R': 6, 'G': 6, 'B': 6},
      goalFrames: {'L': 120, 'R': 40, 'G': 40, 'B': 40},
    ),
  );

  static const m31 = ShotTarget(
    id: 2,
    name: 'M31',
    catalogId: 'NGC224',
    objectType: 'Galaxy',
    raHours: 0 + 42 / 60 + 44.3 / 3600,
    decDegrees: 41 + 16 / 60 + 9 / 3600,
    magnitude: 3.4,
    constellation: 'And',
    sizeArcmin: 190,
    plan: ShotFilterPlan(
      exposureSecs: 120,
      frames: {'L': 40, 'R': 15, 'G': 15, 'B': 15},
      goalFrames: {'L': 360, 'R': 120, 'G': 120, 'B': 120},
    ),
  );

  static const m1 = ShotTarget(
    id: 3,
    name: 'M1',
    catalogId: 'NGC1952',
    objectType: 'Supernova remnant',
    raHours: 5 + 34 / 60 + 31.9 / 3600,
    decDegrees: 22 + 0 / 60 + 52 / 3600,
    magnitude: 8.4,
    constellation: 'Tau',
    sizeArcmin: 6,
    plan: ShotFilterPlan(
      exposureSecs: 240,
      frames: {'L': 24, 'R': 8, 'G': 8, 'B': 8},
      goalFrames: {'L': 150, 'R': 50, 'G': 50, 'B': 50},
    ),
  );

  static const ngc891 = ShotTarget(
    id: 4,
    name: 'NGC 891',
    catalogId: 'NGC891',
    objectType: 'Galaxy',
    raHours: 2 + 22 / 60 + 33.4 / 3600,
    decDegrees: 42 + 20 / 60 + 57 / 3600,
    magnitude: 10.0,
    constellation: 'And',
    sizeArcmin: 13.5,
    plan: ShotFilterPlan(
      exposureSecs: 180,
      frames: {'L': 40, 'R': 12, 'G': 12, 'B': 12},
      goalFrames: {'L': 120, 'R': 36, 'G': 36, 'B': 36},
    ),
  );

  static const ic1805 = ShotTarget(
    id: 5,
    name: 'IC 1805',
    catalogId: 'IC1805',
    objectType: 'Emission nebula',
    raHours: 2 + 33 / 60 + 22 / 3600,
    decDegrees: 61 + 26 / 60 + 36 / 3600,
    magnitude: 6.5,
    constellation: 'Cas',
    sizeArcmin: 60,
    plan: ShotFilterPlan(
      exposureSecs: 300,
      frames: {'Ha': 36, 'OIII': 36, 'SII': 36},
      goalFrames: {'Ha': 120, 'OIII': 120, 'SII': 120},
    ),
  );

  static const m33 = ShotTarget(
    id: 6,
    name: 'M33',
    catalogId: 'NGC598',
    objectType: 'Galaxy',
    raHours: 1 + 33 / 60 + 50.9 / 3600,
    decDegrees: 30 + 39 / 60 + 37 / 3600,
    magnitude: 5.7,
    constellation: 'Tri',
    sizeArcmin: 70,
    plan: ShotFilterPlan(
      exposureSecs: 180,
      frames: {'L': 30, 'R': 10, 'G': 10, 'B': 10},
      goalFrames: {'L': 160, 'R': 50, 'G': 50, 'B': 50},
    ),
  );

  /// Tonight's run, in its order.
  static const targets = [ngc7331, m31, m1];

  /// Every target in the library.
  static const library = [ngc7331, m31, m1, ngc891, ic1805, m33];

  /// The evening of tonight, at midnight local time.
  static DateTime get evening {
    final now = DateTime.now();
    final day = now.hour < 12 ? now.subtract(const Duration(days: 1)) : now;
    return DateTime(day.year, day.month, day.day);
  }

  /// A local time on the night that starts [dayOffset] evenings from tonight's;
  /// hours before noon fall on the following morning.
  static DateTime at(int dayOffset, int hour, int minute, [int second = 0]) {
    final e = evening.add(Duration(days: dayOffset));
    return DateTime(
      e.year,
      e.month,
      e.day + (hour < 12 ? 1 : 0),
      hour,
      minute,
      second,
    );
  }

  /// "Now" on every screen.
  static DateTime get now => at(0, 23, 47, 12);

  static DateTime get sunset => at(0, 16, 59);
  static DateTime get astroDark => at(0, 18, 33);
  static DateTime get astroDawn => at(0, 5, 34);
  static DateTime get sunrise => at(0, 7, 8);

  /// The slots of a full night.
  static List<ShotSlot> fullNight(int day) => [
        ShotSlot(ngc7331, at(day, 18, 40), at(day, 21, 4)),
        ShotSlot(m31, at(day, 21, 10), at(day, 0, 38)),
        ShotSlot(m1, at(day, 0, 46), at(day, 5, 12)),
      ];

  /// The nights in the database, oldest first, and tonight last. Session ids
  /// follow the same order.
  static final List<ShotNightRun> nights = _buildNights();

  static ShotNightRun get tonight => nights.last;
  static ShotNightRun get lastNight => nights[nights.length - 2];

  /// Every night before tonight: the rows the database holds.
  static List<ShotNightRun> get pastNights =>
      nights.sublist(0, nights.length - 1);

  static List<ShotNightRun> _buildNights() {
    final specs = <(int, List<ShotSlot>)>[
      (
        -27,
        [
          ShotSlot(m33, at(-27, 19, 40), at(-27, 23, 50)),
          ShotSlot(ngc891, at(-27, 23, 56), at(-27, 4, 50)),
        ]
      ),
      (-24, [ShotSlot(ic1805, at(-24, 19, 20), at(-24, 4, 40))]),
      (-21, [ShotSlot(ngc891, at(-21, 20, 10), at(-21, 4, 20))]),
      (-18, [ShotSlot(ic1805, at(-18, 19, 10), at(-18, 3, 50))]),
      (
        -13,
        [
          ShotSlot(m33, at(-13, 19, 0), at(-13, 23, 20)),
          ShotSlot(ngc891, at(-13, 23, 26), at(-13, 4, 30)),
        ]
      ),
      (-9, [ShotSlot(m31, at(-9, 20, 50), at(-9, 1, 10))]),
      (-6, fullNight(-6)),
      (
        -3,
        [
          ShotSlot(ngc7331, at(-3, 18, 45), at(-3, 21, 2)),
          ShotSlot(m31, at(-3, 21, 8), at(-3, 0, 41)),
        ]
      ),
      (-1, fullNight(-1)),
      (0, fullNight(0)),
    ];
    final runs = <ShotNightRun>[];
    for (final (i, (day, slots)) in specs.indexed) {
      final random = math.Random(1100 + day);
      final frames = <ShotFrame>[];
      final focus = <ShotAutofocus>[];
      final stopAt = day == 0 ? now : null;
      for (final slot in slots) {
        _fillSlot(slot, day, random, frames, focus, stopAt);
      }
      runs.add(
        ShotNightRun(
          dayOffset: day,
          slots: slots,
          frames: frames,
          autofocusRuns: focus,
          sessionId: i + 1,
        ),
      );
    }
    return runs;
  }

  /// Ambient temperature through a night: 9 °C at dark, falling to 3 °C.
  static double ambientAt(int day, DateTime t) {
    final hours = t.difference(at(day, 18, 0)).inMinutes / 60;
    return 9.0 - 6.0 * (1 - math.exp(-hours / 5)) - 0.4 * (day % 3);
  }

  static void _fillSlot(
    ShotSlot slot,
    int day,
    math.Random random,
    List<ShotFrame> frames,
    List<ShotAutofocus> focus,
    DateTime? stopAt,
  ) {
    if (stopAt != null && slot.start.isAfter(stopAt)) return;
    final plan = slot.target.plan;
    final order = <String>[];
    // Rotate one frame per filter while every filter has frames left, L
    // getting its extra frames in between.
    final left = Map<String, int>.of(plan.frames);
    while (left.values.any((n) => n > 0)) {
      for (final f in plan.frames.keys) {
        if (left[f]! > 0) {
          order.add(f);
          left[f] = left[f]! - 1;
          if (f == 'L' && left['L']! > 0 && left['L']! > left['R']! + 1) {
            order.add('L');
            left['L'] = left['L']! - 1;
          }
        }
      }
    }
    const overheadSecs = 14;
    var t = slot.start.add(const Duration(minutes: 3));
    // Autofocus at the start of each target, then on a 1 degree drop.
    var temp = ambientAt(day, t);
    var focusTemp = temp;
    var position = _focusPosition(temp);
    focus.add(ShotAutofocus(t, position, 1.86 + random.nextDouble() * 0.08,
        double.parse(temp.toStringAsFixed(1))));
    t = t.add(const Duration(minutes: 3));
    var number = 0;
    for (final filter in order) {
      final end = t.add(
        Duration(seconds: plan.exposureSecs.round()),
      );
      if (end.isAfter(slot.end)) break;
      if (stopAt != null && end.isAfter(stopAt)) break;
      temp = ambientAt(day, end);
      if ((focusTemp - temp).abs() >= 1.0) {
        position = _focusPosition(temp);
        focusTemp = temp;
        focus.add(ShotAutofocus(end, position, 1.84 + random.nextDouble() * 0.1,
            double.parse(temp.toStringAsFixed(1))));
        t = end.add(const Duration(minutes: 2, seconds: 40));
        continue;
      }
      final (alt, az) = altAz(slot.target, end);
      final airmass = 1 / math.sin(alt * math.pi / 180);
      final seeing = 2.35 +
          0.25 * math.sin(end.millisecondsSinceEpoch / 3.6e6 / 1.7 + day) +
          (random.nextDouble() - 0.5) * 0.18;
      final filterBlur = switch (filter) {
        'B' => 1.06,
        'R' => 0.98,
        _ => 1.0,
      };
      final fwhm = seeing * math.pow(airmass, 0.6) * filterBlur;
      final hfr = fwhm / pixelScale * 0.62 + 0.25;
      final starsBase = switch (slot.target.name) {
        'M31' => 3400,
        'NGC 7331' => 1450,
        'IC 1805' => 5200,
        'M33' => 2100,
        'NGC 891' => 1900,
        _ => 2300,
      };
      final filterStars = switch (filter) {
        'L' => 1.0,
        'R' => 0.86,
        'G' => 0.83,
        'B' => 0.76,
        _ => 0.4,
      };
      final stars = (starsBase *
              filterStars /
              airmass *
              (0.95 + random.nextDouble() * 0.1))
          .round();
      final bg = switch (filter) {
            'L' => 1180.0,
            'R' => 640.0,
            'G' => 610.0,
            _ => 560.0,
          } *
          (plan.exposureSecs / 180) *
          (0.9 + 0.15 * airmass);
      final guideRa = 0.42 + random.nextDouble() * 0.16;
      final guideDec = 0.36 + random.nextDouble() * 0.14;
      number++;
      frames.add(
        ShotFrame(
          target: slot.target,
          filter: filter,
          exposureSecs: plan.exposureSecs,
          capturedAt: end,
          hfr: double.parse(hfr.toStringAsFixed(2)),
          fwhmArcsec: double.parse(fwhm.toStringAsFixed(2)),
          eccentricity: double.parse(
              (0.32 + random.nextDouble() * 0.08).toStringAsFixed(2)),
          stars: stars,
          background: double.parse(bg.toStringAsFixed(0)),
          noise: double.parse((math.sqrt(bg) * 0.42).toStringAsFixed(1)),
          guideRa: double.parse(guideRa.toStringAsFixed(2)),
          guideDec: double.parse(guideDec.toStringAsFixed(2)),
          altitude: double.parse(alt.toStringAsFixed(1)),
          azimuth: double.parse(az.toStringAsFixed(1)),
          focuserPosition: position,
          focuserTemp: double.parse(temp.toStringAsFixed(1)),
          sensorTemp: double.parse(
            (-10.0 + (random.nextDouble() - 0.5) * 0.14).toStringAsFixed(1),
          ),
          coolerPower: 28 + temp * 1.6 + random.nextDouble() * 3,
          pierSide: az < 180 ? 'West' : 'East',
          frameNumber: number,
        ),
      );
      t = end.add(const Duration(seconds: overheadSecs));
      if (number % 3 == 0) t = t.add(const Duration(seconds: 11));
    }
  }

  /// The focuser position for an ambient temperature: about 30 steps per
  /// degree, outward as it cools.
  static int _focusPosition(double temp) => (28420 + (9 - temp) * 31).round();

  /// Local sidereal time in hours at [t].
  static double lst(DateTime t) {
    final utc = t.toUtc();
    final j2000 = DateTime.utc(2000, 1, 1, 12);
    final days = utc.difference(j2000).inMilliseconds / 86400000.0;
    final gmst = 18.697374558 + 24.06570982441908 * days;
    return ((gmst + longitude / 15) % 24 + 24) % 24;
  }

  /// Altitude and azimuth in degrees of [target] at [t].
  static (double, double) altAz(ShotTarget target, DateTime t) =>
      altAzOf(target.raHours, target.decDegrees, t);

  static (double, double) altAzOf(double raHours, double decDeg, DateTime t) {
    const rad = math.pi / 180;
    final ha = (lst(t) - raHours) * 15 * rad;
    final dec = decDeg * rad;
    const lat = latitude * rad;
    final sinAlt = math.sin(dec) * math.sin(lat) +
        math.cos(dec) * math.cos(lat) * math.cos(ha);
    final alt = math.asin(sinAlt);
    final cosAz = (math.sin(dec) - math.sin(alt) * math.sin(lat)) /
        (math.cos(alt) * math.cos(lat));
    var az = math.acos(cosAz.clamp(-1.0, 1.0)) / rad;
    if (math.sin(ha) > 0) az = 360 - az;
    return (alt / rad, az);
  }

  /// Hour angle in hours, -12..12.
  static double hourAngle(ShotTarget target, DateTime t) {
    var ha = lst(t) - target.raHours;
    if (ha > 12) ha -= 24;
    if (ha < -12) ha += 24;
    return ha;
  }

  /// The local time [target] crosses the meridian on the night of [day].
  static DateTime transit(ShotTarget target, int day) {
    var t = at(day, 12, 0);
    for (var i = 0; i < 3; i++) {
      final ha = hourAngle(target, t);
      t = t.subtract(Duration(seconds: (ha * 3600 / 1.0027379).round()));
      if (t.isBefore(at(day, 12, 0))) t = t.add(const Duration(hours: 24));
    }
    return t;
  }

  /// The database id of [frame]: frames are inserted night by night in
  /// order, so ids count up from 1 through every night.
  static int frameId(ShotFrame frame) {
    var id = 0;
    for (final night in nights) {
      final i = night.frames.indexOf(frame);
      if (i >= 0) return id + i + 1;
      id += night.frames.length;
    }
    throw StateError('not a seeded frame');
  }

  static String filePath(ShotFrame f) {
    final folder = f.target.folder;
    final name = '${folder}_${f.filter}_'
        '${f.exposureSecs.round()}s_${f.frameNumber.toString().padLeft(4, '0')}.fits';
    return 'D:\\Astro\\Skotiq\\$folder\\${f.filter}\\$name';
  }

  /// Writes the targets, goals, past nights and their frames.
  static Future<void> seed(SkotiqDatabase db) async {
    for (final target in library) {
      await db.into(db.targets).insert(
            TargetsCompanion.insert(
              id: Value(target.id),
              name: target.name,
              catalogId: Value(target.catalogId),
              objectType: Value(target.objectType),
              ra: target.raHours,
              dec: target.decDegrees,
              magnitude: Value(target.magnitude),
              constellation: Value(target.constellation),
              sizeArcmin: Value(target.sizeArcmin),
              minAltitude: const Value(30),
              createdAt: Value(at(-30, 17, 0)),
              updatedAt: Value(at(-1, 7, 0)),
            ),
          );
      for (final entry in target.plan.goalFrames.entries) {
        await db.into(db.integrationGoals).insert(
              IntegrationGoalsCompanion.insert(
                targetId: target.id,
                filter: entry.key,
                exposureSeconds: target.plan.exposureSecs,
                frameCount: entry.value,
                createdAt: at(-30, 17, 0).millisecondsSinceEpoch ~/ 1000,
              ),
            );
      }
    }
    for (final night in nights) {
      final live = night.dayOffset == 0;
      final targetIds = {for (final s in night.slots) s.target.id};
      await db.into(db.imagingSessions).insert(
            ImagingSessionsCompanion.insert(
              id: Value(night.sessionId),
              name: Value(night.runName),
              profileId: const Value(null),
              targetId: Value(targetIds.length == 1 ? targetIds.first : null),
              startTime: night.start,
              endTime: Value(
                live ? null : night.end.add(const Duration(minutes: 6)),
              ),
              totalExposures: Value(night.frames.length),
              successfulExposures: Value(night.frames.length),
              failedExposures: const Value(0),
              totalIntegrationSecs: Value(night.integrationSecs),
              avgTemperature: Value(
                night.frames.fold(0.0, (s, f) => s + f.sensorTemp) /
                    night.frames.length,
              ),
              avgHfr: Value(
                night.frames.fold(0.0, (s, f) => s + f.hfr) /
                    night.frames.length,
              ),
              avgGuidingRms: Value(
                night.frames.fold(0.0, (s, f) => s + f.guideTotal) /
                    night.frames.length,
              ),
              autofocusCount: Value(night.autofocusRuns.length),
              status: Value(live ? 'running' : 'completed'),
            ),
          );
      await db.into(db.sequenceRuns).insert(
            SequenceRunsCompanion.insert(
              sequenceName: night.runName,
              startedAt: night.start.add(const Duration(seconds: 20)),
              endedAt: Value(
                live ? null : night.end.add(const Duration(minutes: 6)),
              ),
              status: Value(live ? 'running' : 'completed'),
              statsJson: Value(jsonEncode(night.stats)),
            ),
          );
      await db.batch((batch) {
        batch.insertAll(db.capturedImages, [
          for (final f in night.frames)
            CapturedImagesCompanion.insert(
              filePath: filePath(f),
              fileName: filePath(f).split('\\').last,
              fileSize: const Value(52224000),
              sessionId: Value(night.sessionId),
              targetId: Value(f.target.id),
              exposureDuration: f.exposureSecs,
              gain: const Value(gain),
              offset: const Value(offset),
              filter: Value(f.filter),
              sensorTemp: Value(f.sensorTemp),
              coolerPower: Value(f.coolerPower),
              hfr: Value(f.hfr),
              fwhm: Value(f.fwhmArcsec),
              eccentricity: Value(f.eccentricity),
              starCount: Value(f.stars),
              background: Value(f.background),
              noise: Value(f.noise),
              guidingRmsRa: Value(f.guideRa),
              guidingRmsDec: Value(f.guideDec),
              guidingRmsTotal: Value(f.guideTotal),
              mountRa: Value(f.target.raHours),
              mountDec: Value(f.target.decDegrees),
              mountAltitude: Value(f.altitude),
              mountAzimuth: Value(f.azimuth),
              pierSide: Value(f.pierSide),
              focuserPosition: Value(f.focuserPosition),
              focuserTemp: Value(f.focuserTemp),
              isPlateSolved: const Value(true),
              solvedRa: Value(f.target.raHours * 15),
              solvedDec: Value(f.target.decDegrees),
              solvedPixelScale: Value(pixelScale),
              capturedAt: f.capturedAt,
              isAccepted: const Value(true),
              runtimeGrade: const Value('pass'),
            ),
        ]);
      });
    }
  }
}
