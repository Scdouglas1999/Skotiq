import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_overlay_composer.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

int _loadAttempts = 0;

class _FailingVisualizationPrefs extends ScienceVisualizationPrefsNotifier {
  @override
  Future<ScienceVisualizationPrefs> build() async {
    _loadAttempts++;
    throw StateError('overlay preferences unavailable');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('overlay preference outage hides slider and exposes retry',
      (tester) async {
    _loadAttempts = 0;
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => ScienceOverlayComposer(
          colors: SkotiqColors.of(context),
        ),
      ),
      extraOverrides: [
        scienceVisualizationPrefsProvider.overrideWith(
          _FailingVisualizationPrefs.new,
        ),
      ],
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('Could not load science overlay preferences'),
      findsOneWidget,
    );
    expect(find.byType(Slider), findsNothing);
    expect(_loadAttempts, 1);

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Retry overlay preferences'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(_loadAttempts, 2);
    expect(find.byType(Slider), findsNothing);
  });
}
