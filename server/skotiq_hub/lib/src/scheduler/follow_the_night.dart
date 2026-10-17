import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart';

import '../db/hub_database.dart';

/// A shared, cone-addressable target the community is collectively imaging.
class SharedTarget {
  SharedTarget({
    required this.id,
    required this.name,
    required this.centerRaDeg,
    required this.centerDecDeg,
    required this.radiusDeg,
    required this.priority,
    required this.integrationSeconds,
  });

  final int id;
  final String name;
  final double centerRaDeg;
  final double centerDecDeg;
  final double radiusDeg;

  /// Operator-set base priority in [0, 1]; combined with photon-need at query.
  final double priority;

  /// Total integration the swarm has banked on this target (seconds).
  final double integrationSeconds;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'centerRaDeg': centerRaDeg,
    'centerDecDeg': centerDecDeg,
    'radiusDeg': radiusDeg,
    'priority': priority,
    'integrationSeconds': integrationSeconds,
  };
}

/// One ranked entry in a follow-the-night plan.
class FollowTheNightEntry {
  FollowTheNightEntry({
    required this.target,
    required this.altitudeDeg,
    required this.altitudeOk,
    required this.photonNeed,
    required this.score,
  });

  final SharedTarget target;

  /// Current altitude of the target from the contributor's site (deg).
  final double altitudeDeg;

  /// Whether the target clears the contributor's minimum altitude right now.
  final bool altitudeOk;

  /// 0 (well-covered) .. 1 (starved). Inverse of banked integration.
  final double photonNeed;

  /// Final ranking score (higher = image this next).
  final double score;

  Map<String, Object?> toJson() => <String, Object?>{
    'target': target.toJson(),
    'altitudeDeg': altitudeDeg,
    'altitudeOk': altitudeOk,
    'photonNeed': photonNeed,
    'score': score,
  };
}

/// Computes which shared targets are dark for a contributor right now and most
/// in need of photons. Pure astronomy (LST → hour angle → altitude) so it runs
/// anywhere with no ephemeris service.
class FollowTheNightScheduler {
  FollowTheNightScheduler(this._db);

  final HubDatabase _db;

  /// Insert or fetch a shared target. Returns its id. Cone-addressable: an
  /// existing target within [mergeRadiusDeg] of the same centre is reused so the
  /// swarm converges on one shared stack per object rather than fragmenting.
  int ensureTarget({
    required String name,
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    double priority = 0.5,
    double mergeRadiusDeg = 0.25,
  }) {
    final existing = _db.db.select('SELECT * FROM shared_targets;');
    for (final row in existing) {
      final ra = (row['center_ra_deg'] as num).toDouble();
      final dec = (row['center_dec_deg'] as num).toDouble();
      if (_angularSeparationDeg(centerRaDeg, centerDecDeg, ra, dec) <=
          mergeRadiusDeg) {
        return row['id'] as int;
      }
    }
    _db.db.execute(
      'INSERT INTO shared_targets (name, center_ra_deg, center_dec_deg, '
      'radius_deg, priority, created_at) VALUES (?, ?, ?, ?, ?, ?);',
      <Object?>[
        name.trim(),
        centerRaDeg,
        centerDecDeg,
        radiusDeg,
        priority,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    return _db.db.lastInsertRowId;
  }

  SharedTarget? getTarget(int id) {
    final rows = _db.db.select(
      'SELECT * FROM shared_targets WHERE id = ?;',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Every shared target, highest banked integration first — the swarm's
  /// browseable target list (the entry point to join / contribute / pull). This
  /// backs `GET /v1/targets`, which the constellation client polls before any
  /// per-target handoff query.
  List<SharedTarget> listTargets() {
    final targets = _db.db
        .select('SELECT * FROM shared_targets;')
        .map<SharedTarget>(_fromRow)
        .toList();
    targets.sort(
      (a, b) => b.integrationSeconds.compareTo(a.integrationSeconds),
    );
    return targets;
  }

  /// Rank shared targets for a contributor at ([latitudeDeg], [longitudeDeg])
  /// at [at] (UTC). Targets below [minAltitudeDeg] are excluded; the rest are
  /// scored by `priority * photonNeed * altitudeBonus` so the swarm pours
  /// photons into the darkest, most-starved, highest-priority object available
  /// from the contributor's sky right now.
  List<FollowTheNightEntry> plan({
    required double latitudeDeg,
    required double longitudeDeg,
    DateTime? at,
    double minAltitudeDeg = 25.0,
    int limit = 20,
  }) {
    final when = (at ?? DateTime.now()).toUtc();
    final lstDeg = _localSiderealTimeDeg(when, longitudeDeg);
    final targets = _db.db
        .select('SELECT * FROM shared_targets;')
        .map<SharedTarget>(_fromRow)
        .toList();
    if (targets.isEmpty) return const <FollowTheNightEntry>[];

    var maxIntegration = 0.0;
    for (final t in targets) {
      if (t.integrationSeconds > maxIntegration) {
        maxIntegration = t.integrationSeconds;
      }
    }

    final entries = <FollowTheNightEntry>[];
    for (final t in targets) {
      final alt = _altitudeDeg(
        raDeg: t.centerRaDeg,
        decDeg: t.centerDecDeg,
        latitudeDeg: latitudeDeg,
        lstDeg: lstDeg,
      );
      final altitudeOk = alt >= minAltitudeDeg;
      // Photon need: starved targets (low banked integration) score higher.
      final photonNeed = maxIntegration <= 0
          ? 1.0
          : 1.0 - (t.integrationSeconds / maxIntegration).clamp(0.0, 1.0);
      // Altitude bonus rewards targets high in the sky (lower airmass).
      final altitudeBonus = altitudeOk
          ? (math.sin(alt * math.pi / 180.0)).clamp(0.0, 1.0)
          : 0.0;
      final score = t.priority * (0.5 + 0.5 * photonNeed) * altitudeBonus;
      if (altitudeOk) {
        entries.add(
          FollowTheNightEntry(
            target: t,
            altitudeDeg: alt,
            altitudeOk: altitudeOk,
            photonNeed: photonNeed,
            score: score,
          ),
        );
      }
    }
    entries.sort((a, b) => b.score.compareTo(a.score));
    return entries.take(limit).toList();
  }

  /// Altitude (deg) of a single target right now from a site, used by the
  /// handoff endpoint to report `altitudeOk`.
  double altitudeForTarget({
    required SharedTarget target,
    required double latitudeDeg,
    required double longitudeDeg,
    DateTime? at,
  }) {
    final when = (at ?? DateTime.now()).toUtc();
    final lstDeg = _localSiderealTimeDeg(when, longitudeDeg);
    return _altitudeDeg(
      raDeg: target.centerRaDeg,
      decDeg: target.centerDecDeg,
      latitudeDeg: latitudeDeg,
      lstDeg: lstDeg,
    );
  }

  SharedTarget _fromRow(Row row) {
    return SharedTarget(
      id: row['id'] as int,
      name: row['name'] as String,
      centerRaDeg: (row['center_ra_deg'] as num).toDouble(),
      centerDecDeg: (row['center_dec_deg'] as num).toDouble(),
      radiusDeg: (row['radius_deg'] as num).toDouble(),
      priority: (row['priority'] as num).toDouble(),
      integrationSeconds: (row['integration_seconds'] as num).toDouble(),
    );
  }

  /// The HEALPix tile currently at a target's centre — the "active tile" the
  /// follow-the-night handoff coordinates around.
  static int activeTileFor(SharedTarget target, int order) {
    return _angToNestPix(target.centerRaDeg, target.centerDecDeg, 1 << order);
  }

  // --- Astronomy helpers ---------------------------------------------------

  /// Greenwich Mean Sidereal Time then site longitude → local sidereal time in
  /// degrees [0, 360). Meeus' polynomial (good to arc-seconds, ample here).
  static double _localSiderealTimeDeg(DateTime utc, double longitudeDeg) {
    final jd = _julianDay(utc);
    final t = (jd - 2451545.0) / 36525.0;
    var gmst =
        280.46061837 +
        360.98564736629 * (jd - 2451545.0) +
        0.000387933 * t * t -
        (t * t * t) / 38710000.0;
    gmst %= 360.0;
    if (gmst < 0) gmst += 360.0;
    var lst = gmst + longitudeDeg;
    lst %= 360.0;
    if (lst < 0) lst += 360.0;
    return lst;
  }

  /// Julian Day for [at].
  ///
  /// [at] is normalized with `toUtc()` rather than trusted to already be UTC.
  /// Both call sites normalize first, so the conversion is a no-op for them;
  /// it is present so that a third caller passing a local `DateTime` cannot
  /// silently shift the Julian Day by the site's UTC offset — a whole-hours
  /// error in LST, i.e. a target scored as up while it is below the horizon.
  ///
  /// This copy is NOT shared with `SkyCalculations` in `skotiq_core`:
  /// `skotiq_hub` is a pure-Dart server package and `skotiq_core` is
  /// a Flutter package, so there is no import path between them. It also
  /// builds its day fraction by nested division
  /// (`(h + (m + (s + ms/1000)/60)/60)/24`) rather than as a sum of
  /// independent terms, which is a different rounding and therefore not
  /// interchangeable with `SkyCalculations.julianDate` bit-for-bit.
  static double _julianDay(DateTime at) {
    final utc = at.toUtc();
    final y0 = utc.year;
    final m0 = utc.month;
    final day =
        utc.day +
        (utc.hour +
                (utc.minute + (utc.second + utc.millisecond / 1000.0) / 60.0) /
                    60.0) /
            24.0;
    var y = y0;
    var m = m0;
    if (m <= 2) {
      y -= 1;
      m += 12;
    }
    final a = (y / 100).floor();
    final b = 2 - a + (a / 4).floor();
    return (365.25 * (y + 4716)).floor() +
        (30.6001 * (m + 1)).floor() +
        day +
        b -
        1524.5;
  }

  static double _altitudeDeg({
    required double raDeg,
    required double decDeg,
    required double latitudeDeg,
    required double lstDeg,
  }) {
    final haDeg = lstDeg - raDeg;
    final ha = haDeg * math.pi / 180.0;
    final dec = decDeg * math.pi / 180.0;
    final lat = latitudeDeg * math.pi / 180.0;
    final sinAlt =
        math.sin(lat) * math.sin(dec) +
        math.cos(lat) * math.cos(dec) * math.cos(ha);
    return math.asin(sinAlt.clamp(-1.0, 1.0)) * 180.0 / math.pi;
  }

  static double _angularSeparationDeg(
    double ra1,
    double dec1,
    double ra2,
    double dec2,
  ) {
    final r1 = ra1 * math.pi / 180.0;
    final d1 = dec1 * math.pi / 180.0;
    final r2 = ra2 * math.pi / 180.0;
    final d2 = dec2 * math.pi / 180.0;
    final cosSep =
        math.sin(d1) * math.sin(d2) +
        math.cos(d1) * math.cos(d2) * math.cos(r1 - r2);
    return math.acos(cosSep.clamp(-1.0, 1.0)) * 180.0 / math.pi;
  }

  /// (ra, dec) → HEALPix NESTED pixel id at [nside]. Standard forward mapping;
  /// inverse of [TileBuilder.tileCenter]'s decode, kept here so the scheduler
  /// has no dependency cycle with the tile builder.
  static int _angToNestPix(double raDeg, double decDeg, int nside) {
    final z = math.sin(decDeg * math.pi / 180.0);
    var phi = raDeg * math.pi / 180.0;
    phi %= 2 * math.pi;
    if (phi < 0) phi += 2 * math.pi;
    final za = z.abs();
    final tt = phi * 2.0 / math.pi; // in [0, 4)

    int ifp;
    int ifm;
    int faceNum;
    int ix;
    int iy;
    if (za <= 2.0 / 3.0) {
      // Equatorial region.
      final temp1 = nside * (0.5 + tt);
      final temp2 = nside * (z * 0.75);
      final jp = (temp1 - temp2).floor();
      final jm = (temp1 + temp2).floor();
      ifp = jp ~/ nside;
      ifm = jm ~/ nside;
      faceNum = (ifp == ifm)
          ? (ifp & 3) + 4
          : (ifp < ifm ? ifp & 3 : (ifm & 3) + 8);
      ix = jm & (nside - 1);
      iy = (nside - 1) - (jp & (nside - 1));
    } else {
      // Polar caps.
      final ntt = math.min(3, tt.floor());
      final tp = tt - ntt;
      final tmp = nside * math.sqrt(3.0 * (1.0 - za));
      final jp = (tp * tmp).floor();
      final jm = ((1.0 - tp) * tmp).floor();
      final jpC = math.min(nside - 1, jp);
      final jmC = math.min(nside - 1, jm);
      if (z >= 0) {
        faceNum = ntt;
        ix = (nside - 1) - jmC;
        iy = (nside - 1) - jpC;
      } else {
        faceNum = ntt + 8;
        ix = jpC;
        iy = jmC;
      }
    }
    return faceNum * nside * nside + _interleave(ix, iy);
  }

  /// Bit-interleave (x, y) → NESTED suffix (inverse of the builder's decode).
  static int _interleave(int ix, int iy) {
    var result = 0;
    var bit = 0;
    var x = ix;
    var y = iy;
    while (x > 0 || y > 0) {
      result |= (x & 1) << (2 * bit);
      result |= (y & 1) << (2 * bit + 1);
      x >>= 1;
      y >>= 1;
      bit++;
    }
    return result;
  }
}
