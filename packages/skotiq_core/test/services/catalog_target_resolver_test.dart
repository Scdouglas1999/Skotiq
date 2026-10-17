import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' show Target;

void main() {
  group('resolveDbTargetForCatalog', () {
    Target dbTarget({
      required int id,
      required String name,
      required double ra,
      required double dec,
      String? catalogId,
    }) {
      return Target(
        id: id,
        name: name,
        ra: ra,
        dec: dec,
        catalogId: catalogId,
        minAltitude: 20,
        totalPlannedSubs: 0,
        totalIntegrationSecs: 0,
        priority: 1,
        capturedSubs: 0,
        goalIntegrationSecs: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        isFavorite: false,
      );
    }

    test('matches by exact name', () {
      final matched = resolveDbTargetForCatalog(
        candidates: [
          dbTarget(id: 1, name: 'Orion Nebula', ra: 5.58, dec: -5.39),
          dbTarget(id: 2, name: 'Andromeda', ra: 0.7, dec: 41.3),
        ],
        targetName: 'orion nebula',
        raHours: 99,
        decDegrees: 99,
      );

      expect(matched?.id, equals(1));
    });

    test('matches by catalog id', () {
      final matched = resolveDbTargetForCatalog(
        candidates: [
          dbTarget(
            id: 42,
            name: 'Great Orion Nebula',
            catalogId: 'M42',
            ra: 5.58,
            dec: -5.39,
          ),
        ],
        targetName: 'M42',
        catalogId: 'M42',
        raHours: 99,
        decDegrees: 99,
      );

      expect(matched?.id, equals(42));
    });

    test('matches by coordinate proximity within tolerance', () {
      final matched = resolveDbTargetForCatalog(
        candidates: [dbTarget(id: 7, name: 'Rosette', ra: 6.533, dec: 4.95)],
        targetName: 'NGC 2244',
        catalogId: 'NGC2244',
        raHours: 6.53301,
        decDegrees: 4.95001,
      );

      expect(matched?.id, equals(7));
    });

    test('returns null when no candidate matches', () {
      final matched = resolveDbTargetForCatalog(
        candidates: [dbTarget(id: 1, name: 'M31', ra: 0.7, dec: 41.3)],
        targetName: 'M42',
        catalogId: 'M42',
        raHours: 5.58,
        decDegrees: -5.39,
      );

      expect(matched, isNull);
    });
  });
}
