import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/focus_model_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

void _stubModel(_MockNetworkBackend backend, String message) {
  when(() => backend.getFocusModel()).thenAnswer(
    (_) async => {
      'hasModel': false,
      'message': message,
      'dataPointCount': 3,
    },
  );
}

Future<_SwappableBackendNotifier> _pump(
  WidgetTester tester,
  _MockNetworkBackend backend,
) async {
  late _SwappableBackendNotifier notifier;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider.overrideWith((ref) {
          notifier = _SwappableBackendNotifier(ref, backend);
          return notifier;
        }),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: FocusModelSettings(isMobile: true)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return notifier;
}

Future<void> _confirmClear(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(SkotiqButton, 'Clear Model Data'));
  await tester.pump();
  await tester.tap(find.widgetWithText(SkotiqButton, 'Clear'));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('late clear completion from old rig is discarded',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    _stubModel(hostA, 'Host A model');
    _stubModel(hostB, 'Host B model');
    final clear = Completer<void>();
    when(() => hostA.clearFocusModelData()).thenAnswer((_) => clear.future);
    final notifier = await _pump(tester, hostA);

    await _confirmClear(tester);
    verify(() => hostA.clearFocusModelData()).called(1);
    final clearingButton = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Clear Model Data'),
    );
    expect(clearingButton.onPressed, isNull);
    expect(clearingButton.isLoading, isTrue);

    notifier.switchTo(hostB);
    await tester.pump();
    await tester.pump();
    expect(find.text('Host B model'), findsOneWidget);

    clear.complete();
    await tester.pump();
    await tester.pump();

    expect(find.text('Focus model data cleared'), findsNothing);
    expect(find.text('Host B model'), findsOneWidget);
    final hostBButton = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Clear Model Data'),
    );
    expect(hostBButton.onPressed, isNotNull);
    expect(hostBButton.isLoading, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear failure is visible and unlocks retry', (tester) async {
    final backend = _MockNetworkBackend();
    _stubModel(backend, 'Current model');
    when(() => backend.clearFocusModelData())
        .thenThrow(StateError('database busy'));
    await _pump(tester, backend);

    await _confirmClear(tester);
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Clear failed'), findsOneWidget);
    expect(find.textContaining('database busy'), findsOneWidget);
    final button = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Clear Model Data'),
    );
    expect(button.onPressed, isNotNull);
    expect(button.isLoading, isFalse);
    expect(tester.takeException(), isNull);
  });
}
