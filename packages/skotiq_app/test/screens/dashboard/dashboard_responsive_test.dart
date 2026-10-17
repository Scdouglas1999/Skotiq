// Responsive widget tests for DashboardScreen (mobile responsive standard).
//
// Pumps the dashboard at the three reference phone sizes in BOTH orientations
// and asserts:
//   * the Tonight page's own reflow never overflows,
//   * the page header stays pinned above the scroll view at every size,
//   * the screen renders the panel grid (not the first-light checklist) when a
//     session is active.
//
// Overflow scope: tiles compose content from package:skotiq_ui and from
// the sequencer run-dashboard widgets, which can have their own pre-existing
// inner overflows that are out of scope for this screen rework (and which the
// existing dashboard_screen_test.dart swallows wholesale). This file fails only
// on overflows that originate in dashboard_screen.dart — i.e. THIS rework's
// own column/row reflow — and tolerates tile-internal ones.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout_provider.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_screen.dart';
import 'package:skotiq_app/screens/dashboard/widgets/dashboard_tile.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// Enables only timer-free legacy tiles so the reflow can be exercised without
/// the realistic cockpit default's periodic poll timers (weather / scheduler /
/// cloud-motion) tripping the test binding's "pending timer" assertion. This
/// set spans the curated compact-layout sections: a full-width hero
/// (livePreview), flow sections (captureSettings, sequenceStatus, guiding), and
/// the equipment section (equipmentStatus).
class _SelectiveDashboardLayoutNotifier extends DashboardLayoutNotifier {
  _SelectiveDashboardLayoutNotifier(this.enabledIds);

  final Set<DashboardWidgetId> enabledIds;

  @override
  Future<DashboardLayout> build() async {
    final tiles = DashboardLayout.defaultLayout()
        .tiles
        .map((tile) =>
            tile.copyWith(enabled: enabledIds.contains(tile.widgetId)))
        .toList();
    return DashboardLayout(
      version: DashboardLayout.currentVersion,
      tiles: tiles,
      secondaryZoneWidth: 0.4,
    );
  }
}

const _reflowTiles = <DashboardWidgetId>{
  DashboardWidgetId.livePreview,
  DashboardWidgetId.captureSettings,
  DashboardWidgetId.sequenceStatus,
  DashboardWidgetId.guiding,
  DashboardWidgetId.equipmentStatus,
};

Future<void> _drainAsyncFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Collects overflow exceptions, treating as fatal only those that originate in
/// the dashboard screen's own layout code (dashboard_screen.dart). Tile-internal
/// overflows from skotiq_ui / the sequencer run-dashboard widgets are
/// pre-existing and out of scope here.
class _OverflowGuard {
  final List<FlutterErrorDetails> appOverflows = [];
  void Function(FlutterErrorDetails)? _previous;

  void install() {
    _previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.toString();
      if (text.contains('overflowed')) {
        if (text.contains('dashboard_screen.dart')) {
          appOverflows.add(details);
        }
        return;
      }
      _previous?.call(details);
    };
  }

  void restore() {
    FlutterError.onError = _previous;
  }
}

const _phoneSizes = <(String, Size)>[
  ('small phone portrait', Size(360, 640)),
  ('small phone landscape', Size(640, 360)),
  ('modern phone portrait', Size(390, 844)),
  ('modern phone landscape', Size(844, 390)),
  ('large phone portrait', Size(430, 932)),
  ('large phone landscape', Size(932, 430)),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (name, size) in _phoneSizes) {
    testWidgets('dashboard reflow + pinned controls at $name', (tester) async {
      final guard = _OverflowGuard()..install();
      addTearDown(guard.restore);

      await pumpAppScreen(
        tester,
        const DashboardScreen(),
        size: size,
        settle: false,
        extraOverrides: [
          dashboardLayoutProvider.overrideWith(
            () => _SelectiveDashboardLayoutNotifier(_reflowTiles),
          ),
          // A RUNNING execution shows the cockpit grid instead of the standby
          // hero. Terminal states with nothing loaded or connected show the
          // briefing, so `completed` does not force the grid.
          sequenceExecutionStateProvider.overrideWith(
            (ref) => SequenceExecutionState.running,
          ),
        ],
      );
      await _drainAsyncFrames(tester);

      expect(
        guard.appOverflows,
        isEmpty,
        reason: 'Dashboard compact reflow must not overflow at $name '
            '(${size.width.toInt()}x${size.height.toInt()}).',
      );

      // The dashboard command bar and the pinned run-control strip are both
      // gone (04-shell §5, 06 §Tonight): the run state lives in the instrument
      // bar and the run's controls live in the hero. What must still be true at
      // every phone size is that the page header sits ABOVE the scroll view,
      // so the screen's identity and its Edit layout action never scroll away.
      expect(find.byType(PageHeader), findsOneWidget,
          reason: 'The page header must be present at $name.');
      final header = tester.getTopLeft(find.byType(PageHeader));
      final scroller = tester.getTopLeft(find.byType(SingleChildScrollView));
      expect(header.dy, lessThan(scroller.dy),
          reason: 'The page header must sit above the scrolling body at $name, '
              'not inside it.');
    });
  }

  testWidgets('the grid collapses to one column at phone widths',
      (tester) async {
    // Below the grid's single-column threshold every panel spans all twelve
    // columns, so every tile shares one left edge. Four columns of a twelfth
    // each is 180 px at 900 — narrower than a readout row — so the collapse is
    // the point, not a fallback.
    final guard = _OverflowGuard()..install();
    addTearDown(guard.restore);

    await pumpAppScreen(
      tester,
      const DashboardScreen(),
      // A genuinely narrow page: below the shell's own breakpoint, which is
      // where the grid collapses. A wide phone LANDSCAPE (844) is not narrow —
      // it keeps two panels abreast, which is the point of the breakpoint.
      size: const Size(390, 844),
      settle: false,
      extraOverrides: [
        dashboardLayoutProvider.overrideWith(
          () => _SelectiveDashboardLayoutNotifier(_reflowTiles),
        ),
        // Running puts the panel grid on screen; with nothing loaded or
        // connected the first-light checklist would own the page instead.
        sequenceExecutionStateProvider.overrideWith(
          (ref) => SequenceExecutionState.running,
        ),
      ],
    );
    await _drainAsyncFrames(tester);

    expect(guard.appOverflows, isEmpty,
        reason: 'The collapsed grid must not overflow.');

    final tileElements = find.byType(DashboardTile).evaluate().toList();
    expect(tileElements.length, greaterThanOrEqualTo(2),
        reason: 'Need at least two tiles for the column check to mean '
            'anything.');
    final leftOffsets = <double>{};
    for (final element in tileElements) {
      leftOffsets.add(
        tester.getTopLeft(find.byWidget(element.widget)).dx.roundToDouble(),
      );
    }
    expect(leftOffsets.length, 1,
        reason: 'At a phone width every panel is full width, so every tile '
            'shares one left edge.');
  });
}
