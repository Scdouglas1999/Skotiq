// The seven affordances a merged wave-3 screen had to work around.
//
// Each of these shipped as a local hack on some screen because the kit had no
// slot for it: Equipment drew a solid outline where 06 asks for a dashed empty
// slot, Sequencer hand-rolled a count beside its Preflight button and clamped
// its own label column, Tonight used a null Readout to mean "not connected"
// and a bare mono Text for the number inside its progress ring, and the night
// band's legend overlapped itself at 700px. One kit slot each, pinned here.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  Widget host(Widget child, {double width = 400}) => MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  );

  group('SkotiqPanel(dashed:)', () {
    testWidgets('an empty slot paints a dashed outline and no fill', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const SkotiqPanel(dashed: true, child: Text('Empty slot'))),
      );

      // No `Container` decoration at all: the slot has no fill, and the
      // outline is stroked rather than declared as a Border.
      expect(
        find.descendant(
          of: find.byType(SkotiqPanel),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );
      expect(find.text('Empty slot'), findsOneWidget);
    });

    testWidgets('a selected panel is never dashed', (tester) async {
      await tester.pumpWidget(
        host(
          const SkotiqPanel(
            dashed: true,
            selected: true,
            child: Text('Chosen'),
          ),
        ),
      );

      const colors = SkotiqColors.dark;
      final decoration = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(SkotiqPanel),
              matching: find.byType(Container),
            ),
          )
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .first;
      expect(decoration.color, colors.surface);
      expect(
        decoration.border!.top.color,
        colors.primary.withValues(alpha: SkotiqTokens.opacitySelectedRing),
      );
    });
  });

  group('SkotiqButton(badge:)', () {
    testWidgets('the count is inside the button, and inside its name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          SkotiqButton(
            label: 'Preflight',
            variant: ButtonVariant.secondary,
            badge: '2',
            badgeSemanticsLabel: '2 issues',
            badgeTone: ChipTone.warning,
            onPressed: () {},
          ),
        ),
      );

      expect(find.text('2'), findsOneWidget);
      // Inside the button's own box, so it is pressable with the button and
      // not a second control beside it.
      final button = tester.getRect(find.byType(SkotiqButton));
      final badge = tester.getRect(find.text('2'));
      expect(button.contains(badge.center), isTrue);

      final semantics = tester.getSemantics(find.byType(SkotiqButton));
      // `contains`, not equality: the button's own `Text` merges into this
      // node too, so the label reads "Preflight, 2 issues\nPreflight". That
      // duplication predates the badge — see reports/observatory/w4-kit.
      expect(
        semantics.label,
        contains('Preflight, 2 issues'),
        reason: 'a screen reader that hears "Preflight, 2" learns nothing',
      );
      handle.dispose();
    });

    testWidgets('no badge means no extra box', (tester) async {
      await tester.pumpWidget(
        host(SkotiqButton(label: 'Preflight', onPressed: () {})),
      );
      expect(find.text('2'), findsNothing);
      final semantics = tester.getSemantics(find.byType(SkotiqButton));
      expect(semantics.label, contains('Preflight'));
      expect(semantics.label, isNot(contains('issues')));
    });
  });

  group('FormRow(labelWidth:)', () {
    test('the label column gives way before the row overflows', () {
      // A side panel animating 48 -> 300px passes through every width in
      // between; none of them may overflow.
      for (var width = 48.0; width <= 300; width += 4) {
        final resolved = FormRow.resolveLabelWidth(
          FormRow.defaultLabelWidth,
          width,
        );
        expect(
          resolved,
          lessThanOrEqualTo(FormRow.defaultLabelWidth),
          reason: 'the column never grows past what the form asked for',
        );
        expect(resolved, greaterThanOrEqualTo(FormRow.minLabelWidth));
        if (width >=
            FormRow.defaultLabelWidth +
                FormRow.columnGap +
                FormRow.minControlWidth) {
          expect(
            resolved,
            FormRow.defaultLabelWidth,
            reason: 'a pane with room keeps the width the form chose',
          );
        }
      }
    });

    testWidgets('a 150px pane lays the row out without overflowing', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          width: 150,
          const FormRow(
            label: 'Exposure',
            child: SkotiqTextField(initialValue: '120', mono: true),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(FormRow)).width, 150);
    });
  });

  group('NightBand legend', () {
    NightBand band() {
      final sunset = DateTime(2026, 9, 9, 19, 12);
      return NightBand(
        sunset: sunset,
        astroDark: DateTime(2026, 9, 9, 20, 48),
        astroDawn: DateTime(2026, 9, 10, 4, 51),
        sunrise: DateTime(2026, 9, 10, 6, 24),
        now: DateTime(2026, 9, 9, 22, 41),
        events: <NightBandEvent>[
          NightBandEvent(time: sunset, label: '19:12 sunset'),
          NightBandEvent(
            time: DateTime(2026, 9, 9, 20, 48),
            label: '20:48 astro dark',
          ),
          NightBandEvent(
            time: DateTime(2026, 9, 10, 4, 51),
            label: '04:51 astro dawn',
          ),
          NightBandEvent(
            time: DateTime(2026, 9, 10, 6, 24),
            label: '06:24 sunrise',
          ),
        ],
      );
    }

    testWidgets('a wide band names every event', (tester) async {
      // The default 800px test surface is itself under the compact threshold,
      // so the wide case has to widen the window, not just the box.
      tester.view.physicalSize = const Size(1400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(host(band(), width: 1200));
      expect(find.text('20:48 astro dark'), findsOneWidget);
      expect(find.text('04:51 astro dawn'), findsOneWidget);
    });

    testWidgets('a narrow band keeps only sunset and sunrise', (tester) async {
      await tester.pumpWidget(host(band(), width: 660));
      expect(find.text('19:12 sunset'), findsOneWidget);
      expect(find.text('06:24 sunrise'), findsOneWidget);
      expect(
        find.text('20:48 astro dark'),
        findsNothing,
        reason:
            'the middle labels overlapped into a smear at 700px, and the '
            'canvas already draws those two moments as dashed verticals',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('DeviceRow(trailing:)', () {
    testWidgets('a device with nothing to report says so in a word', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const DeviceRow(name: 'Mount', trailing: Text('Not connected'))),
      );
      expect(find.text('Not connected'), findsOneWidget);
      expect(
        find.text(kReadoutUnknown),
        findsNothing,
        reason:
            'a row of em dashes says "three things I cannot measure" '
            'where the truth is one thing',
      );
    });
  });

  group('Readout(label: null)', () {
    testWidgets('a bare value reserves no row for a label', (tester) async {
      await tester.pumpWidget(
        host(const Readout(value: '61%', size: ReadoutSize.sm)),
      );
      final bare = tester.getSize(find.byType(Readout)).height;

      await tester.pumpWidget(
        host(
          const Readout(value: '61%', label: 'Progress', size: ReadoutSize.sm),
        ),
      );
      final labelled = tester.getSize(find.byType(Readout)).height;

      expect(
        bare,
        lessThan(labelled),
        reason:
            'the label row must not be reserved when there is no label; '
            'the ring centres the value on nothing otherwise',
      );
      expect(find.text('PROGRESS'), findsOneWidget);
    });

    testWidgets('a bare value keeps the readout face', (tester) async {
      await tester.pumpWidget(
        host(const Readout(value: '61%', size: ReadoutSize.sm)),
      );
      final paragraph = tester.renderObject<RenderParagraph>(find.text('61%'));
      expect(
        paragraph.text.style!.fontFamily,
        SkotiqTypography.readoutSm.fontFamily,
        reason:
            'the point of a label-less readout is that the call site does '
            'not fall back to a bare mono TextStyle',
      );
    });
  });

  group('SkotiqDecorations.panelTinted / chip(radius:)', () {
    testWidgets('a tinted panel is the panel radius with a toned ring', (
      tester,
    ) async {
      const colors = SkotiqColors.dark;
      final decoration = SkotiqDecorations.panelTinted(
        colors,
        tone: colors.warning,
      );
      expect(
        decoration.color,
        colors.warning.withValues(alpha: SkotiqTokens.opacityStatusFill),
      );
      expect(
        decoration.border!.top.color,
        colors.warning.withValues(alpha: SkotiqTokens.opacitySelectedRing),
      );
      expect(
        (decoration.borderRadius! as BorderRadius).topLeft.x,
        SkotiqTokens.radiusLg,
      );
    });

    test('a chip can be asked for a square badge radius', () {
      const colors = SkotiqColors.dark;
      final badge = SkotiqDecorations.chip(
        colors,
        tone: colors.success,
        radius: SkotiqTokens.radiusLg,
      );
      expect(
        (badge.borderRadius! as BorderRadius).topLeft.x,
        SkotiqTokens.radiusLg,
      );
      expect(
        SkotiqDecorations.chip(colors, tone: colors.success).borderRadius,
        BorderRadius.circular(SkotiqTokens.radiusXs),
      );
    });
  });
}
