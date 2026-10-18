// The guiding controls as a compact grid with nothing hidden.
//
// The panel was a bordered card with its own scroll view inside the Guiding
// side panel: Stop, Pause, Loop exposures, Auto select and Deselect stacked as
// full-width 44px buttons, with Dither and Settle settings below the fold of
// the inner scroll and announced only by a fade. It now sizes to its content,
// lays its buttons out in rows of equal cells at the standard control height,
// and leaves scrolling to the column that holds it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/phd2/guide_controls_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The Guiding side panel's content width: 300 less its 16px padding.
const double _sidePanelContentWidth = 268;

Future<void> _pumpPanel(
  WidgetTester tester, {
  double width = _sidePanelContentWidth,
  TargetPlatform platform = TargetPlatform.linux,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(420, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark.copyWith(platform: platform),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: const GuideControlsPanel(
              state: Phd2GuidingState.looping,
              isConnected: true,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Rect _buttonRect(WidgetTester tester, String label) => tester.getRect(
      find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first,
    );

void main() {
  testWidgets('the panel has no scroll view of its own and hides nothing',
      (tester) async {
    await _pumpPanel(tester);

    expect(
      find.descendant(
        of: find.byType(GuideControlsPanel),
        matching: find.byType(Scrollable),
      ),
      findsNothing,
      reason: 'a nested scroll area hid Dither and Settle below its fold',
    );
    for (final label in [
      'Guiding controls',
      'Star selection',
      'Dither',
      'Dither now',
      'Settle settings',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '$label is laid out');
    }
    final panel = tester.getRect(find.byType(GuideControlsPanel));
    expect(panel.height, lessThan(420),
        reason: 'the whole panel fits a laptop side panel with room to spare');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the run controls share one row at standard height on desktop',
      (tester) async {
    await _pumpPanel(tester);

    final stop = _buttonRect(tester, 'Stop');
    final pause = _buttonRect(tester, 'Pause');
    final loop = _buttonRect(tester, 'Loop');
    expect(pause.top, stop.top);
    expect(loop.top, stop.top);
    expect(stop.height, SkotiqTokens.buttonHeight);

    final auto = _buttonRect(tester, 'Auto select');
    final deselect = _buttonRect(tester, 'Deselect');
    expect(deselect.top, auto.top, reason: 'the star controls pair up');
    expect(auto.top, greaterThan(stop.bottom));
  });

  testWidgets('a touch device keeps the platform touch target', (tester) async {
    await _pumpPanel(tester, platform: TargetPlatform.android);

    expect(
      _buttonRect(tester, 'Stop').height,
      greaterThanOrEqualTo(kMinInteractiveDimension),
    );
  });

  testWidgets('a narrow column wraps the grid instead of truncating labels',
      (tester) async {
    await _pumpPanel(tester, width: 200);

    final stop = _buttonRect(tester, 'Stop');
    final loop = _buttonRect(tester, 'Loop');
    expect(loop.top, greaterThan(stop.top),
        reason: 'three cells do not fit 200px, so Loop moves to a new row');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the short Loop label keeps its full name for assistive tech',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpPanel(tester);

    expect(find.bySemanticsLabel('Loop exposures'), findsOneWidget);
    semantics.dispose();
  });
}
