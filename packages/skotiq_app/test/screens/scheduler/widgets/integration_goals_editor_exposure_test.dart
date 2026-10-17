import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/scheduler/widgets/integration_goals_editor.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockIntegrationGoalService extends Mock
    implements IntegrationGoalService {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

void main() {
  setUpAll(() {
    registerFallbackValue(
      IntegrationGoal(
        targetId: 0,
        filter: 'L',
        exposureSeconds: 1,
        frameCount: 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      ),
    );
  });

  testWidgets('new scheduler goals use Smart Night exposure recommendations',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          integrationGoalProgressProvider.overrideWith(
            (ref, targetId) async => const <IntegrationGoalProgress>[],
          ),
          smartNightExposureContextProvider.overrideWith(
            (ref) async => const SmartNightExposureContext(
              camera: CameraExposureSpec(
                readNoiseE: 1.5,
                fullWellE: 18000,
                qePeak: 0.8,
              ),
              bortleClass: 5,
              focalLengthMm: 480,
              apertureMm: 80,
              pixelSizeMicrons: 3.76,
              availableFilterNames: ['Ha', 'L'],
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: IntegrationGoalsEditor(
              targetId: 42,
              targetName: 'North America Nebula',
              availableFilters: ['Ha', 'L'],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('180'), findsOneWidget);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ha').last);
    await tester.pumpAndSettle();

    expect(find.text('300'), findsOneWidget);
    expect(find.text('180'), findsNothing);
  });

  testWidgets(
      'host switch retires an add and a failed save keeps the selected filter',
      (tester) async {
    final service = _MockIntegrationGoalService();
    final firstWrite = Completer<int>();
    final secondWrite = Completer<int>();
    var writes = 0;
    when(() => service.upsert(any())).thenAnswer(
      (_) => (writes++ == 0 ? firstWrite : secondWrite).future,
    );
    late _SwappableBackendNotifier backendNotifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            backendNotifier = _SwappableBackendNotifier(
              ref,
              DisconnectedBackend(),
            );
            return backendNotifier;
          }),
          integrationGoalServiceProvider.overrideWithValue(service),
          integrationGoalProgressProvider.overrideWith(
            (ref, targetId) async => const <IntegrationGoalProgress>[],
          ),
          smartNightExposureContextProvider.overrideWith(
            (ref) async => null,
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: IntegrationGoalsEditor(
              targetId: 42,
              targetName: 'M42',
              availableFilters: ['Ha', 'L'],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ha').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Add'));
    await tester.pump();
    expect(writes, 1);

    backendNotifier.switchTo(DisconnectedBackend());
    await tester.pump();
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Add'),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Add'));
    await tester.pump();
    expect(writes, 2);

    firstWrite.completeError(StateError('old host failed'));
    await tester.pump();
    expect(find.textContaining('old host failed'), findsNothing);
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byType(DropdownButton<String>),
          )
          .value,
      'Ha',
    );

    secondWrite.complete(2);
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byType(DropdownButton<String>),
          )
          .value,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}
