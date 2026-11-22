// The palette reads a designation the way every catalog search does
// (normalizeCatalogSearchText): "Messier 42", "M 42" and "M042" are M42.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/command_palette/command_palette.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('spelled and padded designations find the object', (
    tester,
  ) async {
    await pumpAppScreen(
      tester,
      const CommandPalette(),
      size: const Size(1920, 1080),
      extraOverrides: <Override>[
        loadedDsosProvider.overrideWith(
          (ref) async => const [
            DeepSkyObject(
              id: 'NGC1976',
              name: 'M42',
              coordinates: CelestialCoordinate(ra: 5.588, dec: -5.39),
              type: DsoType.nebula,
              magnitude: 4,
              catalogIds: ['M42'],
              commonNames: 'Orion Nebula',
            ),
          ],
        ),
        loadedStarsProvider.overrideWith((ref) async => const <Star>[]),
      ],
    );

    for (final query in [
      'M42',
      'm 42',
      'Messier 42',
      'M042',
      'NGC 1976',
      'ngc 19',
    ]) {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump();
      expect(find.textContaining('M42 (NGC1976)'), findsOneWidget,
          reason: query);
    }
  });
}
