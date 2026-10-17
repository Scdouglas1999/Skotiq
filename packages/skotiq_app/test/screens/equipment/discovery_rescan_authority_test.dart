import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/widgets/discovery_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('late native rescan result from the old rig is discarded',
      (tester) async {
    final hostA = mockBackend();
    final hostB = mockBackend();
    addTearDown(hostA.dispose);
    addTearDown(hostB.dispose);
    final rescan = Completer<void>();
    when(() => hostA.rescanDevices()).thenAnswer((_) => rescan.future);
    late _SwappableBackendNotifier backendNotifier;

    await pumpAppScreen(
      tester,
      const DiscoveryPanel(),
      settle: false,
      extraOverrides: [
        backendProvider.overrideWith((ref) {
          backendNotifier = _SwappableBackendNotifier(ref, hostA);
          return backendNotifier;
        }),
      ],
    );
    await tester.pump();

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Rescan'),
    );
    await tester.pump();
    verify(() => hostA.rescanDevices()).called(1);

    backendNotifier.switchTo(hostB);
    await tester.pump();
    expect(
      find.widgetWithText(SkotiqButton, 'Rescan'),
      findsOneWidget,
    );

    rescan.complete();
    await tester.pump();
    await tester.pump();

    expect(find.text('Equipment rescan complete'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
