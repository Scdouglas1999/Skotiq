import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _stats = [
  ResponsiveStat(label: 'RMS Total', value: '0.62"'),
  ResponsiveStat(label: 'RMS RA', value: '0.41"'),
  ResponsiveStat(label: 'RMS Dec', value: '0.47"'),
  ResponsiveStat(label: 'HFR', value: '2.13px'),
  ResponsiveStat(label: 'Frames', value: '34/120'),
  ResponsiveStat(label: 'Exposure', value: '300s'),
];

Widget _host({double width = 360, List<ResponsiveStat>? stats}) {
  return MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: ResponsiveStatStrip(stats: stats ?? _stats),
        ),
      ),
    ),
  );
}

Future<void> _pumpAt(WidgetTester tester, Size size, Widget child) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(child);
  await tester.pumpAndSettle();
}

void main() {
  final sizes = <String, Size>{
    '360x640 portrait': const Size(360, 640),
    '640x360 landscape': const Size(640, 360),
    '390x844 portrait': const Size(390, 844),
    '844x390 landscape': const Size(844, 390),
  };

  for (final entry in sizes.entries) {
    testWidgets('no overflow at ${entry.key}', (tester) async {
      await _pumpAt(tester, entry.value, _host(width: entry.value.width));
      expect(tester.takeException(), isNull);
      // All stats are rendered (reflowed, not dropped).
      expect(find.text('0.62"'), findsOneWidget);
      expect(find.text('34/120'), findsOneWidget);
    });
  }

  testWidgets('reflows to a wrap when stats do not fit one row', (
    tester,
  ) async {
    await _pumpAt(tester, const Size(360, 640), _host(width: 320));
    // The strip uses a Wrap (multiple runs) rather than a single Row.
    final wrap = find.descendant(
      of: find.byType(ResponsiveStatStrip),
      matching: find.byType(Wrap),
    );
    expect(wrap, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stays on one Row when everything fits', (tester) async {
    await _pumpAt(
      tester,
      const Size(1000, 600),
      _host(
        width: 980,
        stats: const [
          ResponsiveStat(label: 'A', value: '1'),
          ResponsiveStat(label: 'B', value: '2'),
        ],
      ),
    );
    final wrap = find.descendant(
      of: find.byType(ResponsiveStatStrip),
      matching: find.byType(Wrap),
    );
    expect(wrap, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('values keep a legible (>=13sp) font', (tester) async {
    await _pumpAt(tester, const Size(360, 640), _host(width: 320));
    final valueText = tester.widget<Text>(find.text('0.62"'));
    expect(valueText.style!.fontSize, greaterThanOrEqualTo(13));
  });
}
