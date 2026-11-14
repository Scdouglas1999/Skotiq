// A session a failed run ended is a failure on every surface: History showed
// it as a gray "Failed" chip while the campaign view drew it red.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

ImagingSession _session(int id, String name, String status) => ImagingSession(
      id: id,
      name: name,
      startTime: DateTime.utc(2026, 8, 13, 9, id),
      totalExposures: 0,
      successfulExposures: 0,
      failedExposures: 0,
      totalIntegrationSecs: 0,
      autofocusCount: 0,
      status: status,
    );

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1400, 1200);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('History tones each session status the way runs are toned',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        standaloneImagesProvider
            .overrideWith((ref) => Stream.value(const <DbCapturedImage>[])),
        allDbImagesProvider
            .overrideWith((ref) => Stream.value(const <DbCapturedImage>[])),
        allSessionsProvider.overrideWith((ref) => Stream.value([
              _session(1, 'Failed night', 'failed'),
              _session(2, 'Kept checkpoint', 'paused-stopped'),
              _session(3, 'Old error', 'error'),
              _session(4, 'Done', 'completed'),
            ])),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: AnalyticsScreen(initialTab: AnalyticsTab.history)),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    ChipTone toneOf(String label) =>
        tester.widget<SkotiqChip>(find.widgetWithText(SkotiqChip, label)).tone;
    expect(toneOf('Failed'), ChipTone.error);
    expect(toneOf('Stopped (resumable)'), ChipTone.neutral);
    expect(toneOf('Error'), ChipTone.error);
    expect(toneOf('Completed'), ChipTone.success);
  });
}
