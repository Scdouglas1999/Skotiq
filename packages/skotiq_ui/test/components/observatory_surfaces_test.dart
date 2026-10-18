import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _host(Widget child, {bool disableAnimations = false, Size? size}) =>
    MaterialApp(
      theme: SkotiqTheme.dark.copyWith(platform: TargetPlatform.linux),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: disableAnimations),
          child: Scaffold(
            body: Center(
              child: size == null
                  ? child
                  : SizedBox(
                      width: size.width,
                      height: size.height,
                      child: child,
                    ),
            ),
          ),
        ),
      ),
    );

void main() {
  group('AdaptiveTabBar', () {
    testWidgets('the underline spans the label plus 2px each side', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            height: 40,
            child: AdaptiveTabBar(
              horizontalPadding: 0,
              collapseLabelsWhenTight: false,
              tabs: const <AdaptiveTab>[
                AdaptiveTab(label: 'Builder'),
                AdaptiveTab(label: 'Templates'),
              ],
              selectedIndex: 0,
              onSelected: (_) {},
            ),
          ),
          size: const Size(600, 40),
        ),
      );
      await tester.pumpAndSettle();

      final labelWidth = tester.getSize(find.text('Builder')).width;
      // The indicator is the only box in the bar painted a flat `primary`.
      // (`find.byType(IgnorePointer)` would also match the Scrollable's own.)
      final indicator = find.descendant(
        of: find.byType(AdaptiveTabBar),
        matching: find.byWidgetPredicate(
          (w) => w is Container && w.color == SkotiqColors.dark.primary,
        ),
      );
      final indicatorSize = tester.getSize(indicator);
      expect(indicatorSize.height, AdaptiveTabBar.indicatorThickness);
      final indicatorWidth = indicatorSize.width;

      expect(
        indicatorWidth,
        closeTo(labelWidth + 2 * AdaptiveTabBar.tabPadding, 0.5),
      );
    });

    testWidgets('only the selected tab is marked, and its ink is loudest', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            height: 40,
            child: AdaptiveTabBar(
              horizontalPadding: 0,
              collapseLabelsWhenTight: false,
              tabs: const <AdaptiveTab>[
                AdaptiveTab(label: 'Builder'),
                AdaptiveTab(label: 'Templates'),
              ],
              selectedIndex: 1,
              onSelected: (_) {},
            ),
          ),
          size: const Size(600, 40),
        ),
      );
      await tester.pumpAndSettle();

      final colors = SkotiqColors.dark;
      expect(
        tester.widget<Text>(find.text('Templates')).style!.color,
        colors.textPrimary,
      );
      expect(
        tester.widget<Text>(find.text('Builder')).style!.color,
        colors.textMuted,
      );
    });
  });

  group('SegmentedControl', () {
    testWidgets('the selected segment takes the hover fill, others muted', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SegmentedControl(
            segments: const <String>['Nodes', 'Snippets'],
            selectedIndex: 0,
            onSelected: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final colors = SkotiqColors.dark;
      expect(
        tester.widget<Text>(find.text('Nodes')).style!.color,
        colors.textPrimary,
      );
      expect(
        tester.widget<Text>(find.text('Snippets')).style!.color,
        colors.textMuted,
      );
      expect(
        tester.getSize(find.text('Nodes')).height,
        lessThan(SegmentedControl.segmentHeight),
      );
    });

    testWidgets('tapping reports the index', (tester) async {
      var picked = -1;
      await tester.pumpWidget(
        _host(
          SegmentedControl(
            segments: const <String>['Nodes', 'Snippets'],
            selectedIndex: 0,
            onSelected: (i) => picked = i,
          ),
        ),
      );
      await tester.tap(find.text('Snippets'));
      expect(picked, 1);
    });
  });

  group('Checklist', () {
    testWidgets('a done step is struck through and a todo step is not', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 420,
            child: Checklist(
              steps: <ChecklistStep>[
                ChecklistStep(
                  title: 'Set your observing site',
                  state: ChecklistStepState.done,
                ),
                ChecklistStep(
                  title: 'Connect a camera',
                  state: ChecklistStepState.next,
                ),
                ChecklistStep(title: 'Install the catalogs'),
              ],
            ),
          ),
        ),
      );

      final colors = SkotiqColors.dark;
      final done = tester.widget<Text>(find.text('Set your observing site'));
      expect(done.style!.decoration, TextDecoration.lineThrough);
      expect(done.style!.color, colors.textSecondary);

      for (final title in <String>[
        'Connect a camera',
        'Install the catalogs',
      ]) {
        final open = tester.widget<Text>(find.text(title));
        expect(open.style!.decoration, isNot(TextDecoration.lineThrough));
        expect(open.style!.color, colors.textPrimary);
      }
    });

    testWidgets('the next step carries the halo and the others do not', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 420,
            child: Checklist(
              steps: <ChecklistStep>[
                ChecklistStep(title: 'One', state: ChecklistStepState.next),
                ChecklistStep(title: 'Two'),
              ],
            ),
          ),
        ),
      );

      final discs = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(Checklist),
              matching: find.byType(Container),
            ),
          )
          .where(
            (c) =>
                c.decoration is BoxDecoration &&
                (c.decoration! as BoxDecoration).shape == BoxShape.circle,
          )
          .toList();

      expect(discs, hasLength(2));
      expect((discs.first.decoration! as BoxDecoration).boxShadow, isNotNull);
      expect((discs.last.decoration! as BoxDecoration).boxShadow, isNull);
    });
  });

  group('SidePanel', () {
    testWidgets('the strip marks the selected section and reports taps', (
      tester,
    ) async {
      var picked = -1;
      await tester.pumpWidget(
        _host(
          SidePanel(
            sections: const <SidePanelSection>[
              SidePanelSection(icon: LucideIcons.sliders, tooltip: 'Capture'),
              SidePanelSection(icon: LucideIcons.target, tooltip: 'Target'),
            ],
            selectedSection: 1,
            onSectionSelected: (i) => picked = i,
            child: const Text('body'),
          ),
          size: const Size(320, 300),
        ),
      );

      final buttons = tester
          .widgetList<SkotiqIconButton>(find.byType(SkotiqIconButton))
          .toList();
      expect(buttons, hasLength(2));
      expect(buttons[0].selected, isFalse);
      expect(buttons[1].selected, isTrue);
      expect(buttons.every((b) => b.size == IconButtonSize.strip), isTrue);

      await tester.tap(find.bySemanticsLabel('Capture'));
      expect(picked, 0);
    });

    testWidgets('strip hover labels sit to the left, centred on the icon', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _host(
          Align(
            alignment: Alignment.centerRight,
            child: SidePanel(
              sections: const <SidePanelSection>[
                SidePanelSection(icon: LucideIcons.camera, tooltip: 'Capture'),
                SidePanelSection(
                  icon: LucideIcons.thermometer,
                  tooltip: 'Camera',
                ),
              ],
              child: const Text('body'),
            ),
          ),
          size: const Size(800, 600),
        ),
      );

      final button = tester.getRect(find.bySemanticsLabel('Capture'));
      await tester.longPress(find.bySemanticsLabel('Capture'));
      await tester.pumpAndSettle();

      final label = tester.getRect(find.text('Capture'));
      expect(
        label.center.dy,
        closeTo(button.center.dy, 2.0),
        reason: 'strip tooltip must share a centre line with its icon',
      );
      expect(
        label.right,
        lessThanOrEqualTo(button.left + 1.0),
        reason: 'strip tooltip belongs to the left of a right-edge icon',
      );

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('without sections there is no strip', (tester) async {
      await tester.pumpWidget(
        _host(const SidePanel(child: Text('body')), size: const Size(320, 300)),
      );
      expect(find.byType(SkotiqIconButton), findsNothing);
    });
  });

  group('NightBand', () {
    testWidgets('the now marker lands at the right fraction of the night', (
      tester,
    ) async {
      final sunset = DateTime(2026, 9, 9, 19);
      final sunrise = DateTime(2026, 9, 10, 7);
      // Exactly a quarter of a 12-hour night.
      final now = DateTime(2026, 9, 9, 22);
      final band = NightBand(
        sunset: sunset,
        astroDark: DateTime(2026, 9, 9, 21),
        astroDawn: DateTime(2026, 9, 10, 5),
        sunrise: sunrise,
        now: now,
      );

      expect(band.fractionOf(now), closeTo(0.25, 1e-9));
      expect(band.fractionOf(sunset), 0);
      expect(band.fractionOf(sunrise), 1);
      // Before sunset and after sunrise clamp rather than running off the
      // canvas: a marker painted outside the band is worse than one pinned to
      // its edge.
      expect(band.fractionOf(sunset.subtract(const Duration(hours: 2))), 0);
      expect(band.fractionOf(sunrise.add(const Duration(hours: 2))), 1);

      await tester.pumpWidget(
        _host(SizedBox(width: 600, child: band), size: const Size(600, 200)),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('the legend renders each shown label in full', (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 700,
            child: NightBand(
              sunset: DateTime(2026, 9, 9, 19, 12),
              astroDark: DateTime(2026, 9, 9, 20, 48),
              astroDawn: DateTime(2026, 9, 10, 4, 51),
              sunrise: DateTime(2026, 9, 10, 6, 24),
              now: DateTime(2026, 9, 9, 22, 41),
              events: <NightBandEvent>[
                NightBandEvent(
                  time: DateTime(2026, 9, 9, 19, 12),
                  label: '19:12 sunset',
                ),
                NightBandEvent(
                  time: DateTime(2026, 9, 9, 20, 48),
                  label: '20:48 astro dark',
                ),
                NightBandEvent(
                  time: DateTime(2026, 9, 10, 6, 24),
                  label: '06:24 sunrise',
                ),
              ],
            ),
          ),
          size: const Size(700, 200),
        ),
      );

      // At 700px the band shows only its first and last labels: the middle
      // ones overlapped into a smear there, and the canvas already draws
      // astro dark and astro dawn as dashed verticals (see
      // `kit_gaps_test.dart` for the width rule itself).
      expect(find.text('20:48 astro dark'), findsNothing);

      // Every label that IS shown is laid out at its natural width — the first
      // golden clipped "20:48 astro dark" to "20:48 astro dar" inside a fixed
      // 96px slot.
      for (final label in <String>['19:12 sunset', '06:24 sunrise']) {
        final painter = tester.renderObject<RenderBox>(find.text(label));
        expect(painter.size.width, greaterThan(0));
        expect(
          painter.size.width,
          lessThan(200),
          reason: 'a legend label is one line',
        );
      }
      expect(find.text('now 22:41'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('motion', () {
    testWidgets('every animated component honours disableAnimations', (
      tester,
    ) async {
      // MediaQuery.disableAnimations makes the framework's implicit animations
      // jump to their end value in one frame. The assertion is that a single
      // pump reaches the final state — no component may drive its own
      // Ticker-based motion past that.
      await tester.pumpWidget(
        _host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SkotiqIconButton(
                icon: LucideIcons.settings,
                tooltip: 'Settings',
                selected: true,
                onPressed: () {},
              ),
              SegmentedControl(
                segments: const <String>['A', 'B'],
                selectedIndex: 0,
                onSelected: (_) {},
              ),
              SkotiqButton(label: 'Go', onPressed: () {}),
              const SizedBox(
                width: 320,
                height: 200,
                child: SidePanel(child: Text('body')),
              ),
            ],
          ),
          disableAnimations: true,
        ),
      );
      await tester.pump();

      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('Glass', () {
    testWidgets('its contents resolve the DARK ladder in the light theme', (
      tester,
    ) async {
      late SkotiqColors inner;
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.light,
          home: Scaffold(
            body: Center(
              child: Glass(
                child: Builder(
                  builder: (context) {
                    inner = SkotiqColors.of(context);
                    return const Text('HFR');
                  },
                ),
              ),
            ),
          ),
        ),
      );

      // The frame under the glass is a photograph of the night sky in every
      // theme, so the text on top of it comes off the dark ladder.
      expect(inner.textPrimary, SkotiqColors.dark.textPrimary);
      expect(inner.surface, SkotiqColors.dark.surface);
    });

    testWidgets('red night keeps its own palette inside glass', (tester) async {
      late SkotiqColors inner;
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.redNight,
          home: Scaffold(
            body: Center(
              child: Glass(
                child: Builder(
                  builder: (context) {
                    inner = SkotiqColors.of(context);
                    return const Text('HFR');
                  },
                ),
              ),
            ),
          ),
        ),
      );
      expect(inner.isRedNight, isTrue);
    });

    testWidgets('the RepaintBoundary is OUTSIDE the blur, not inside', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const Glass(child: Text('HFR'))));

      final boundary = find.descendant(
        of: find.byType(Glass),
        matching: find.byType(RepaintBoundary),
      );
      final filter = find.descendant(
        of: find.byType(Glass),
        matching: find.byType(BackdropFilter),
      );
      expect(boundary, findsWidgets);
      expect(
        find.descendant(of: boundary.first, matching: filter),
        findsOneWidget,
        reason:
            'a boundary placed inside an animation gate silently kills the '
            'animation and reads as a free performance win',
      );
    });
  });

  group('SkotiqBanner', () {
    testWidgets('title and message share one line, action right-aligned', (
      tester,
    ) async {
      var dismissed = 0;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 720,
            child: SkotiqBanner(
              title: 'Catalogs not installed.',
              message: 'Annotations need HYG + OpenNGC.',
              action: SkotiqButton(
                label: 'Download',
                size: ButtonSize.small,
                onPressed: () {},
              ),
              onDismiss: () => dismissed++,
            ),
          ),
          size: const Size(720, 200),
        ),
      );

      final rich = tester.widget<Text>(
        find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
      );
      final span = rich.textSpan! as TextSpan;
      expect(span.text, 'Catalogs not installed.');
      expect(span.style!.fontWeight, FontWeight.w600);
      expect(
        span.children!.whereType<TextSpan>().single.text,
        ' Annotations need HYG + OpenNGC.',
      );

      await tester.tap(find.bySemanticsLabel('Dismiss'));
      expect(dismissed, 1);
    });

    testWidgets('a tone tints the fill and colours the glyph', (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 720,
            child: SkotiqBanner(
              title: 'Ends after astro dawn.',
              tone: BannerTone.warning,
            ),
          ),
          size: const Size(720, 200),
        ),
      );

      final colors = SkotiqColors.dark;
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(SkotiqBanner),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        (container.decoration! as BoxDecoration).color,
        colors.warning.withValues(alpha: SkotiqTokens.opacityHairline),
      );
      expect(tester.widget<Icon>(find.byType(Icon)).color, colors.warning);
    });
  });

  group('EmptyState', () {
    testWidgets('one glyph, one title, one sentence, one action', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 480,
            child: EmptyState(
              icon: LucideIcons.folderOpen,
              title: 'Nothing captured yet',
              body: 'Start a capture and this fills in.',
              action: SkotiqButton(
                label: 'Go to Imaging',
                size: ButtonSize.small,
                variant: ButtonVariant.secondary,
                onPressed: () {},
              ),
            ),
          ),
          size: const Size(480, 400),
        ),
      );

      expect(
        tester.widget<Icon>(find.byIcon(LucideIcons.folderOpen)).size,
        EmptyState.iconSize,
      );
      expect(
        tester.widget<Text>(find.text('Nothing captured yet')).style!.fontSize,
        SkotiqTypography.sectionTitle.fontSize,
      );
      // The content never runs wider than 360, whatever it is given.
      expect(
        tester.getSize(find.text('Start a capture and this fills in.')).width,
        lessThanOrEqualTo(EmptyState.maxWidth),
      );
      expect(
        find.widgetWithText(SkotiqButton, 'Go to Imaging'),
        findsOneWidget,
      );
    });
  });

  group('ListRow and DeviceRow', () {
    testWidgets('a tappable row hovers and reports its tap', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 320,
            child: ListRow(
              title: 'M51 Whirlpool',
              icon: LucideIcons.star,
              trailing: '22:41',
              onTap: () => taps++,
            ),
          ),
        ),
      );

      expect(find.text('22:41'), findsOneWidget);
      await tester.tap(find.byType(ListRow));
      expect(taps, 1);
    });

    testWidgets('a DeviceRow ends in its small readouts', (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 320,
            child: DeviceRow(
              name: 'Simulated camera',
              readouts: <Readout>[
                Readout(
                  value: '-10.0',
                  unit: '°C',
                  label: 'Temp',
                  size: ReadoutSize.sm,
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('TEMP'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('Simulated camera')).style!.fontSize,
        SkotiqTypography.button.fontSize,
      );
    });
  });

  group('Candidate', () {
    testWidgets(
      'shared columns line the header and rows up whatever the button',
      (tester) async {
        const columns = CandidateColumns(readoutWidth: 96, actionWidth: 120);
        Widget row(String action, {CandidateWindow? window}) => Candidate(
          score: '90',
          name: 'M33',
          detail: 'Galaxy',
          columns: columns,
          dense: true,
          readouts: const <Readout>[
            Readout(value: '00:48 · 81°', label: 'Transit'),
            Readout(value: '9h 45m', label: 'Above 30°'),
          ],
          window: window,
          action: SkotiqButton(
            label: action,
            size: ButtonSize.small,
            variant: ButtonVariant.secondary,
            onPressed: () {},
          ),
        );

        await tester.pumpWidget(
          _host(
            SizedBox(
              width: 900,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const CandidateHeader(
                    leading: Text('3 candidates'),
                    readoutLabels: <String>['Transit', 'Imageable'],
                    windowLabel: 'Window',
                    columns: columns,
                  ),
                  row(
                    'Image tonight',
                    window: const CandidateWindow(start: 0, end: 1, now: 0.5),
                  ),
                  row(
                    'Add',
                    window: const CandidateWindow(start: 0, end: 1, now: 0.5),
                  ),
                  // No window tonight: its slot is still held.
                  row('Add'),
                ],
              ),
            ),
          ),
        );

        final header = find.byType(CandidateHeader);
        final rows = find.byType(Candidate);
        for (var c = 0; c < 2; c++) {
          final label = c == 0 ? 'TRANSIT' : 'IMAGEABLE';
          final headerX = tester
              .getTopLeft(
                find.descendant(of: header, matching: find.text(label)),
              )
              .dx;
          for (var r = 0; r < 3; r++) {
            final readout = find
                .descendant(of: rows.at(r), matching: find.byType(Readout))
                .at(c);
            expect(tester.getTopLeft(readout).dx, headerX);
          }
        }
        final rights = <double>[
          for (var r = 0; r < 3; r++)
            tester
                .getTopRight(
                  find.descendant(
                    of: rows.at(r),
                    matching: find.byType(SkotiqButton),
                  ),
                )
                .dx,
        ];
        expect(rights.toSet(), hasLength(1));
      },
    );

    testWidgets('the window bar places its span and its now tick', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 200,
            child: CandidateWindowBar(
              window: CandidateWindow(start: 0.25, end: 0.75, now: 0.5),
            ),
          ),
        ),
      );

      final track = tester.getRect(find.byType(CandidateWindowBar));
      final span = tester.getRect(find.byType(DecoratedBox).last);
      expect(span.left - track.left, closeTo(track.width * 0.25, 0.5));
      expect(span.width, closeTo(track.width * 0.5, 0.5));

      final tick = tester.getRect(find.byType(ColoredBox));
      expect(tick.center.dx - track.left, closeTo(track.width * 0.5, 1));
    });

    testWidgets('selected draws the primary ring', (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 560,
            child: Candidate(
              score: '94',
              name: 'M51',
              detail: 'Galaxy',
              selected: true,
              readouts: const <Readout>[
                Readout(value: '61', unit: '°', label: 'Alt'),
              ],
            ),
          ),
          size: const Size(560, 200),
        ),
      );

      final panel = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(SkotiqPanel),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        (panel.decoration! as BoxDecoration).border!.top.color,
        SkotiqColors.dark.primary.withValues(
          alpha: SkotiqTokens.opacitySelectedRing,
        ),
      );
    });
  });

  group('FormRow', () {
    testWidgets('the label sits in a fixed column to the LEFT', (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 400,
            child: FormRow(
              label: 'Exposure',
              child: SkotiqTextField(initialValue: '120', mono: true),
            ),
          ),
        ),
      );

      final label = tester.getRect(find.text('Exposure'));
      final field = tester.getRect(find.byType(SkotiqTextField));
      expect(label.right, lessThanOrEqualTo(field.left));
      expect(field.height, fieldHeight);
    });

    testWidgets('a dense field is 28 tall', (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 400,
            child: SkotiqTextField(initialValue: '120', dense: true),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(SkotiqTextField)).height,
        fieldHeightDense,
      );
    });
  });

  group('SkotiqToolbar', () {
    testWidgets('groups are separated by hairlines', (tester) async {
      await tester.pumpWidget(
        _host(
          SkotiqToolbar(
            groups: <List<Widget>>[
              <Widget>[
                SkotiqIconButton(
                  icon: LucideIcons.undo2,
                  tooltip: 'Undo',
                  size: IconButtonSize.sm,
                  onPressed: () {},
                ),
              ],
              <Widget>[
                SkotiqIconButton(
                  icon: LucideIcons.redo2,
                  tooltip: 'Redo',
                  size: IconButtonSize.sm,
                  onPressed: () {},
                ),
              ],
            ],
          ),
        ),
      );

      final separators = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(SkotiqToolbar),
              matching: find.byType(Container),
            ),
          )
          .where((c) => c.constraints?.maxWidth == 1)
          .toList();
      expect(separators, hasLength(1));
    });

    testWidgets('a tight width collapses the overflow group behind a menu', (
      tester,
    ) async {
      Widget bar(double width) => _host(
        SizedBox(
          width: width,
          child: SkotiqToolbar(
            overflowIcon: LucideIcons.moreHorizontal,
            onOverflowPressed: () {},
            overflow: <Widget>[
              SkotiqButton(
                label: 'Export the whole session',
                size: ButtonSize.small,
                variant: ButtonVariant.ghost,
                onPressed: () {},
              ),
            ],
            groups: <List<Widget>>[
              <Widget>[
                SkotiqButton(
                  label: 'Timeline',
                  size: ButtonSize.small,
                  variant: ButtonVariant.ghost,
                  onPressed: () {},
                ),
              ],
            ],
          ),
        ),
        size: Size(width, 60),
      );

      await tester.pumpWidget(bar(600));
      expect(find.text('Export the whole session'), findsOneWidget);
      expect(find.bySemanticsLabel('More actions'), findsNothing);

      await tester.pumpWidget(bar(160));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('More actions'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
