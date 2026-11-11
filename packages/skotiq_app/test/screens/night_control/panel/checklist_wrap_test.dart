// "Before you start" at the panel's real width, in the app's own faces: a
// detail whose second half says why the row matters wraps to a second line
// instead of being cut.
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/overview_sections.dart';

import '../../../golden/surface_golden_harness.dart';
import 'panel_test_support.dart';

void main() {
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  testWidgets('a detail too long for one line wraps, never cut',
      (tester) async {
    const solverDetail = 'not set up · solving and centering will fail';
    const dawnDetail =
        'park at 20:18 if still running · an idle mount only stops tracking';
    const weatherDetail = 'no source · safety cannot react';
    await pumpPanel(
      tester,
      child: NightChecklistSection(
        items: const <ChecklistItemVm>[
          ChecklistItemVm(
            id: ChecklistItemId.solver,
            state: ChecklistItemState.attention,
            title: NightText.literal('Solver'),
            detail: NightText.literal(solverDetail),
            actionLabel: NightText.literal('Set up'),
            route: '/settings',
          ),
          ChecklistItemVm(
            id: ChecklistItemId.weather,
            state: ChecklistItemState.attention,
            title: NightText.literal('Weather'),
            detail: NightText.literal(weatherDetail),
            actionLabel: NightText.literal('Add'),
            route: '/settings',
          ),
          ChecklistItemVm(
            id: ChecklistItemId.dawn,
            state: ChecklistItemState.ok,
            title: NightText.literal('Dawn'),
            detail: NightText.literal(dawnDetail),
          ),
        ],
        onAction: (_) {},
      ),
      overrides: const <Override>[],
    );

    for (final detail in <String>[solverDetail, weatherDetail, dawnDetail]) {
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(detail),
      );
      expect(paragraph.didExceedMaxLines, isFalse, reason: detail);
    }
    expect(tester.takeException(), isNull);
  });
}
