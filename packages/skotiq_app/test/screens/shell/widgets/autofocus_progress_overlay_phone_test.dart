import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/autofocus_progress_overlay.dart';
import 'package:skotiq_core/providers.dart';

import '../../../harness/pump_app_screen.dart';

/// On a phone the autofocus pill stays where the shell puts it: a scroll
/// swipe that starts on it must not carry it up over the screen's rows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a swipe over the phone pill leaves it in place', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const Stack(children: [AutofocusProgressOverlay()]),
      size: const Size(412, 800),
      settle: false,
    );
    handle.container
        .read(autofocusOverlayProvider.notifier)
        .onAutofocusStarted();
    await tester.pump();

    final pill = find.textContaining('AF:');
    expect(pill, findsOneWidget);
    final before = tester.getRect(pill);

    await tester.drag(pill, const Offset(0, -400));
    await tester.pump();

    expect(tester.getRect(pill), before);
  });
}
