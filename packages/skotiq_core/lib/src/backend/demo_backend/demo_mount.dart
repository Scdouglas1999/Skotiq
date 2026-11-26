import 'dart:math' as math;

import '../../models/backend/backend_types.dart';

/// Local sidereal time in hours at [utc] for an observer at [longitudeDeg]
/// (east positive). The IAU 1982 GMST polynomial, good to well under a second
/// for the current century.
double localSiderealHours(DateTime utc, double longitudeDeg) {
  final jd = utc.toUtc().millisecondsSinceEpoch / 86400000.0 + 2440587.5;
  final t = (jd - 2451545.0) / 36525.0;
  final gmstDeg =
      280.46061837 +
      360.98564736629 * (jd - 2451545.0) +
      0.000387933 * t * t -
      t * t * t / 38710000.0;
  return _wrapHours((gmstDeg + longitudeDeg) / 15.0);
}

double _wrapHours(double hours) {
  final wrapped = hours % 24.0;
  return wrapped < 0 ? wrapped + 24.0 : wrapped;
}

/// [hours] folded into -12..12.
double _signedHours(double hours) {
  final wrapped = _wrapHours(hours);
  return wrapped > 12.0 ? wrapped - 24.0 : wrapped;
}

/// Altitude and azimuth (degrees, azimuth from north through east) of
/// [raHours]/[decDeg] for an observer at [latitudeDeg] at [lstHours].
({double altitude, double azimuth}) altAzOf({
  required double raHours,
  required double decDeg,
  required double latitudeDeg,
  required double lstHours,
}) {
  const rad = math.pi / 180.0;
  final ha = _signedHours(lstHours - raHours) * 15.0 * rad;
  final dec = decDeg * rad;
  final lat = latitudeDeg * rad;
  final sinAlt =
      math.sin(dec) * math.sin(lat) +
      math.cos(dec) * math.cos(lat) * math.cos(ha);
  final alt = math.asin(sinAlt.clamp(-1.0, 1.0));
  final y = -math.cos(dec) * math.sin(ha);
  final x =
      math.sin(dec) * math.cos(lat) -
      math.cos(dec) * math.sin(lat) * math.cos(ha);
  var az = math.atan2(y, x) / rad;
  if (az < 0) az += 360.0;
  return (altitude: alt / rad, azimuth: az);
}

/// Right ascension and declination of [altitudeDeg]/[azimuthDeg] for an
/// observer at [latitudeDeg] at [lstHours].
({double raHours, double decDeg}) raDecOf({
  required double altitudeDeg,
  required double azimuthDeg,
  required double latitudeDeg,
  required double lstHours,
}) {
  const rad = math.pi / 180.0;
  final alt = altitudeDeg * rad;
  final az = azimuthDeg * rad;
  final lat = latitudeDeg * rad;
  final sinDec =
      math.sin(alt) * math.sin(lat) +
      math.cos(alt) * math.cos(lat) * math.cos(az);
  final dec = math.asin(sinDec.clamp(-1.0, 1.0));
  final y = -math.sin(az) * math.cos(alt);
  final x =
      math.sin(alt) * math.cos(lat) -
      math.cos(alt) * math.sin(lat) * math.cos(az);
  final ha = math.atan2(y, x) / rad / 15.0;
  return (raHours: _wrapHours(lstHours - ha), decDeg: dec / rad);
}

/// The demo mount: an equatorial mount whose pointing is worked out from the
/// clock whenever it is read. A slew moves it in a straight line from where
/// it was to the target over [slewDuration]; with tracking off the sky turns
/// under it, so its right ascension advances at the sidereal rate.
class DemoMount {
  DemoMount({
    required this.now,
    required this.latitudeDeg,
    required this.longitudeDeg,
  }) {
    final t = now();
    final park = _parkPosition(t);
    _anchorRa = park.raHours;
    _anchorDec = park.decDeg;
    _anchorAt = t;
  }

  final DateTime Function() now;
  final double latitudeDeg;
  final double longitudeDeg;

  bool connected = false;
  bool tracking = false;
  bool parked = true;
  int trackingRate = 0;

  double _anchorRa = 0;
  double _anchorDec = 0;
  DateTime _anchorAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  /// Axis rates of a manual move, degrees per second.
  double _raAxisRate = 0;
  double _decAxisRate = 0;

  _Slew? _slew;

  /// Whether the mount is moving to a target (a GoTo or a park).
  bool get slewing {
    final slew = _slew;
    return slew != null && now().isBefore(slew.endsAt);
  }

  bool _atHome = false;

  bool get atHome => (parked || _atHome) && !slewing;

  /// The demo park position: pointing at the celestial pole, counterweight
  /// down (hour angle 6 h east of the meridian).
  /// Where the mount goes home to: the park position.
  ({double raHours, double decDeg}) homePosition() => _parkPosition(now());

  ({double raHours, double decDeg}) _parkPosition(DateTime at) => (
    raHours: _wrapHours(localSiderealHours(at, longitudeDeg) + 6.0),
    decDeg: latitudeDeg >= 0 ? 90.0 : -90.0,
  );

  ({double raHours, double decDeg}) position() {
    final t = now();
    final slew = _slew;
    if (slew != null) {
      if (t.isBefore(slew.endsAt)) {
        final total = slew.endsAt.difference(slew.startedAt).inMicroseconds;
        final done = t.difference(slew.startedAt).inMicroseconds;
        final f = total <= 0 ? 1.0 : (done / total).clamp(0.0, 1.0);
        final dra = _signedHours(slew.toRa - slew.fromRa);
        return (
          raHours: _wrapHours(slew.fromRa + dra * f),
          decDeg: slew.fromDec + (slew.toDec - slew.fromDec) * f,
        );
      }
      _finishSlew(slew);
    }
    final seconds = t.difference(_anchorAt).inMicroseconds / 1e6;
    final drift = tracking ? 0.0 : seconds * 1.00273790935 / 3600.0;
    final ra = _anchorRa + drift + _raAxisRate * seconds / 15.0;
    final dec = (_anchorDec + _decAxisRate * seconds).clamp(-90.0, 90.0);
    return (raHours: _wrapHours(ra), decDeg: dec);
  }

  void _finishSlew(_Slew slew) {
    _slew = null;
    _anchorRa = slew.toRa;
    _anchorDec = slew.toDec;
    _anchorAt = slew.endsAt;
    if (slew.parks) {
      parked = true;
      tracking = false;
    } else if (slew.homes) {
      _atHome = true;
      tracking = false;
    } else {
      tracking = true;
    }
  }

  /// Fix the current position as the anchor, so a change of tracking or axis
  /// rate applies from now on.
  void _rebase() {
    final p = position();
    _atHome = false;
    _anchorRa = p.raHours;
    _anchorDec = p.decDeg;
    _anchorAt = now();
  }

  /// Start a GoTo; answers how long it takes.
  Duration slewTo(double raHours, double decDeg) {
    final from = position();
    final distanceDeg = _angularDistanceDeg(
      from.raHours,
      from.decDeg,
      raHours,
      decDeg,
    );
    // About 8 degrees a second, never under two seconds or over eight.
    final ms = (distanceDeg / 8.0 * 1000).clamp(2000.0, 8000.0).round();
    final duration = Duration(milliseconds: ms);
    final t = now();
    _raAxisRate = 0;
    _decAxisRate = 0;
    _slew = _Slew(
      fromRa: from.raHours,
      fromDec: from.decDeg,
      toRa: _wrapHours(raHours),
      toDec: decDeg.clamp(-90.0, 90.0),
      startedAt: t,
      endsAt: t.add(duration),
      parks: false,
    );
    _atHome = false;
    tracking = true;
    return duration;
  }

  /// Start a move home; answers how long it takes.
  Duration home() {
    final from = position();
    const duration = Duration(seconds: 5);
    final t = now();
    final target = _parkPosition(t.add(duration));
    _raAxisRate = 0;
    _decAxisRate = 0;
    tracking = false;
    _slew = _Slew(
      fromRa: from.raHours,
      fromDec: from.decDeg,
      toRa: target.raHours,
      toDec: target.decDeg,
      startedAt: t,
      endsAt: t.add(duration),
      parks: false,
      homes: true,
    );
    return duration;
  }

  /// Start a park; answers how long it takes.
  Duration park() {
    final from = position();
    const duration = Duration(seconds: 5);
    final t = now();
    final target = _parkPosition(t.add(duration));
    _raAxisRate = 0;
    _decAxisRate = 0;
    tracking = false;
    _slew = _Slew(
      fromRa: from.raHours,
      fromDec: from.decDeg,
      toRa: target.raHours,
      toDec: target.decDeg,
      startedAt: t,
      endsAt: t.add(duration),
      parks: true,
    );
    return duration;
  }

  void unpark() {
    _rebase();
    parked = false;
  }

  void setTracking(bool enabled) {
    _rebase();
    tracking = enabled;
  }

  void sync(double raHours, double decDeg) {
    _rebase();
    _anchorRa = _wrapHours(raHours);
    _anchorDec = decDeg.clamp(-90.0, 90.0);
  }

  void moveAxis(int axis, double degPerSecond) {
    _rebase();
    if (axis == 0) {
      _raAxisRate = degPerSecond;
    } else {
      _decAxisRate = degPerSecond;
    }
  }

  /// Stop any GoTo or manual move where the mount is now.
  void abort() {
    _rebase();
    _slew = null;
    _raAxisRate = 0;
    _decAxisRate = 0;
  }

  /// A guide pulse nudges the pointing at the guide rate (half sidereal).
  void pulse(String direction, int durationMs) {
    final arcsec = 7.5 * durationMs / 1000.0;
    _rebase();
    switch (direction.toLowerCase()) {
      case 'north' || 'n':
        _anchorDec = (_anchorDec + arcsec / 3600.0).clamp(-90.0, 90.0);
      case 'south' || 's':
        _anchorDec = (_anchorDec - arcsec / 3600.0).clamp(-90.0, 90.0);
      case 'east' || 'e':
        _anchorRa = _wrapHours(_anchorRa + arcsec / 54000.0);
      case 'west' || 'w':
        _anchorRa = _wrapHours(_anchorRa - arcsec / 54000.0);
    }
  }

  MountStatus status() {
    final p = position();
    final lst = localSiderealHours(now(), longitudeDeg);
    final horizon = altAzOf(
      raHours: p.raHours,
      decDeg: p.decDeg,
      latitudeDeg: latitudeDeg,
      lstHours: lst,
    );
    final hourAngle = _signedHours(lst - p.raHours);
    return MountStatus(
      connected: connected,
      tracking: tracking,
      slewing: slewing,
      parked: parked,
      atHome: atHome,
      sideOfPier: hourAngle < 0 ? PierSide.west : PierSide.east,
      rightAscension: p.raHours,
      declination: p.decDeg,
      altitude: horizon.altitude,
      azimuth: horizon.azimuth,
      siderealTime: lst,
      trackingRate: TrackingRate.values[trackingRate.clamp(0, 3)],
      canPark: true,
      canSlew: true,
      canSync: true,
      canPulseGuide: true,
      canSetTrackingRate: true,
    );
  }

  double lstNow() => localSiderealHours(now(), longitudeDeg);
}

class _Slew {
  const _Slew({
    required this.fromRa,
    required this.fromDec,
    required this.toRa,
    required this.toDec,
    required this.startedAt,
    required this.endsAt,
    required this.parks,
    this.homes = false,
  });

  final double fromRa;
  final double fromDec;
  final double toRa;
  final double toDec;
  final DateTime startedAt;
  final DateTime endsAt;
  final bool parks;
  final bool homes;
}

double _angularDistanceDeg(
  double ra1Hours,
  double dec1Deg,
  double ra2Hours,
  double dec2Deg,
) {
  const rad = math.pi / 180.0;
  final ra1 = ra1Hours * 15.0 * rad;
  final ra2 = ra2Hours * 15.0 * rad;
  final d1 = dec1Deg * rad;
  final d2 = dec2Deg * rad;
  final c =
      math.sin(d1) * math.sin(d2) +
      math.cos(d1) * math.cos(d2) * math.cos(ra1 - ra2);
  return math.acos(c.clamp(-1.0, 1.0)) / rad;
}
