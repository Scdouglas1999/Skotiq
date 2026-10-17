import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: SkotiqTheme.dark,
  home: Scaffold(body: Center(child: child)),
);

Finder _minusButton() => find.ancestor(
  of: find.byIcon(LucideIcons.minus),
  matching: find.byType(InkWell),
);

Finder _plusButton() => find.ancestor(
  of: find.byIcon(LucideIcons.plus),
  matching: find.byType(InkWell),
);

void main() {
  testWidgets('tapping plus reports value + step', (tester) async {
    int? reported;
    await tester.pumpWidget(
      _wrap(
        SkotiqStepper(value: 5, step: 1, onChanged: (v) => reported = v),
      ),
    );

    await tester.tap(_plusButton());
    await tester.pump();

    expect(reported, 6);
  });

  testWidgets('tapping minus reports value - step', (tester) async {
    int? reported;
    await tester.pumpWidget(
      _wrap(
        SkotiqStepper(value: 5, step: 1, onChanged: (v) => reported = v),
      ),
    );

    await tester.tap(_minusButton());
    await tester.pump();

    expect(reported, 4);
  });

  testWidgets('respects a step larger than 1', (tester) async {
    int? reported;
    await tester.pumpWidget(
      _wrap(
        SkotiqStepper(
          value: 100,
          step: 10,
          max: 999,
          onChanged: (v) => reported = v,
        ),
      ),
    );

    await tester.tap(_plusButton());
    await tester.pump();

    expect(reported, 110);
  });

  testWidgets('minus at min is disabled and fires no callback', (tester) async {
    var fired = false;
    await tester.pumpWidget(
      _wrap(
        SkotiqStepper(value: 1, min: 1, onChanged: (_) => fired = true),
      ),
    );

    final inkWell = tester.widget<InkWell>(_minusButton());
    expect(inkWell.onTap, isNull, reason: 'minus must be disabled at min');

    await tester.tap(_minusButton());
    await tester.pump();
    expect(fired, isFalse);
  });

  testWidgets('plus at max is disabled and fires no callback', (tester) async {
    var fired = false;
    await tester.pumpWidget(
      _wrap(
        SkotiqStepper(value: 10, max: 10, onChanged: (_) => fired = true),
      ),
    );

    final inkWell = tester.widget<InkWell>(_plusButton());
    expect(inkWell.onTap, isNull, reason: 'plus must be disabled at max');

    await tester.tap(_plusButton());
    await tester.pump();
    expect(fired, isFalse);
  });

  testWidgets('emitted values clamp within [min, max]', (tester) async {
    int? reported;
    // step overshoots the upper bound; result must clamp to max.
    await tester.pumpWidget(
      _wrap(
        SkotiqStepper(
          value: 9,
          min: 1,
          max: 10,
          step: 5,
          onChanged: (v) => reported = v,
        ),
      ),
    );

    await tester.tap(_plusButton());
    await tester.pump();
    expect(reported, 10);

    reported = null;
    // step overshoots the lower bound; result must clamp to min.
    await tester.pumpWidget(
      _wrap(
        SkotiqStepper(
          value: 3,
          min: 1,
          max: 10,
          step: 5,
          onChanged: (v) => reported = v,
        ),
      ),
    );

    await tester.tap(_minusButton());
    await tester.pump();
    expect(reported, 1);
  });

  testWidgets('renders the current value as text', (tester) async {
    await tester.pumpWidget(
      _wrap(const SkotiqStepper(value: 42, onChanged: _noop)),
    );

    expect(find.text('42'), findsOneWidget);
  });

  testWidgets('exposes semantic label and value', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _wrap(
          const SkotiqStepper(
            value: 7,
            semanticLabel: 'Exposure count',
            onChanged: _noop,
          ),
        ),
      );
      await tester.pump();

      final node = tester.getSemantics(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'Exposure count',
        ),
      );
      expect(node.value, '7');
    } finally {
      handle.dispose();
    }
  });

  testWidgets('compact mode uses smaller icons', (tester) async {
    await tester.pumpWidget(
      _wrap(const SkotiqStepper(value: 3, compact: true, onChanged: _noop)),
    );

    final icon = tester.widget<Icon>(find.byIcon(LucideIcons.plus));
    expect(icon.size, SkotiqTokens.iconXs);
  });
}

void _noop(int _) {}
