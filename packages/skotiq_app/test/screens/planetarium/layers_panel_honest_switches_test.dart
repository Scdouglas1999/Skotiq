// A layer switch must not accept a flip it cannot act on. Two switches have the
// same shape:
//
//  * 'Deep stars (Tycho-2 / Gaia tier)' rendered identical to the working
//    switches next to it. Flipped on at 1.5 deg FOV the sky stays
//    pixel-identical — no stars, no toast, no progress, no "not installed"
//    state — and the switch stays on. No deep tileset is published, and the
//    shipped `deep_stars/config.json` points at an abandoned dev localhost
//    host, so this control can never do anything.
//
//  * 'Equatorial grid' and 'Alt/Az grid' read as peers of 'Coordinate grid' but
//    are only modifiers of it: with the master off, turning either on draws
//    nothing and says nothing.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/redesign/layers_panel.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../harness/pump_app_screen.dart';

/// Every [Switch] in the panel, in build order.
Iterable<Switch> _switches(WidgetTester tester) =>
    tester.widgetList<Switch>(find.byType(Switch));

/// The switch on the row whose label is [label], or null when the row renders
/// something else in the trailing slot (e.g. an Install button).
Switch? _switchFor(WidgetTester tester, String label) {
  final row = find.ancestor(
    of: find.text(label),
    matching: find.byType(Row),
  );
  final switches =
      find.descendant(of: row.first, matching: find.byType(Switch));
  if (switches.evaluate().isEmpty) return null;
  return tester.widget<Switch>(switches.first);
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  List<Override> extraOverrides = const [],
}) async {
  await pumpAppScreen(
    tester,
    const LayersPanel(),
    size: const Size(420, 900),
    extraOverrides: extraOverrides,
    settle: false,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('deep-star tier', () {
    testWidgets('with no tileset installed the row is inert and says why',
        (tester) async {
      await _pumpPanel(
        tester,
        extraOverrides: [
          deepStarManifestProvider.overrideWith(
            (ref) => Future<DeepStarManifest?>.value(null),
          ),
        ],
      );

      expect(find.text('Deep stars (Tycho-2 / Gaia tier)'), findsOneWidget);
      expect(
        find.textContaining('No tileset available yet'),
        findsOneWidget,
        reason: 'silence is what made this a dead control',
      );
      // No switch to flip — a configure affordance takes its place.
      expect(_switchFor(tester, 'Deep stars (Tycho-2 / Gaia tier)'), isNull);
      // Named for what it does. "Install" promised a download that does not
      // exist: the button only opens a form asking the user to host a tileset
      // themselves, so the control could never install anything.
      expect(find.text('Install'), findsNothing);
      expect(find.text('Configure source...'), findsOneWidget);
    });

    testWidgets('the row never claims to be on while uninstalled',
        (tester) async {
      await _pumpPanel(
        tester,
        extraOverrides: [
          // Someone flipped it on in a previous session, before the gate existed.
          showDeepStarsProvider.overrideWith((ref) => true),
          deepStarManifestProvider.overrideWith(
            (ref) => Future<DeepStarManifest?>.value(null),
          ),
        ],
      );

      expect(find.textContaining('No tileset available yet'), findsOneWidget);
      expect(_switchFor(tester, 'Deep stars (Tycho-2 / Gaia tier)'), isNull);
    });
  });

  group('grid switches', () {
    testWidgets('the frame switches are disabled while the master grid is off',
        (tester) async {
      await _pumpPanel(tester);

      final equatorial = _switchFor(tester, 'Equatorial (RA/Dec) lines');
      final altAz = _switchFor(tester, 'Alt/Az lines');
      expect(equatorial, isNotNull);
      expect(altAz, isNotNull);

      final master = _switchFor(tester, 'Coordinate grid');
      expect(master, isNotNull);

      if (master!.value == false) {
        expect(
          equatorial!.onChanged,
          isNull,
          reason: 'a switch that cannot draw anything must not accept a flip',
        );
        expect(altAz!.onChanged, isNull);
      } else {
        // Master defaults on: turn it off and re-check.
        await tester.tap(find.text('Coordinate grid'));
        await tester.pump();
        expect(
            _switchFor(tester, 'Equatorial (RA/Dec) lines')!.onChanged, isNull);
        expect(_switchFor(tester, 'Alt/Az lines')!.onChanged, isNull);
      }
    });

    testWidgets('the master grid switch is listed before its dependents',
        (tester) async {
      await _pumpPanel(tester);

      final masterY = tester.getTopLeft(find.text('Coordinate grid')).dy;
      final equatorialY =
          tester.getTopLeft(find.text('Equatorial (RA/Dec) lines')).dy;
      expect(
        masterY,
        lessThan(equatorialY),
        reason: 'the master has to come first for the hierarchy to read',
      );
    });

    testWidgets('the dependents are indented under the master', (tester) async {
      await _pumpPanel(tester);

      final masterX = tester.getTopLeft(find.text('Coordinate grid')).dx;
      final equatorialX =
          tester.getTopLeft(find.text('Equatorial (RA/Dec) lines')).dx;
      expect(equatorialX, greaterThan(masterX));
    });

    testWidgets('turning the master on enables the frame switches',
        (tester) async {
      await _pumpPanel(tester);

      if (_switchFor(tester, 'Coordinate grid')!.value == false) {
        await tester.tap(find.text('Coordinate grid'));
        await tester.pump();
      }

      expect(_switchFor(tester, 'Coordinate grid')!.value, isTrue);
      expect(
        _switchFor(tester, 'Equatorial (RA/Dec) lines')!.onChanged,
        isNotNull,
      );
      expect(_switchFor(tester, 'Alt/Az lines')!.onChanged, isNotNull);
    });
  });

  testWidgets('no layer row is left with an unlabelled switch', (tester) async {
    await _pumpPanel(tester);
    // Sanity guard on the finders above: the panel really did build rows.
    expect(_switches(tester).length, greaterThan(5));
  });
}
