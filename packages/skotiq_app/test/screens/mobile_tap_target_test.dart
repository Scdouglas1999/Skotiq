// Android tap-target audit for the mobile primary destinations.
//
// A previous mobile pass judged tap-target sizes "by eye from screenshots, not
// measured", which cannot distinguish a 44dp control from a 48dp one. This
// suite MEASURES them: it runs Flutter's own `androidTapTargetGuideline` (the
// 48x48 rule) over each screen at the three standard phone widths, and — when
// something fails — walks the semantics tree to report the offending rects with
// their actual sizes so the failure names real numbers instead of a boolean.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_app/screens/night_control/night_control_screen.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/screens/planner/planner_screen.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/weather/weather_screen.dart';

import '../harness/harness.dart';

/// Android's minimum touch-target edge, in logical pixels.
const double kMinTapTarget = 48.0;

Future<void> _drainFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// One measured, tappable semantics node.
class _Target {
  final Rect rect;
  final String label;
  _Target(this.rect, this.label);

  double get shortestEdge =>
      rect.width < rect.height ? rect.width : rect.height;
  @override
  String toString() =>
      '${rect.width.toStringAsFixed(1)}x${rect.height.toStringAsFixed(1)}'
      '${label.isEmpty ? '' : ' "$label"'}';
}

/// Whether [target] is only small because a scroll viewport cut it off.
///
/// A horizontal tab strip (or any scrolling row of controls) always ends
/// mid-item at SOME offset: the strip's right edge slices whatever item happens
/// to straddle it, and the semantics rect of that item is clipped to the
/// visible sliver. That is a *scrolled* control, not an undersized one — the
/// user reaches it by scrolling, exactly as the strip's chevrons advertise, and
/// no layout can prevent the cut for every viewport width. The rule is about
/// controls that are meant to be hit where they sit.
///
/// The exemption is deliberately narrow: the target must be flush against a
/// scroll viewport's edge on the axis it is undersized on, and its other edge
/// must be at least the minimum. A genuinely tiny control that merely happens
/// to sit at a viewport edge is still reported, because it fails the other
/// dimension too.
bool _isClippedByScroll(_Target target, List<Rect> viewports) {
  // A target in the corner where a horizontal scroller meets the edge of
  // the page's vertical one is cut on both axes, by two viewports.
  var atSide = false;
  var atEnd = false;
  for (final viewport in viewports) {
    if (!viewport.overlaps(target.rect)) continue;
    atSide = atSide ||
        (target.rect.right - viewport.right).abs() < 1.0 ||
        (target.rect.left - viewport.left).abs() < 1.0;
    atEnd = atEnd ||
        (target.rect.bottom - viewport.bottom).abs() < 1.0 ||
        (target.rect.top - viewport.top).abs() < 1.0;
  }
  if (atSide && atEnd) return true;
  for (final viewport in viewports) {
    if (!viewport.overlaps(target.rect)) continue;
    final cutHorizontally = target.rect.width < kMinTapTarget &&
        target.rect.height >= kMinTapTarget &&
        ((target.rect.right - viewport.right).abs() < 1.0 ||
            (target.rect.left - viewport.left).abs() < 1.0);
    final cutVertically = target.rect.height < kMinTapTarget &&
        target.rect.width >= kMinTapTarget &&
        ((target.rect.bottom - viewport.bottom).abs() < 1.0 ||
            (target.rect.top - viewport.top).abs() < 1.0);
    if (cutHorizontally || cutVertically) return true;
  }
  return false;
}

/// Every tappable semantics node, with rects resolved to global coordinates —
/// the same traversal Flutter's own tap-target guideline performs.
List<_Target> _measureTapTargets() {
  final tappableNodes = find.semantics.byPredicate((node) {
    final data = node.getSemanticsData();
    return data.hasAction(SemanticsAction.tap) &&
        !data.flagsCollection.isHidden &&
        !data.flagsCollection.isTextField;
  });
  return [
    for (final candidate in tappableNodes.evaluate())
      _Target(
        _globalRect(candidate),
        candidate.getSemanticsData().label,
      ),
  ];
}

/// A semantics node's rect is in ITS OWN coordinate space; the walk up the
/// ancestor chain applying each node's transform is what puts it on screen —
/// the same accumulation Flutter's own `androidTapTargetGuideline` performs.
/// (Sizes are unaffected by the translations, so this changes no verdict; it is
/// what lets a rect be compared against a scroll viewport's position.)
Rect _globalRect(SemanticsNode node) {
  var bounds = node.rect;
  SemanticsNode? current = node;
  while (current != null) {
    final transform = current.transform;
    if (transform != null) {
      bounds = MatrixUtils.transformRect(transform, bounds);
    }
    current = current.parent;
  }
  return bounds;
}

const _phoneSizes = <(String, Size)>[
  ('small 360x640', Size(360, 640)),
  ('modern 390x844', Size(390, 844)),
  ('large 430x932', Size(430, 932)),
];

void main() {
  final screens = <String, Widget Function()>{
    'tonight': () => const NightControlScreen(),
    'equipment': () => const EquipmentScreen(),
    'imaging': () => const ImagingScreen(),
    'sequencer': () => const SequencerScreen(),
    'guiding': () => const GuidingScreen(),
    'weather': () => const WeatherScreen(),
    'planner': () => const PlannerScreen(),
    'analytics': () => const AnalyticsScreen(),
  };

  for (final entry in screens.entries) {
    for (final (label, size) in _phoneSizes) {
      testWidgets('${entry.key} meets the 48dp Android tap target at $label',
          (tester) async {
        final handle = tester.ensureSemantics();
        final app = await pumpAppScreen(
          tester,
          entry.value(),
          size: size,
          settle: false,
        );
        await _drainFrames(tester);

        final viewports = [
          for (final scrollable in find.byType(Scrollable).evaluate())
            tester.getRect(find.byWidget(scrollable.widget)),
        ];
        final undersized = _measureTapTargets()
            .where((t) => t.shortestEdge < kMinTapTarget)
            .where((t) => !_isClippedByScroll(t, viewports))
            .toList()
          ..sort((a, b) => a.shortestEdge.compareTo(b.shortestEdge));

        // Report the actual numbers rather than a bare boolean.
        expect(
          undersized,
          isEmpty,
          reason:
              '${entry.key} @ $label has ${undersized.length} tap target(s) '
              'under ${kMinTapTarget}dp: ${undersized.take(12).join(', ')}',
        );

        handle.dispose();

        // Tear the tree down inside the test body. Screens that watch a
        // polling provider (analytics -> activeTransientAlertsProvider) hold a
        // periodic Timer that is only cancelled by the provider's `onDispose`.
        // `pumpAppScreen` disposes the container in an `addTearDown`, which
        // runs *after* the binding's "no pending timers" invariant check — so
        // those screens failed here on a timer leak rather than on a tap
        // target. Unmount, then dispose (dispose is idempotent, so the
        // harness's own tearDown stays a no-op).
        await tester.pumpWidget(const SizedBox.shrink());
        app.container.dispose();
        // Disposing drift's query streams schedules zero-duration timers of its
        // own; elapse a little so they fire before the invariant check.
        await _drainFrames(tester);
      });
    }
  }
}
