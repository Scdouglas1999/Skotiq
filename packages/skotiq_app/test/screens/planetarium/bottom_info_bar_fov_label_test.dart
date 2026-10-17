// The sky renderer scales by min(width, height), so the field of view spans
// the canvas's SHORT axis — on a landscape window "60 deg" is 60 deg tall and
// noticeably wider than that across. The HUD label has to say which axis it
// means.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/bottom_info_bar.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('the FOV readout names the axis it measures', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(extensions: const [SkotiqColors.dark]),
          home: const Scaffold(
            body: BottomInfoBar(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('FOV (short axis):'), findsOneWidget);
    expect(find.text('FOV:'), findsNothing);
  });
}
