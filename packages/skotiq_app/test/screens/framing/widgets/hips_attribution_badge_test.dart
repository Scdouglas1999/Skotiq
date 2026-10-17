// Component C8 — guards for the HiPS survey attribution badge.
//
// The badge must display the survey's licence-required credit (parsed from the
// `properties` document into [HipsProperties.obsCopyright], else
// [HipsProperties.creator]) whenever HiPS imagery is visible, and show nothing
// otherwise. These tests pin:
//
//   * shows obs_copyright when visible;
//   * falls back to creator when obs_copyright is absent;
//   * shows NOTHING when not visible (imagery off) or when no credit/properties
//     are published (never invents a credit).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/widgets/hips_attribution_badge.dart';
import 'package:skotiq_core/skotiq_core.dart' show HipsProperties;
// ignore: implementation_imports
import 'package:skotiq_core/src/models/hips/hips_properties.dart'
    show HipsFrame, HipsTileFormat;
import 'package:skotiq_ui/skotiq_ui.dart';

HipsProperties _propsWith({String? copyright, String? creator, String? url}) {
  return HipsProperties(
    hipsOrder: 9,
    hipsOrderMin: 3,
    tileWidth: 512,
    tileWidthWasDefaulted: false,
    tileFormats: const [HipsTileFormat.jpeg],
    frame: HipsFrame.equatorial,
    obsCopyright: copyright,
    obsCopyrightUrl: url,
    creator: creator,
  );
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows obs_copyright credit when visible', (tester) async {
    const credit = 'Digitized Sky Survey (DSS), STScI/NASA';
    await _pump(
      tester,
      HipsAttributionBadge(
        properties: _propsWith(copyright: credit),
        visible: true,
      ),
    );
    expect(find.text(credit), findsOneWidget);
  });

  testWidgets('falls back to creator when obs_copyright is absent',
      (tester) async {
    await _pump(
      tester,
      HipsAttributionBadge(
        properties: _propsWith(creator: 'CDS (Strasbourg)'),
        visible: true,
      ),
    );
    expect(find.text('CDS (Strasbourg)'), findsOneWidget);
  });

  testWidgets('shows nothing when not visible', (tester) async {
    await _pump(
      tester,
      HipsAttributionBadge(
        properties: _propsWith(copyright: 'STScI/NASA'),
        visible: false,
      ),
    );
    expect(find.text('STScI/NASA'), findsNothing);
    expect(find.byType(Icon), findsNothing,
        reason: 'An invisible badge renders no chrome at all.');
  });

  testWidgets('shows nothing when no credit is published', (tester) async {
    await _pump(
      tester,
      HipsAttributionBadge(
        properties: _propsWith(),
        visible: true,
      ),
    );
    expect(find.byType(Icon), findsNothing,
        reason: 'No obs_copyright and no creator → no badge (never invented).');
  });

  testWidgets('shows nothing when properties are null', (tester) async {
    await _pump(
      tester,
      const HipsAttributionBadge(properties: null, visible: true),
    );
    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('credit is tappable (underlined) when an attribution URL exists',
      (tester) async {
    const credit = 'STScI/NASA';
    await _pump(
      tester,
      HipsAttributionBadge(
        properties: _propsWith(
          copyright: credit,
          url: 'https://archive.stsci.edu/dss/',
        ),
        visible: true,
      ),
    );
    // A tappable credit is wrapped in a GestureDetector + the text is underlined.
    expect(
      find.descendant(
        of: find.byType(HipsAttributionBadge),
        matching: find.byType(GestureDetector),
      ),
      findsOneWidget,
    );
    final text = tester.widget<Text>(find.text(credit));
    expect(text.style?.decoration, TextDecoration.underline,
        reason: 'A credit with a URL is shown as a tappable link.');
  });
}
