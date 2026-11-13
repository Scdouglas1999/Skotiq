// What one keystroke in the command palette costs with catalogs the size of
// the installed ones (OpenNGC: about 13,000 objects; HYG to magnitude 12:
// about 118,000 stars).
//
// Every keystroke used to walk both catalogs normalizing each designation
// with a regular expression and lower-casing each name, and did it twice:
// once for the key event and once for the rebuild.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/command_palette/command_palette.dart';
import 'package:skotiq_app/screens/shell/command_palette/command_sources.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../harness/harness.dart';

List<DeepSkyObject> _dsos() => [
      for (var i = 1; i <= 13000; i++)
        DeepSkyObject(
          id: 'NGC$i',
          name: i <= 110 ? 'M$i' : 'NGC$i',
          coordinates: CelestialCoordinate(ra: (i % 24).toDouble(), dec: 10),
          type: DsoType.galaxy,
          magnitude: 8 + (i % 80) / 10,
          catalogIds: ['UGC ${i.toString().padLeft(5, '0')}', 'PGC $i'],
          commonNames: i % 40 == 0 ? 'Whirlpool $i Galaxy' : null,
        ),
    ];

List<Star> _stars() => [
      for (var i = 0; i < 118000; i++)
        Star(
          id: 'HIP$i',
          name: i % 300 == 0 ? 'Star${i ~/ 300}' : '',
          coordinates: CelestialCoordinate(ra: (i % 24).toDouble(), dec: -10),
          magnitude: (i % 120) / 10,
        ),
    ];

const _queries = [
  'ngc', 'ngc 8', 'ngc 89', 'ngc 891', 'whi', 'whirl', 'star1', 'star12',
  'm3', 'm31', 'ugc 004', 'gain', 'park',
];

double _median(List<double> values) =>
    (values.toList()..sort())[values.length ~/ 2];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a keystroke does not walk the catalogs again', (tester) async {
    final dsos = _dsos();
    final stars = _stars();
    late WidgetRef ref;
    await pumpAppScreen(
      tester,
      Consumer(
        builder: (context, r, _) {
          ref = r;
          return const CommandPalette();
        },
      ),
      size: const Size(1920, 1080),
      extraOverrides: <Override>[
        loadedDsosProvider.overrideWith((ref) async => dsos),
        loadedStarsProvider.overrideWith((ref) async => stars),
      ],
    );

    // The catalog search alone, as each keystroke runs it.
    double search(String query) {
      final watch = Stopwatch()..start();
      buildTargetEntries(ref, query);
      return watch.elapsedMicroseconds / 1000;
    }

    search('ng');
    final searches = [for (final query in _queries) search(query)];

    // The whole keystroke in this harness: the search, the other sources and
    // the palette's rebuild and layout.
    Future<double> type(String query) async {
      await tester.enterText(find.byType(TextField), query);
      final watch = Stopwatch()..start();
      await tester.pump();
      return watch.elapsedMicroseconds / 1000;
    }

    final keystrokes = [for (final query in _queries) await type(query)];
    final oneLetter = await type('a');
    // ignore: avoid_print
    print('command palette, ${dsos.length} objects and ${stars.length} stars: '
        'catalog search median ${_median(searches).toStringAsFixed(2)} ms '
        '(worst ${(searches..sort()).last.toStringAsFixed(2)} ms); '
        'whole keystroke median ${_median(keystrokes).toStringAsFixed(1)} ms; '
        'one-letter query ${oneLetter.toStringAsFixed(1)} ms');

    await type('ngc 891');
    expect(find.text('NGC891'), findsOneWidget);
    await type('m31');
    expect(find.textContaining('M31 (NGC31)'), findsOneWidget);
    await type('star12');
    expect(find.textContaining('Open in Framing'), findsWidgets);

    // Debug-mode numbers on a loaded machine: the bound is far above the
    // indexed search and far below a walk of both catalogs.
    expect(_median(searches), lessThan(15));
  });
}
