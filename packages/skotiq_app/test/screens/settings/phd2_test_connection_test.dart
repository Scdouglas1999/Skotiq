// The PHD2 Guiding page had no way to find out whether PHD2 answers: no
// Connect/Test button, no state, no version, nothing. Every other integration
// page in the app (plate solvers, cloud sync, every notification transport) can
// be probed from where it is configured.
//
// The second half of the same defect: a bare port probe cannot tell PHD2 from
// any other process holding 4400, so the page must report what actually
// identified itself — PHD2's version and the equipment profile it has loaded —
// and must not call an anonymous listener "PHD2".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/phd2_guiding_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

Future<HarnessHandle> _pump(
  WidgetTester tester, {
  required Phd2ProbeResult probe,
}) async {
  final backend = mockBackend();
  when(
    () => backend.phd2Probe(host: any(named: 'host'), port: any(named: 'port')),
  ).thenAnswer((_) async => probe);

  final handle = await pumpAppScreen(
    tester,
    const SingleChildScrollView(child: Phd2GuidingSettings()),
    backend: backend,
    settle: false,
  );
  await handle.container.read(appSettingsProvider.future);
  await tester.pump();
  return handle;
}

Future<void> _tapTest(WidgetTester tester) async {
  final button = find.text('Test connection').last;
  await tester.scrollUntilVisible(
    button,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
  await tester.tap(button);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the page offers a connection test naming the endpoint', (
    tester,
  ) async {
    final handle = await _pump(
      tester,
      probe: const Phd2ProbeResult(outcome: Phd2ProbeOutcome.unreachable),
    );
    addTearDown(handle.container.dispose);

    expect(find.text('Test connection'), findsWidgets);
    expect(
      find.text('Check whether PHD2 is listening on localhost:4400'),
      findsOneWidget,
    );
  });

  testWidgets('a real PHD2 is named with its version and active profile', (
    tester,
  ) async {
    final handle = await _pump(
      tester,
      probe: const Phd2ProbeResult(
        outcome: Phd2ProbeOutcome.identified,
        version: '2.6.13',
        profile: 'Main rig',
      ),
    );
    addTearDown(handle.container.dispose);

    await _tapTest(tester);

    expect(
      find.text('PHD2 2.6.13 answered on localhost:4400. Active profile: '
          'Main rig.'),
      findsOneWidget,
    );
    verify(
      () => handle.backend.phd2Probe(host: 'localhost', port: 4400),
    ).called(1);
  });

  testWidgets('an anonymous listener on 4400 is not called PHD2', (
    tester,
  ) async {
    final handle = await _pump(
      tester,
      probe: const Phd2ProbeResult(outcome: Phd2ProbeOutcome.unidentified),
    );
    addTearDown(handle.container.dispose);

    await _tapTest(tester);

    expect(
      find.text(
        'Something is listening on localhost:4400 but it did not identify '
        'itself as PHD2. Check that the port belongs to PHD2 and that '
        '"Enable Server" is on.',
      ),
      findsOneWidget,
    );
    // The page must never claim PHD2 off a probe that did not identify one.
    expect(find.textContaining('PHD2 answered'), findsNothing);
  });

  testWidgets('a silent socket is reported as unreachable, with the cause', (
    tester,
  ) async {
    final handle = await _pump(
      tester,
      probe: const Phd2ProbeResult(
        outcome: Phd2ProbeOutcome.unreachable,
        error: 'Connection refused',
      ),
    );
    addTearDown(handle.container.dispose);

    await _tapTest(tester);

    expect(
      find.text(
        'No response on localhost:4400 (Connection refused). Is PHD2 running '
        'with "Enable Server" turned on?',
      ),
      findsOneWidget,
    );
  });
}
