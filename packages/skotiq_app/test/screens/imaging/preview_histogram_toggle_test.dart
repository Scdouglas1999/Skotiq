// The live-view histogram is off the frame by default and opt-in under
// Overlays → Histogram, and the choice survives a restart.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_hud.dart';
import 'package:skotiq_app/screens/imaging/widgets/preview_histogram_visibility.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

CapturedImageData _frame() => CapturedImageData(
      width: 64,
      height: 48,
      displayData: Uint8List(64 * 48 * 4),
      histogram: List<int>.filled(256, 7),
      stats: const ImageStats(mean: 120, hfr: 2.51, starCount: 39),
      capturedAt: DateTime.utc(2026, 7, 29, 15, 34),
      settings:
          const ExposureSettings(exposureTime: 3.0, gain: 100, offset: 10),
    );

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _swallowKnownOverflows() {
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    defaultOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = defaultOnError);
}

void main() {
  group('PreviewHistogramVisibleNotifier', () {
    test('defaults off with nothing stored', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final notifier = PreviewHistogramVisibleNotifier();
      addTearDown(notifier.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(notifier.state, isFalse);
    });

    test('remembers the choice across instances', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final first = PreviewHistogramVisibleNotifier();
      await first.setVisible(true);
      first.dispose();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(previewHistogramVisiblePrefsKey), isTrue);

      final second = PreviewHistogramVisibleNotifier();
      addTearDown(second.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(second.state, isTrue, reason: 'a restart keeps the histogram on');
    });

    test('a choice made before the stored value loads is not overwritten',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        previewHistogramVisiblePrefsKey: true,
      });
      final notifier = PreviewHistogramVisibleNotifier();
      addTearDown(notifier.dispose);
      await notifier.setVisible(false);
      await Future<void>.delayed(Duration.zero);
      expect(notifier.state, isFalse);
    });
  });

  testWidgets(
      'the histogram is off the frame until Overlays → Histogram turns it on',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    addTearDown(() async => handle.database.close());
    handle.container.read(currentImageProvider.notifier).state = _frame();
    await _drain(tester);

    expect(find.byType(HistogramHud), findsNothing,
        reason: 'nothing but the frame-info pill covers the image by default');
    expect(find.byType(FrameInfoPill), findsOneWidget);

    await tester.tap(find.text('Overlays'));
    await _drain(tester);
    await tester.tap(find.text('Histogram'));
    await _drain(tester);

    expect(handle.container.read(previewHistogramVisibleProvider), isTrue);
    expect(find.byType(HistogramHud), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(previewHistogramVisiblePrefsKey), isTrue);
  });

  testWidgets('the histogram no longer repeats the stretch state',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      previewHistogramVisiblePrefsKey: true,
    });
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    addTearDown(() async => handle.database.close());
    handle.container.read(currentImageProvider.notifier).state = _frame();
    await _drain(tester);

    expect(find.byType(HistogramHud), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(HistogramHud),
        matching: find.textContaining('Stretch'),
      ),
      findsNothing,
      reason: 'the capture bar\'s Stretch toggle is the one place it is said',
    );
  });
}
