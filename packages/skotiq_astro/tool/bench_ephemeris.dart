// ignore_for_file: avoid_print
// Micro-benchmark for the ephemeris paths the planner and Tonight screens hit.
// Run: dart run tool/bench_ephemeris.dart
import 'package:skotiq_astro/skotiq_astro.dart';

void main() {
  const sites = [(34.05, -118.25), (51.48, 0.0), (-33.87, 151.21), (64.84, -147.72)];
  double bench(String name, int n, void Function(int i) body) {
    for (var i = 0; i < n ~/ 10 + 1; i++) {
      body(i);
    }
    // Best of five: the machine is shared, and the minimum is the least
    // disturbed run.
    var us = double.infinity;
    for (var run = 0; run < 5; run++) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        body(i);
      }
      sw.stop();
      final perCall = sw.elapsedMicroseconds / n;
      if (perCall < us) us = perCall;
    }
    print('${name.padRight(44)} ${us.toStringAsFixed(1).padLeft(10)} us/call');
    return us;
  }

  final base = DateTime(2026, 1, 1);
  bench('calculateTwilightTimes', 400, (i) {
    final (lat, lon) = sites[i % sites.length];
    AstronomyCalculations.calculateTwilightTimes(
      date: base.add(Duration(days: i % 365)),
      latitudeDeg: lat,
      longitudeDeg: lon,
    );
  });
  bench('calculateObjectVisibility (fixed)', 400, (i) {
    final (lat, lon) = sites[i % sites.length];
    AstronomyCalculations.calculateObjectVisibility(
      raDeg: (i * 37) % 360,
      decDeg: (i * 13) % 120 - 60,
      date: base.add(Duration(days: i % 365)),
      latitudeDeg: lat,
      longitudeDeg: lon,
    );
  });
  bench('calculateMoonTimes', 400, (i) {
    final (lat, lon) = sites[i % sites.length];
    AstronomyCalculations.calculateMoonTimes(
      date: base.add(Duration(days: i % 365)),
      latitudeDeg: lat,
      longitudeDeg: lon,
    );
  });
  bench('objectAltAz', 200000, (i) {
    AstronomyCalculations.objectAltAz(
      raDeg: (i * 37) % 360,
      decDeg: (i * 13) % 120 - 60,
      dt: base.add(Duration(minutes: i)),
      latitudeDeg: 34.05,
      longitudeDeg: -118.25,
    );
  });
}
