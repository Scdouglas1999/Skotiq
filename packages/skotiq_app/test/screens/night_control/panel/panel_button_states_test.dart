// The Mount, Guide and Solve tabs had their own button (the kit's outlined
// one) beside the quiet button of Overview, Camera and Focus. The one
// button now carries what the other had: a main action, a destructive one,
// an action in flight and a tooltip.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/panel/panel_widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: Center(child: SizedBox(width: 120, child: child))),
      ),
    );

Material _surface(WidgetTester tester) => tester.widget<Material>(
      find.descendant(
        of: find.byType(NightPanelButton),
        matching: find.byType(Material),
      ),
    );

SkotiqColors _colors(WidgetTester tester) =>
    tester.element(find.byType(NightPanelButton)).skotiqColors;

void main() {
  testWidgets('quiet by default, the primary color for the main action',
      (tester) async {
    await _pump(tester, NightPanelButton(label: 'Loop', onPressed: () {}));
    expect(_surface(tester).color, _colors(tester).surfaceElevated);

    await _pump(
      tester,
      NightPanelButton(label: 'Guide', onPressed: () {}, emphasized: true),
    );
    expect(_surface(tester).color, _colors(tester).primary);
    expect(
      tester.widget<Text>(find.text('Guide')).style!.color,
      _colors(tester).onPrimary,
    );
  });

  testWidgets('a destructive action is quiet with its label in the error color',
      (tester) async {
    await _pump(
      tester,
      NightPanelButton(label: 'Park', onPressed: () {}, destructive: true),
    );
    expect(_surface(tester).color, _colors(tester).surfaceElevated);
    expect(
      tester.widget<Text>(find.text('Park')).style!.color,
      _colors(tester).error,
    );
  });

  testWidgets('in flight: a spinner for the label, and a press does nothing',
      (tester) async {
    var presses = 0;
    await _pump(
      tester,
      NightPanelButton(label: 'Slew', onPressed: () => presses++, busy: true),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Slew'), findsNothing);
    await tester.tap(find.byType(NightPanelButton));
    await tester.pump();
    expect(presses, 0);
    final handle = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel('Slew'),
      findsOneWidget,
      reason: 'a screen reader still hears which button it is',
    );
    handle.dispose();
  });

  testWidgets('says why it is disabled, or its caution when enabled',
      (tester) async {
    await _pump(
      tester,
      const NightPanelButton(label: 'Home', disabledReason: 'Mount is parked'),
    );
    expect(tester.widget<Tooltip>(find.byType(Tooltip)).message,
        'Mount is parked');

    await _pump(
      tester,
      NightPanelButton(
        label: 'Home',
        onPressed: () {},
        tooltip: 'Moves the mount',
      ),
    );
    expect(tester.widget<Tooltip>(find.byType(Tooltip)).message,
        'Moves the mount');

    await _pump(tester, NightPanelButton(label: 'Home', onPressed: () {}));
    expect(tester.widget<Tooltip>(find.byType(Tooltip)).message, 'Home');
  });

  // Rebuilt under a new parent when a reason came or went, the guide
  // buttons dropped out of the Linux accessibility tree.
  testWidgets('keeps its place in the tree when it is enabled or disabled',
      (tester) async {
    Future<List<Type>> wrappers(Widget button) async {
      await _pump(tester, button);
      final types = <Type>[];
      tester.element(find.byType(InkWell)).visitAncestorElements((element) {
        if (element.widget is NightPanelButton) return false;
        types.add(element.widget.runtimeType);
        return true;
      });
      return types;
    }

    final enabled =
        await wrappers(NightPanelButton(label: 'Stop', onPressed: () {}));
    final disabled = await wrappers(
      const NightPanelButton(label: 'Stop', disabledReason: 'Not guiding'),
    );
    final bare = await wrappers(const NightPanelButton(label: 'Stop'));
    expect(disabled, enabled);
    expect(bare, enabled);
  });

  testWidgets('a grid of specs renders the one button', (tester) async {
    await _pump(
      tester,
      NightPanelButtonGrid(
        columns: 2,
        buttons: [
          NightPanelButtonSpec(label: 'Slew', onPressed: () {}),
          const NightPanelButtonSpec(
            label: 'Sync here',
            onPressed: null,
            disabledReason: 'Solve first',
            key: ValueKey('sync'),
          ),
        ],
      ),
    );
    expect(find.byType(NightPanelButton), findsNWidgets(2));
    expect(find.byType(SkotiqButton), findsNothing);
    expect(
      tester
          .widget<NightPanelButton>(find.byKey(const ValueKey('sync')))
          .disabledReason,
      'Solve first',
    );
  });
}
