import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  Future<void> pumpGallery(
    WidgetTester tester, {
    required ThemeData theme,
    required Size size,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(theme: theme, home: const SkotiqDesignSystemGallery()),
    );
    await tester.pump();
  }

  testWidgets('renders core component gallery in dark theme', (tester) async {
    await pumpGallery(
      tester,
      theme: SkotiqTheme.dark,
      size: const Size(1280, 1500),
    );

    expect(find.text('Design System Gallery'), findsOneWidget);
    expect(find.text('Color Palette'), findsOneWidget);
    expect(find.text('Typography'), findsOneWidget);
    expect(find.text('readoutLg — hero numbers'), findsOneWidget);
    // Every remaining section is a component from 05 (plus the palette and
    // type reference). The pre-Observatory ones are gone, and none of them is
    // shown twice: the sheet's own sections are what the gallery teaches.
    for (final retired in const <String>[
      'Cards',
      'Tabs',
      'Navigation',
      'Decorations',
      'Chips and Status Pills',
      'Alerts',
      'Buttons',
      'Inputs',
      'Status Dots',
    ]) {
      expect(find.text(retired), findsNothing, reason: '"$retired" is retired');
    }
    expect(find.text('Buttons and icon buttons'), findsOneWidget);
    expect(find.text('Fields and form rows'), findsOneWidget);
    expect(find.text('Panels and wells'), findsOneWidget);
    expect(find.text('Readouts'), findsOneWidget);
    expect(find.text('Underline tabs'), findsOneWidget);
    expect(find.text('Chips and status dots'), findsOneWidget);
    expect(find.text('Banner'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('gallery-button-primary')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('gallery-dropdown')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('gallery-instrument-pill')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders compact width without build errors', (tester) async {
    await pumpGallery(
      tester,
      theme: SkotiqTheme.light,
      size: const Size(390, 900),
    );

    expect(find.text('Buttons and icon buttons'), findsOneWidget);
    expect(find.text('Fields and form rows'), findsOneWidget);
    expect(find.text('Banner'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders red night theme gallery', (tester) async {
    await pumpGallery(
      tester,
      theme: SkotiqTheme.redNight,
      size: const Size(900, 900),
    );

    expect(find.text('Chips and status dots'), findsOneWidget);
    expect(find.text('Night band'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gallery controls update representative states', (tester) async {
    await pumpGallery(
      tester,
      theme: SkotiqTheme.dark,
      size: const Size(1280, 2200),
    );

    expect(find.text('Observatory sample actions: 0'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey('gallery-button-primary')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('gallery-button-primary')));
    await tester.pump();
    expect(find.text('Observatory sample actions: 1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('gallery-button-secondary')));
    await tester.pump();
    expect(find.text('Observatory sample actions: 2'), findsOneWidget);

    expect(
      tester
          .widget<SkotiqDropdown>(
            find.byKey(const ValueKey('gallery-dropdown')),
          )
          .value,
      'Light',
    );
    // `pump`, never `pumpAndSettle`: the gallery renders a shimmer, which by
    // design never settles. The extra frame is the popover's 120ms fade.
    await tester.ensureVisible(find.byKey(const ValueKey('gallery-dropdown')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('gallery-dropdown')));
    await tester.pump();
    await tester.pump(SkotiqTokens.durationSmooth);
    await tester.tap(find.text('Dark').last);
    await tester.pump();
    await tester.pump(SkotiqTokens.durationSmooth);
    expect(
      tester
          .widget<SkotiqDropdown>(
            find.byKey(const ValueKey('gallery-dropdown')),
          )
          .value,
      'Dark',
    );

    expect(
      tester.widget<SkotiqCheckbox>(find.byType(SkotiqCheckbox)).value,
      isTrue,
    );
    await tester.ensureVisible(find.byType(SkotiqCheckbox));
    await tester.pump();
    await tester.tap(find.byType(SkotiqCheckbox));
    await tester.pump();
    expect(
      tester.widget<SkotiqCheckbox>(find.byType(SkotiqCheckbox)).value,
      isFalse,
    );

    expect(
      tester
          .widget<SkotiqSwitch>(find.byKey(const ValueKey('gallery-switch')))
          .value,
      isTrue,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('gallery-switch')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('gallery-switch')));
    await tester.pump();
    expect(
      tester
          .widget<SkotiqSwitch>(find.byKey(const ValueKey('gallery-switch')))
          .value,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}
