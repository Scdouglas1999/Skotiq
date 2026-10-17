// Regressions for two planetarium HUD surfaces that printed unreadable or
// ambiguous labels.
//
//  * At 900x700 the bottom info bar rendered
//    'Center: 0h 0m 0s   Center: +0d   FOV: 60.0d' — the compact path took the
//    first WORD of each label, so 'Center RA' and 'Center Dec' both collapsed to
//    'Center', leaving two adjacent identically-labelled fields holding
//    different quantities.
//
//  * The object popup crammed a Slew dropdown plus 'Framing' and 'Sequence'
//    into one ~300px row, so at 1920x1200 three of five action labels rendered
//    as 'Frami...', 'Sequ...' and 'Log Observati...'. A truncated control label
//    is not a legible control, and 'Sequ...' at 2am is genuinely ambiguous.
//
// The action labels below are the popup's CURRENT copy. The Observatory pass
// put every button in sentence case (06 §Copy: "Frame type", not "Frame
// Type"), so 'Log Observation', 'Target Queue' and 'Add to List' became
// 'Log observation', 'Target queue' and 'Add to list'; these assertions name
// the strings on screen so a rename cannot quietly take the guard with it.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/bottom_info_bar.dart';
import 'package:skotiq_app/screens/planetarium/widgets/object_info_popup.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../golden/surface_golden_harness.dart';
import '../../harness/pump_app_screen.dart';

const _object = Star(
  id: 'HIP42327',
  name: 'HIP42327',
  coordinates: CelestialCoordinate(ra: 8.6296, dec: 19.2672),
  magnitude: 4.9,
);

/// True when [label] was painted narrower than the width its text needs, i.e.
/// Flutter had to ellipsize it.
bool _isTruncated(WidgetTester tester, String label) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
  // Half-pixel slack: layout widths are not bit-exact against intrinsics.
  return paragraph.size.width + 0.5 <
      paragraph.getMaxIntrinsicWidth(double.infinity);
}

/// Pumps the bar and runs [body], then unmounts and disposes explicitly.
///
/// The bar watches `sunAltitudeProvider`, which pulls in `observationTimeProvider`
/// and its 1 s `Timer.periodic` sky clock. That timer outlives the widget tree,
/// so the test has to tear the tree down and dispose the container itself or the
/// binding trips its "A Timer is still pending" invariant.
Future<void> _withBar(
  WidgetTester tester,
  Size size,
  Future<void> Function() body,
) async {
  final handle = await pumpAppScreen(
    tester,
    BottomInfoBar(colors: SkotiqTheme.dark.extension<SkotiqColors>()!),
    size: size,
    settle: false,
    registerTearDown: false,
  );
  try {
    await tester.pump();
    await body();
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    handle.container.dispose();
    await handle.database.close();
    await tester.pump(const Duration(milliseconds: 1));
  }
}

/// Pumps the popup and runs [body], then unmounts and disposes explicitly.
///
/// Same hazard as [_withBar]: the popup's "Current Position" block reads the
/// planetarium clock, so mounting it starts `observationTimeProvider`'s 1 s
/// `Timer.periodic`, which outlives the widget tree.
Future<void> _withPopup(
  WidgetTester tester,
  Size size,
  Future<void> Function() body,
) async {
  final handle = await pumpAppScreen(
    tester,
    Stack(
      children: [
        ObjectInfoPopup(
          colors: SkotiqTheme.dark.extension<SkotiqColors>()!,
          object: _object,
          coordinates: _object.coordinates,
          position: Offset(size.width / 2, size.height / 2),
          onDismiss: () {},
          onSendToFraming: () {},
          onAddToSequencer: () {},
          onAddToQueue: () {},
          onSlewToTarget: () {},
          onSlewAndCenter: () {},
          onSlewCenterRotate: () {},
          hasRotator: false,
        ),
      ],
    ),
    size: size,
    settle: false,
    registerTearDown: false,
  );
  try {
    await tester.pumpAndSettle();
    await body();
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    handle.container.dispose();
    await handle.database.close();
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  // Real bundled fonts, not the test font. flutter_test's default typeface makes
  // every glyph a square of the font size, so 'Add to list' would measure ~143px
  // where HankenGrotesk needs ~62px — the widths this test asserts on only mean
  // anything against the typeface the product actually ships.
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  group('bottom info bar', () {
    testWidgets('never prints two fields under the same compact label',
        (tester) async {
      await _withBar(tester, const Size(880, 700), () async {
        expect(
          find.text('Center:'),
          findsNothing,
          reason: 'two adjacent fields both labelled "Center:" is worse than '
              'either full labels or bare values',
        );
        expect(find.text('RA:'), findsOneWidget);
        expect(find.text('Dec:'), findsOneWidget);
        expect(
          find.text('FOV (short):'),
          findsOneWidget,
          reason: 'compacting to a bare "FOV:" drops the short-axis qualifier '
              'the full label exists to state',
        );
      });
    });

    testWidgets('spells the coordinate labels out when there is room',
        (tester) async {
      await _withBar(tester, const Size(1600, 900), () async {
        expect(find.text('Center RA:'), findsOneWidget);
        expect(find.text('Center Dec:'), findsOneWidget);
      });
    });

    for (final size in const [
      Size(700, 700),
      Size(880, 700),
      Size(1280, 800),
      Size(1920, 1200),
    ]) {
      testWidgets(
          'no label in the bar is truncated at '
          '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await _withBar(tester, size, () async {
          for (final text in tester.widgetList<Text>(find.byType(Text))) {
            final data = text.data;
            if (data == null) continue;
            expect(
              _isTruncated(tester, data),
              isFalse,
              reason: '"$data" is ellipsized at ${size.width}x${size.height}',
            );
          }
        });
      });
    }
  });

  group('object info popup actions', () {
    testWidgets('no action label is truncated at 1920x1200', (tester) async {
      await _withPopup(tester, const Size(1920, 1200), () async {
        for (final label in const [
          'Framing',
          'Sequence',
          'Log observation',
          'Add to list',
          'Target queue',
        ]) {
          expect(find.text(label), findsOneWidget, reason: '$label is missing');
          expect(
            _isTruncated(tester, label),
            isFalse,
            reason: '"$label" is ellipsized — this is exactly the "Frami.../'
                'Sequ..." defect',
          );
        }
      });
    });

    testWidgets('nor at a laptop size', (tester) async {
      await _withPopup(tester, const Size(1366, 768), () async {
        for (final label in const [
          'Framing',
          'Sequence',
          'Log observation',
          'Add to list',
          'Target queue',
        ]) {
          expect(
            _isTruncated(tester, label),
            isFalse,
            reason: '"$label" is ellipsized at 1366x768',
          );
        }
      });
    });

    testWidgets('at most two actions share a row', (tester) async {
      await _withPopup(tester, const Size(1920, 1200), () async {
        final rows = <double, int>{};
        for (final label in const [
          'Framing',
          'Sequence',
          'Log observation',
          'Add to list',
          'Target queue',
        ]) {
          // Round to absorb sub-pixel differences between siblings.
          final y = tester.getTopLeft(find.text(label)).dy.roundToDouble();
          rows[y] = (rows[y] ?? 0) + 1;
        }
        expect(
          rows.values,
          everyElement(lessThanOrEqualTo(2)),
          reason: 'three-up is what squeezed the labels to ~87px each',
        );
      });
    });
  });
}
