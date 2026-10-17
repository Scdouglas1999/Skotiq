import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Cross-night grouping for the First Light light-curve detail view: a single
/// physical transient re-detected over several nights produces one row per
/// frame, and [TransientDetectionsDao.detectionsNear] gathers them by position
/// so the detail screen can plot a Δmag-vs-time history.
void main() {
  late SkotiqDatabase db;
  late TransientDetectionsDao dao;

  TransientDetectionsCompanion at(
    double ra,
    double dec,
    DateTime when, {
    double? deltaMag,
  }) {
    return TransientDetectionsCompanion.insert(
      tileId: 42,
      raDeg: ra,
      decDeg: dec,
      residualFlux: 1500.0,
      snr: 18.0,
      fwhm: 2.1,
      eccentricity: 0.1,
      kind: 'newSource',
      confidence: 0.8,
      detectedAt: Value(when),
      deltaMag: Value(deltaMag),
    );
  }

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = TransientDetectionsDao(db);
  });

  tearDown(() async => db.close());

  test('groups the same position across nights, oldest-first', () async {
    // Same source, three nights, tiny centroid scatter (<~10").
    await dao.insertDetection(
      at(120.000, 25.000, DateTime.utc(2026, 6, 1), deltaMag: -0.2),
    );
    await dao.insertDetection(
      at(120.001, 25.001, DateTime.utc(2026, 6, 3), deltaMag: -0.5),
    );
    await dao.insertDetection(
      at(119.999, 24.999, DateTime.utc(2026, 6, 5), deltaMag: -0.9),
    );
    // A genuinely different source ~1 deg away — must NOT group in.
    await dao.insertDetection(
      at(121.0, 25.0, DateTime.utc(2026, 6, 4), deltaMag: 0.1),
    );

    final group = await dao.detectionsNear(120.0, 25.0, radiusDeg: 0.02);

    expect(group, hasLength(3));
    // Oldest-first ordering drives the light-curve x-axis. Compare epoch ms so
    // the assertion is timezone-agnostic (Drift round-trips DateTime to local).
    expect(group.map((r) => r.detectedAt.millisecondsSinceEpoch), [
      DateTime.utc(2026, 6, 1).millisecondsSinceEpoch,
      DateTime.utc(2026, 6, 3).millisecondsSinceEpoch,
      DateTime.utc(2026, 6, 5).millisecondsSinceEpoch,
    ]);
    expect(group.every((r) => (r.raDeg - 120.0).abs() < 0.01), isTrue);
  });

  test(
    'RA bounding box widens with declination (cos(dec) correction)',
    () async {
      // At dec=80, 0.02 deg on the sky is ~0.115 deg in RA. A detection 0.05 deg
      // away in RA is on-sky ~0.0087 deg from the anchor — inside a 0.02 cone.
      await dao.insertDetection(at(120.05, 80.0, DateTime.utc(2026, 6, 2)));

      final group = await dao.detectionsNear(120.0, 80.0, radiusDeg: 0.02);

      expect(
        group,
        isNotEmpty,
        reason:
            'high-dec RA box must widen by 1/cos(dec) or it drops real rows',
      );
    },
  );

  test('empty when nothing is near the position', () async {
    await dao.insertDetection(at(10.0, -30.0, DateTime.utc(2026, 6, 2)));

    final group = await dao.detectionsNear(200.0, 50.0, radiusDeg: 0.02);

    expect(group, isEmpty);
  });
}
