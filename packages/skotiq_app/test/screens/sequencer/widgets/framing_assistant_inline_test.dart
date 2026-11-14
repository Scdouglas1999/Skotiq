// The sequencer's Frame target dialog frames the node on the one framing
// session: opening it puts the node's target and rotation on framingProvider,
// Apply returns the session's rotation, Cancel returns null.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_sky_canvas.dart';
import 'package:skotiq_app/screens/sequencer/widgets/framing_assistant_inline.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

Future<ProviderContainer> _pumpOpener(
  WidgetTester tester,
  TargetHeaderNode target,
  void Function(double?) onResult,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => onResult(
                  await showFramingAssistantDialog(
                    context: context,
                    ref: ref,
                    target: target,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

void main() {
  testWidgets('opening frames the node on the framing session', (
    tester,
  ) async {
    double? result = -1;
    final container = await _pumpOpener(
      tester,
      TargetHeaderNode(
        name: 'M42',
        targetName: 'M42',
        raHours: 5.59,
        decDegrees: -5.39,
        rotation: 45,
      ),
      (value) => result = value,
    );

    expect(find.textContaining('M42'), findsWidgets);
    expect(find.byType(FramingSkyCanvas), findsOneWidget);
    final framing = container.read(framingProvider);
    expect(framing.target?.raHours, closeTo(5.59, 1e-9));
    expect(framing.target?.decDegrees, closeTo(-5.39, 1e-9));
    expect(framing.rotation, 45);

    container.read(framingProvider.notifier).setRotation(-30);
    await tester.pump();
    expect(find.text('-30°'), findsOneWidget);

    await tester.tap(find.text('Apply rotation'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(result, -30);
  });

  testWidgets('Cancel returns null', (tester) async {
    double? result = -1;
    await _pumpOpener(
      tester,
      TargetHeaderNode(
        name: 'Test',
        targetName: 'Test',
        raHours: 1,
        decDegrees: 10,
      ),
      (value) => result = value,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(result, isNull);
  });
}
