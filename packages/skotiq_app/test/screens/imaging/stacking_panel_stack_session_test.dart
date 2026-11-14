// Stack & Share after the run: the panel stacked only the session of a run
// still imaging, so once a night ended the button read "Select a session to
// stack" with nothing on the panel to select one with.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/stacking_panel.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _RecordingSelector implements StackLightSelector {
  final asked = <int>[];

  @override
  Future<StackSelectionSummary> selectForSession({
    required int sessionId,
    required StackAndShareConfig config,
  }) async {
    asked.add(sessionId);
    throw StateError('selection is not under test');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ImagingSession _session(int id, String name, DateTime start, int frames) =>
    ImagingSession(
      id: id,
      name: name,
      startTime: start,
      totalExposures: frames,
      successfulExposures: frames,
      failedExposures: 0,
      totalIntegrationSecs: frames * 60.0,
      autofocusCount: 0,
      status: 'completed',
    );

Future<_RecordingSelector> _pumpPanel(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 1400);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
  final selector = _RecordingSelector();
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      isRemoteModeProvider.overrideWithValue(false),
      connectedCameraIdProvider.overrideWithValue(null),
      stackLightSelectorProvider.overrideWithValue(selector),
      allSessionsProvider.overrideWith(
        (ref) => Stream.value([
          // Newest first, as the provider sorts them. The newest run failed
          // before its first frame, so there is nothing in it to stack.
          _session(3, 'Failed run', DateTime(2026, 11, 11, 15, 22), 0),
          _session(2, 'Zenith test', DateTime(2026, 11, 11, 1, 10), 8),
          _session(1, 'M31', DateTime(2026, 11, 10, 22, 5), 12),
        ]),
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
  await tester.pump();
  return selector;
}

Future<void> _pressStackAndShare(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(SkotiqButton, 'Stack & Share'));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('with no run imaging, the newest session with frames is stacked',
      (tester) async {
    final selector = await _pumpPanel(tester);

    expect(find.textContaining('Zenith test'), findsOneWidget);
    expect(find.textContaining('Failed run'), findsNothing);

    await _pressStackAndShare(tester);
    expect(selector.asked, [2]);
  });

  testWidgets('the operator can pick an earlier session', (tester) async {
    final selector = await _pumpPanel(tester);

    await tester.tap(find.textContaining('Zenith test'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('M31').last);
    await tester.pumpAndSettle();

    await _pressStackAndShare(tester);
    expect(selector.asked, [1]);
  });
}
