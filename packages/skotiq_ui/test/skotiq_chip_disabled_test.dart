import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A chip the operator cannot choose has to look like one.
///
/// In the Submit-discovery dialog the AAVSO and MPC network chips carry a null
/// `onTap` and are otherwise pixel-identical to an unselected TNS chip, so
/// three dead chips read as three available choices — and the panel's
/// explanation of WHY they are blocked sits under controls that give no sign of
/// being blocked. A null `onTap` also drops the button role, so a screen reader
/// is told nothing at all.
Widget _wrap(Widget child) => MaterialApp(
  theme: SkotiqTheme.dark,
  home: Scaffold(body: Center(child: child)),
);

Container _boxOf(WidgetTester tester) {
  return tester.widget<Container>(
    find.descendant(
      of: find.byType(SkotiqChip),
      matching: find.byType(Container),
    ),
  );
}

Color _labelColor(WidgetTester tester) {
  return tester
      .widget<Text>(
        find.descendant(
          of: find.byType(SkotiqChip),
          matching: find.byType(Text),
        ),
      )
      .style!
      .color!;
}

void main() {
  testWidgets('a disabled chip does not render as an available option', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(SkotiqChip(label: 'AAVSO', onTap: () {}, enabled: false)),
    );
    final disabledLabel = _labelColor(tester);
    // A chip has no border in the Observatory language — the fill IS the
    // boundary — so the dimming that separates a blocked option from an
    // unpicked one has to reach the fill as well as the label.
    final disabledFill = (_boxOf(tester).decoration! as BoxDecoration).color!;

    await tester.pumpWidget(
      _wrap(SkotiqChip(label: 'AAVSO', onTap: () {})),
    );
    await tester.pumpAndSettle();
    final enabledLabel = _labelColor(tester);
    final enabledFill = (_boxOf(tester).decoration! as BoxDecoration).color!;

    expect(
      disabledLabel,
      isNot(enabledLabel),
      reason:
          'A blocked network looked exactly like one the operator had '
          'simply not picked yet.',
    );
    expect(disabledLabel.a, lessThan(enabledLabel.a));
    expect(disabledFill.a, lessThan(enabledFill.a));
  });

  testWidgets('a disabled chip is announced as an unavailable button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      _wrap(SkotiqChip(label: 'MPC', onTap: () {}, enabled: false)),
    );

    expect(
      tester.getSemantics(find.byType(SkotiqChip)),
      matchesSemantics(
        label: 'MPC',
        isButton: true,
        // Saying nothing about availability is how the blocked networks read
        // as available: the node must carry an enabled state, set to false.
        hasEnabledState: true,
        isEnabled: false,
        hasSelectedState: true,
        isSelected: false,
      ),
    );
    handle.dispose();
  });

  // The production shape. The Submit-discovery panel passes BOTH a null onTap
  // (nothing to call) and enabled: false, so the "no onTap means status label"
  // early-out must not swallow the disabled treatment before it is applied.
  testWidgets('a disabled chip with no onTap is still a disabled option', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      _wrap(const SkotiqChip(label: 'AAVSO', enabled: false)),
    );
    final disabledLabel = _labelColor(tester);

    expect(
      tester.getSemantics(find.byType(SkotiqChip)),
      matchesSemantics(
        label: 'AAVSO',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasSelectedState: true,
        isSelected: false,
      ),
    );

    await tester.pumpWidget(
      _wrap(SkotiqChip(label: 'AAVSO', onTap: () {})),
    );
    await tester.pumpAndSettle();
    expect(disabledLabel.a, lessThan(_labelColor(tester).a));
    handle.dispose();
  });

  testWidgets('a disabled chip cannot be tapped', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(SkotiqChip(label: 'MPC', onTap: () => taps++, enabled: false)),
    );

    await tester.tap(find.byType(SkotiqChip), warnIfMissed: false);
    await tester.pump();

    expect(taps, 0);
  });

  testWidgets('a status chip is still a plain label, not a disabled control', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      _wrap(const SkotiqChip(label: 'Keep-set already optimal')),
    );

    // No onTap and enabled: a status readout was never an option, so it must
    // not acquire a button role just because the disabled path exists.
    expect(
      find.descendant(
        of: find.byType(SkotiqChip),
        matching: find.byType(Semantics),
      ),
      findsNothing,
    );
    handle.dispose();
  });
}
