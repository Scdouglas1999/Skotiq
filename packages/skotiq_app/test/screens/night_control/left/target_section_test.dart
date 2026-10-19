// The target block: coordinates, catalog facts, the altitude plot's
// sentence, and a long name that ellipsizes instead of overflowing.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/left/target_section.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../fixtures/night_fixtures.dart';
import 'night_widget_test_support.dart';

Future<void> _pump(
  WidgetTester tester, {
  NightTargetVm? target,
  bool noTarget = false,
  double textScale = 1,
}) async {
  final harness = NightHarness(
    board: NightFixtures.running(),
    target: target,
    noTarget: noTarget,
  );
  await harness.pump(
    tester,
    const SizedBox(width: 272, child: NightTargetSection()),
    size: const Size(272, 758),
    textScale: textScale,
  );
}

NightTargetVm _named(String name, {String? constellation}) {
  final t = NightFixtures.target();
  return NightTargetVm(
    name: name,
    raHours: t.raHours,
    decDegrees: t.decDegrees,
    horizonLimitDeg: t.horizonLimitDeg,
    constellation: constellation ?? t.constellation,
    objectType: t.objectType,
    sizeArcmin: t.sizeArcmin,
    altitudeCurve: t.altitudeCurve,
  );
}

void main() {
  testWidgets('the board target: name, facts and coordinates', (tester) async {
    await _pump(tester);
    expect(find.text('Target · M74'), findsOneWidget);
    expect(find.text("Psc · galaxy 9.9'"), findsOneWidget);
    expect(find.text('01h36m42s'), findsOneWidget);
    expect(find.text('+15°47\'01"'), findsOneWidget);
    expect(find.text('0.4°'), findsOneWidget);
    expect(find.text('62.8°'), findsOneWidget);
    expect(find.text('−0h59m'), findsOneWidget);
    expect(find.text('1.12'), findsOneWidget);
    expect(find.text('moon 44%'), findsOneWidget);
    expect(find.text('flip 01:58'), findsOneWidget);
    expect(find.text('30° limit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the altitude plot reads as one sentence', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    expect(
      find.bySemanticsLabel(
        'M74 altitude over the night: transit 00:51 at 66 degrees, below 30 '
        'degrees after 04:20; moon sets 23:09, meridian flip 01:58',
      ),
      findsOneWidget,
    );
    final chart = tester.widget<SeriesChart>(find.byType(SeriesChart));
    expect(chart.zeroLineY, 30);
    expect(chart.markers.map((m) => m.at), contains(NightFixtures.at(1, 58)));
    handle.dispose();
  });

  testWidgets('unknown values read as a dash, never zero', (tester) async {
    await _pump(tester, target: _named('M74'));
    // Rotation, altitude, hour angle and airmass are unknown.
    expect(find.text('—'), findsNWidgets(4));
    expect(find.text('0.0°'), findsNothing);
  });

  testWidgets('a long target name ellipsizes', (tester) async {
    const name = 'Sh2-155 Cave Nebula with the dark lane and the whole '
        'reflection complex around it';
    for (final scale in const <double>[1, 1.3]) {
      await _pump(
        tester,
        target: _named(name, constellation: 'Cepheus'),
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
      final title = tester.renderObject<RenderParagraph>(
        find.text('Target · $name'),
      );
      expect(title.didExceedMaxLines, isTrue);
      expect(tester.getSize(find.text('Target · $name')).width,
          lessThanOrEqualTo(272));
    }
  });

  testWidgets('no target says so', (tester) async {
    await _pump(tester, noTarget: true);
    expect(find.text('The plan has no target'), findsOneWidget);
    expect(find.byType(SeriesChart), findsNothing);
  });
}
