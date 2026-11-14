// A live stack is of one filter. The panel names it and says what became of
// a frame taken through another one.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/stacking_panel.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _FixedLiveStackingNotifier extends LiveStackingNotifier {
  _FixedLiveStackingNotifier(super.ref, LiveStackingState initial) {
    // ignore: invalid_use_of_protected_member
    state = initial;
  }
}

Future<void> _pumpPanel(WidgetTester tester, LiveStackingStats stats) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 1800);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      isRemoteModeProvider.overrideWithValue(false),
      connectedCameraIdProvider.overrideWithValue(null),
      liveStackingProvider.overrideWith(
        (ref) => _FixedLiveStackingNotifier(
          ref,
          LiveStackingState(status: LiveStackingStatus.running, stats: stats),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: StackingPanel(colors: SkotiqColors.dark)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a frame of another filter is reported as left out', (
    tester,
  ) async {
    await _pumpPanel(
      tester,
      const LiveStackingStats(
        stackedFrameCount: 3,
        totalFramesAttempted: 3,
        filter: 'L',
        otherFilterFrames: 1,
        lastOtherFilter: 'R',
      ),
    );

    expect(find.text('Stacking L'), findsOneWidget);
    // The banner is one sentence run: its title, then its message.
    expect(
      find.textContaining(
        '1 frame left out It was taken with the R filter and this stack is '
        'of L frames. To stack it, stop and start a new live stack.',
        findRichText: true,
      ),
      findsOneWidget,
    );
  });

  testWidgets('a stack with nothing left out carries no notice', (
    tester,
  ) async {
    await _pumpPanel(
      tester,
      const LiveStackingStats(
        stackedFrameCount: 3,
        totalFramesAttempted: 3,
        filter: 'L',
      ),
    );

    expect(find.text('Stacking L'), findsOneWidget);
    expect(
      find.textContaining('left out', findRichText: true),
      findsNothing,
    );
  });
}
