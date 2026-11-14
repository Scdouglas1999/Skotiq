import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/imaging/widgets/guiding_panel.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

class _MockGuider extends Mock implements Phd2Controller {}

class _ConnectedGuiderNotifier extends GuiderStateNotifier {
  _ConnectedGuiderNotifier(super.ref) {
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'guider-1',
      deviceName: 'Test Guider',
    );
  }
}

final _guiderSlotProvider = StateProvider<Phd2Controller>(
  (ref) => throw UnimplementedError(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a late start from the old host does not touch the new one',
      (tester) async {
    final guiderA = _MockGuider();
    final guiderB = _MockGuider();
    final resultA = Completer<void>();
    final resultB = Completer<void>();
    when(() => guiderA.startGuiding()).thenAnswer((_) => resultA.future);
    when(() => guiderB.startGuiding()).thenAnswer((_) => resultB.future);

    final handle = await pumpAppScreen(
      tester,
      const GuidingPanel(colors: SkotiqColors.dark),
      extraOverrides: [
        _guiderSlotProvider.overrideWith((ref) => guiderA),
        phd2ControllerProvider.overrideWith(
          (ref) => ref.watch(_guiderSlotProvider),
        ),
        guiderStateProvider.overrideWith(_ConnectedGuiderNotifier.new),
      ],
      settle: false,
    );
    await tester.pump();

    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.text('Starting...'), findsOneWidget);

    handle.container.read(_guiderSlotProvider.notifier).state = guiderB;
    await tester.pump();
    expect(find.text('Start'), findsOneWidget);

    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.text('Starting...'), findsOneWidget);

    // The old host's start ending must not end the new host's.
    resultA.complete();
    await tester.pump();
    expect(find.text('Starting...'), findsOneWidget);

    resultB.complete();
    await tester.pump();
    expect(find.text('Start'), findsOneWidget);
    verify(() => guiderA.startGuiding()).called(1);
    verify(() => guiderB.startGuiding()).called(1);
  });
}
