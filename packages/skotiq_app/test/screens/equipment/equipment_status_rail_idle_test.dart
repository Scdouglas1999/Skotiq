import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/widgets/equipment_health_panel.dart';
import 'package:skotiq_app/screens/equipment/widgets/equipment_readiness_panel.dart';
import 'package:skotiq_app/widgets/readiness/readiness_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// The Equipment screen's right-hand STATUS rail was measured burning ~10x the
/// CPU of any other screen while completely idle with zero devices connected:
/// 231-251% with the rail expanded versus 22-23% with it collapsed, flipped
/// deterministically by the rail's own toggle across five samples, on a static
/// "No devices connected" empty state with nothing animating on screen.
///
/// An idle panel must schedule no frames. These tests pin that: they mount the
/// rail's two panels and assert the frame loop goes quiet, so a future change
/// that reintroduces a perpetual animation (or a provider that hands back a new
/// object identity on every read and drives an unbounded rebuild loop) fails
/// here instead of on a battery in the field.
void main() {
  Widget rail() => const SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EquipmentHealthPanel(),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: EquipmentReadinessPanel(),
            ),
          ],
        ),
      );

  testWidgets('the idle status rail stops scheduling frames', (tester) async {
    final handle = await pumpAppScreen(tester, rail());
    addTearDown(() async => handle.database.close());

    // pumpAndSettle itself would time out on a perpetual animation; assert the
    // stronger property explicitly so the failure message is unambiguous.
    await tester.pumpAndSettle();
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason:
          'the status rail requested another frame while idle — something in '
          'System Health / Ready-to-image is repainting continuously',
    );

    // And it stays quiet across a stretch of wall-clock time, which is what the
    // CPU sample actually covered.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a blocked readiness row does not pulse forever', (tester) async {
    // The specific cause: every blocked row rendered StatusDotVariant.urgent, a
    // repeating opacity pulse. A repeating controller re-schedules a frame on
    // every vsync while it is painted, and readiness stays blocked until the
    // operator fixes the setup — so the panel produced frames for the whole
    // session.
    final handle = await pumpAppScreen(
      tester,
      const ReadinessPanel(showHeader: false),
      settle: false,
    );
    addTearDown(() async => handle.database.close());

    // With the harness backend nothing is connected, so readiness is blocked and
    // at least one row is rendered at blocked severity.
    expect(
      handle.container.read(readinessReportProvider).blockedItems,
      isNotEmpty,
      reason: 'the scenario under test requires a blocked row',
    );

    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    for (final dot in tester.widgetList<StatusDot>(find.byType(StatusDot))) {
      expect(
        dot.variant,
        isNot(StatusDotVariant.urgent),
        reason: 'readiness is a static checklist, not a live urgency signal',
      );
    }
  });

  testWidgets('an equipment health report is value-equal across rebuilds', (
    tester,
  ) async {
    // The rail rebuild cascade started here: EquipmentHealthReport had no
    // operator==, so every recompute produced a new identity and Riverpod
    // treated an identical report as a change.
    const service = EquipmentHealthService();
    final first = service.analyze(sessions: const [], deviceHealth: const []);
    final second = service.analyze(sessions: const [], deviceHealth: const []);
    expect(first, equals(second));
    expect(first.hashCode, equals(second.hashCode));
  });
}
