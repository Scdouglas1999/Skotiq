// While auto-calibration keeps captured lights uncalibrated, Imaging says so
// and why, until the cause ends or the operator closes it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/uncalibrated_frames_banner.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _reason = 'the dark is 60 s and the light 2 s; a dark of another '
    'exposure can only be scaled with a master bias';

Future<AutoCalibrationNotice> _pump(WidgetTester tester) async {
  final notice = AutoCalibrationNotice();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        autoCalibrationNoticeProvider.overrideWith((ref) => notice),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: SizedBox(width: 900, child: UncalibratedFramesBanner()),
        ),
      ),
    ),
  );
  return notice;
}

void main() {
  testWidgets('nothing is shown while frames calibrate', (tester) async {
    await _pump(tester);
    expect(find.byType(SkotiqBanner), findsNothing);
  });

  testWidgets('the reason and the frames kept are shown in full', (
    tester,
  ) async {
    final notice = await _pump(tester);
    notice
      ..keptUncalibrated(_reason)
      ..keptUncalibrated(_reason);
    await tester.pump();

    expect(
      find.text(
        'Frames are being saved uncalibrated. The dark is 60 s and the light '
        '2 s; a dark of another exposure can only be scaled with a master '
        'bias. 2 frames kept as captured so far.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(find.text('Calibration settings'), findsOneWidget);
  });

  testWidgets('a closed notice stays closed while its cause lasts', (
    tester,
  ) async {
    final notice = await _pump(tester);
    notice.keptUncalibrated(_reason);
    await tester.pump();
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.byType(SkotiqBanner), findsNothing);

    notice.keptUncalibrated(_reason);
    await tester.pump();
    expect(find.byType(SkotiqBanner), findsNothing);

    notice.keptUncalibrated('failed to read dark master');
    await tester.pump();
    expect(find.byType(SkotiqBanner), findsOneWidget);
  });
}
