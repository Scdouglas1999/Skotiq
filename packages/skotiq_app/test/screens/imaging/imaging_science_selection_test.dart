import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/live_preview_area.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

// Fail on excessive traversal instead of hanging the test runner for minutes.
class _ReadBudgetList<T> extends ListBase<T> {
  _ReadBudgetList(this.items) : remainingReads = items.length * 20;
  final List<T> items;
  int remainingReads;
  @override
  int get length => items.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  T operator [](int index) {
    if (--remainingReads < 0) {
      throw StateError('Science selection exceeded its linear read budget');
    }
    return items[index];
  }

  @override
  void operator []=(int index, T value) => throw UnsupportedError('read only');
}

void main() {
  testWidgets('opening preview with a session of Science tiles stays bounded',
      (tester) async {
    // October 29 freeze: 24 frames with 3,912 measurements each. The current
    // frame has not acquired Science results, so the preview selects a fallback.
    final tiles = _ReadBudgetList(List.generate(24 * 3912, (index) {
      final frame = index ~/ 3912;
      return ScienceTileMetricRow(
        id: index,
        capturedImageId: 1762 + frame,
        timestamp: DateTime.utc(2026, 10, 29).add(Duration(minutes: frame)),
        layerType: ScienceLayerType.uniformity.dbValue,
        tileRow: 0,
        tileCol: 0,
        sampleCount: 100,
        value: 0.5,
        p05: 0.4,
        p50: 0.5,
        p95: 0.6,
        auxValue: 0,
      );
    }));
    await pumpAppScreen(
      tester,
      LivePreviewArea(
        colors: SkotiqColors.dark,
        zoomLevel: 1,
        panOffset: Offset.zero,
        showCrosshair: false,
        showStarOverlay: false,
        isStoppingCapture: false,
        onZoomIn: () {},
        onZoomOut: () {},
        onPanUpdate: (_) {},
      ),
      settle: false,
      extraOverrides: [
        sessionlessTileMetricsProvider
            .overrideWith((ref) => Stream.value(tiles)),
      ],
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    expect(tiles.remainingReads, lessThan(tiles.length * 20),
        reason: 'The preview must actually consume the supplied Science rows.');
  });
}
