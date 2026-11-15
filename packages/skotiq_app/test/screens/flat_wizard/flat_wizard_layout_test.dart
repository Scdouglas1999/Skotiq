// The Flat wizard's page: the run's start and its save folder live in the
// page header, the settings are a 520 px column of panels, and a camera with
// no filters still gets a row to set and run.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/flat_wizard/flat_wizard_screen.dart';
import 'package:skotiq_app/screens/flat_wizard/widgets/flat_wizard_panel.dart';
import 'package:skotiq_app/screens/flat_wizard/widgets/flat_wizard_split_view.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

Future<HarnessHandle> _pump(WidgetTester tester, Size size) async {
  final handle = await pumpAppScreen(
    tester,
    const FlatWizardScreen(),
    size: size,
    settle: false,
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return handle;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the header carries the one primary and the save folder',
      (tester) async {
    await _pump(tester, const Size(1600, 900));

    final header = find.byType(PageHeader);
    final start = find.descendant(
      of: header,
      matching: find.widgetWithText(SkotiqButton, 'Start capture'),
    );
    expect(start, findsOneWidget);
    expect(
      find.descendant(
        of: header,
        matching: find.widgetWithText(SkotiqButton, 'Choose folder'),
      ),
      findsOneWidget,
    );
    final primaries = tester
        .widgetList<SkotiqButton>(find.byType(SkotiqButton))
        .where((b) => b.variant == ButtonVariant.primary);
    expect(primaries, hasLength(1), reason: 'one primary per page');
  });

  testWidgets('the settings are three panels in a 520 px column',
      (tester) async {
    await _pump(tester, const Size(1600, 900));

    final panels = find.byType(FlatWizardPanel);
    expect(
      tester.widgetList<FlatWizardPanel>(panels).map((p) => p.title),
      ['Per filter', 'Exposure', 'Camera'],
    );
    for (final panel in panels.evaluate()) {
      expect(panel.size!.width, FlatWizardSplitView.controlsWidth);
    }
    final first = tester.getRect(panels.first);
    final header = tester.getRect(find.byType(PageHeader));
    expect(first.left, SkotiqTokens.screenPadding.left);
    expect(first.top - header.bottom, SkotiqTokens.screenPadding.top);
  });

  testWidgets('a camera with no filters gets one row to set and run',
      (tester) async {
    final handle = await _pump(tester, const Size(1600, 900));

    final row = handle.container.read(flatWizardProvider).filterSettings;
    expect(row, hasLength(1));
    expect(row.single.hasFilter, isFalse);
    expect(find.text('No filter'), findsWidgets);
    expect(find.byKey(const ValueKey('flat-filter-frames-0')), findsOneWidget);
  });

  testWidgets('a mode switch changes the settings, not the page',
      (tester) async {
    final handle = await _pump(tester, const Size(1600, 900));

    await tester.tap(find.text('Sky flats'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(handle.container.read(flatWizardProvider).mode,
        FlatWizardMode.skyFlats);
    expect(find.widgetWithText(SkotiqButton, 'Start batch'), findsOneWidget);
    expect(find.text('Twilight'), findsOneWidget);
    expect(find.text('Dawn'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone opens the preview in a sheet that shows it',
      (tester) async {
    await _pump(tester, const Size(390, 844));

    await tester.tap(find.text('Preview'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.takeException(), isNull);
    expect(find.text('No flat captured yet'), findsOneWidget);
    expect(find.text('Convergence'), findsOneWidget);
  });
}
