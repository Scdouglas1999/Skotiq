import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/widgets/narrowband_mixer_panel.dart'
    as nb;

/// The mixer must never present a matrix that combines to black.
///
/// The masters load asynchronously, so the panel is built first with an empty
/// channel list and the real Ha/OIII/SII arrive in a later rebuild. These tests
/// drive that exact sequence and read the rendered combine matrix, which is
/// what the operator actually sees.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(List<nb.NarrowbandChannelRef> channels) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: nb.NarrowbandMixerPanel(
            channels: channels,
            onApply: (_, __) {},
          ),
        ),
      ),
    );
  }

  const ha = nb.NarrowbandChannelRef(masterId: 1, filter: 'Ha', label: 'Ha');
  const oiii =
      nb.NarrowbandChannelRef(masterId: 2, filter: 'OIII', label: 'OIII');
  const sii = nb.NarrowbandChannelRef(masterId: 3, filter: 'SII', label: 'SII');

  /// Every weight the matrix preview is rendering, in row-major order.
  List<double> renderedWeights(WidgetTester tester) {
    final matrix = find.textContaining(RegExp(r'->\s+R '));
    final values = <double>[];
    for (final widget in tester.widgetList<Text>(matrix)) {
      for (final match
          in RegExp(r'[RGB] (\d+\.\d\d)').allMatches(widget.data ?? '')) {
        values.add(double.parse(match.group(1)!));
      }
    }
    return values;
  }

  testWidgets('channels arriving after the first build seed SHO, not zeros',
      (tester) async {
    await tester.pumpWidget(host(const []));
    await tester.pump();

    await tester.pumpWidget(host(const [ha, oiii, sii]));
    await tester.pump();

    expect(find.text('SHO preset'), findsOneWidget);
    expect(find.text('Custom mix'), findsNothing);
    // SHO → R=SII, G=Ha, B=OIII, in channel order Ha / OIII / SII.
    expect(renderedWeights(tester), [0, 1, 0, 0, 0, 1, 1, 0, 0]);
  });

  testWidgets('a bicolor Ha+OIII set resolves to HOO, not a red-less SHO',
      (tester) async {
    await tester.pumpWidget(host(const []));
    await tester.pump();
    await tester.pumpWidget(host(const [ha, oiii]));
    await tester.pump();

    expect(find.text('HOO preset'), findsOneWidget);
    // HOO → R=Ha, G=B=OIII. A partially-applied SHO would leave R at 0.00.
    expect(renderedWeights(tester), [1, 0, 0, 0, 1, 1]);
  });

  testWidgets('a set no palette covers still opens on a visible mapping',
      (tester) async {
    const nii =
        nb.NarrowbandChannelRef(masterId: 4, filter: 'NII', label: 'N2');
    await tester.pumpWidget(host(const []));
    await tester.pump();
    await tester.pumpWidget(host(const [nii]));
    await tester.pump();

    // Luminance, not black.
    expect(renderedWeights(tester), [1, 1, 1]);
  });

  testWidgets('swapping one channel re-seeds even when the count is unchanged',
      (tester) async {
    await tester.pumpWidget(host(const [ha, oiii, sii]));
    await tester.pump();
    expect(find.text('SHO preset'), findsOneWidget);

    // Same length, different set — SHO is no longer satisfiable.
    const hb = nb.NarrowbandChannelRef(masterId: 5, filter: 'Hb', label: 'Hb');
    await tester.pumpWidget(host(const [ha, oiii, hb]));
    await tester.pump();

    expect(find.text('HOO preset'), findsOneWidget);
    expect(renderedWeights(tester), [1, 0, 0, 0, 1, 1, 0, 0, 0]);
  });
}
