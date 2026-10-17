import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout.dart';
import 'package:skotiq_app/screens/dashboard/widgets/dashboard_tile.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets(
      'edit controls reserve space and remain clickable in a scroll view',
      (tester) async {
    var resized = 0;
    var hidden = 0;
    var contentTaps = 0;
    await tester.pumpWidget(MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
          body: SingleChildScrollView(child: Builder(builder: (context) {
        return DashboardTileFrame(
          colors: context.skotiqColors,
          isEditing: true,
          isDropTarget: false,
          size: DashboardTileSize.medium,
          onResize: () => resized++,
          onHide: () => hidden++,
          child: TextButton(
              onPressed: () => contentTaps++,
              child: const Text('Panel content')),
        );
      }))),
    ));
    expect(tester.takeException(), isNull);
    final resize = find.byTooltip('Resize (Medium)');
    final hide = find.byTooltip('Hide tile');
    final content = find.text('Panel content');
    expect(tester.getRect(resize).bottom,
        lessThanOrEqualTo(tester.getRect(content).top));
    await tester.tap(resize);
    await tester.tap(hide);
    await tester.tap(content, warnIfMissed: false);
    expect(resized, 1);
    expect(hidden, 1);
    expect(contentTaps, 0);
  });
}
