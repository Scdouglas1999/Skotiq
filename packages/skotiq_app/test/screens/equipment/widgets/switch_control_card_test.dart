import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/widgets/switch_control_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockDeviceService extends Mock implements DeviceService {}

final _serviceSlotProvider = StateProvider<DeviceService>(
  (ref) => throw UnimplementedError(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpCard(
    WidgetTester tester, {
    required DeviceService service,
    required List<String> names,
    required List<bool> states,
    required List<String> descriptions,
    required List<bool> isBoolean,
    required List<double> values,
    required List<double> minValues,
    required List<double> maxValues,
    required List<double> steps,
    required List<bool> canWrite,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          deviceServiceProvider.overrideWithValue(service),
          switchStateProvider.overrideWith((ref) {
            final notifier = SwitchStateNotifier(ref);
            notifier.setConnecting('native:switch:test', 'Power Box');
            notifier.setConnected();
            notifier.setChannels(
              count: names.length,
              names: names,
              states: states,
              descriptions: descriptions,
              isBoolean: isBoolean,
              values: values,
              minValues: minValues,
              maxValues: maxValues,
              steps: steps,
              canWrite: canWrite,
              refreshedAt: DateTime.utc(2026, 7, 13),
            );
            return notifier;
          }),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SingleChildScrollView(child: SwitchControlCard()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders and writes boolean and analog channels truthfully',
      (tester) async {
    final service = _MockDeviceService();
    when(service.refreshSwitchChannels).thenAnswer((_) async {});
    when(() => service.setSwitchChannelValue(1, 60)).thenAnswer((_) async {});

    await pumpCard(
      tester,
      service: service,
      names: const ['Mount Power', 'Dew Heater'],
      states: const [true, false],
      descriptions: const ['12V relay', 'PWM output'],
      isBoolean: const [true, false],
      values: const [1, 35],
      minValues: const [0, 0],
      maxValues: const [1, 100],
      steps: const [1, 5],
      canWrite: const [true, true],
    );

    expect(find.byType(Switch), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('PWM output'), findsOneWidget);
    expect(find.text('35'), findsOneWidget);

    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('switch-channel-1-slider')),
    );
    expect(slider.divisions, 20);
    slider.onChangeEnd!(60);
    await tester.pumpAndSettle();

    verify(() => service.setSwitchChannelValue(1, 60)).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only relay and sensor expose values without controls',
      (tester) async {
    final service = _MockDeviceService();
    when(service.refreshSwitchChannels).thenAnswer((_) async {});

    await pumpCard(
      tester,
      service: service,
      names: const ['Rain Alarm', 'Input Voltage'],
      states: const [false, true],
      descriptions: const ['Sensor state', 'Measured supply'],
      isBoolean: const [true, false],
      values: const [0, 12.4],
      minValues: const [0, 0],
      maxValues: const [1, 15],
      steps: const [1, 0.1],
      canWrite: const [false, false],
    );

    expect(find.byType(Switch), findsNothing);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('12.40'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.onChanged, isNull);
    expect(slider.onChangeEnd, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh is single-flight and reports an explicit failure',
      (tester) async {
    final service = _MockDeviceService();
    final manualRefresh = Completer<void>();
    var refreshCalls = 0;
    when(service.refreshSwitchChannels).thenAnswer((_) {
      refreshCalls++;
      if (refreshCalls == 1) return Future<void>.value();
      return manualRefresh.future;
    });

    await pumpCard(
      tester,
      service: service,
      names: const ['Mount Power'],
      states: const [true],
      descriptions: const ['12V relay'],
      isBoolean: const [true],
      values: const [1],
      minValues: const [0],
      maxValues: const [1],
      steps: const [1],
      canWrite: const [true],
    );
    expect(refreshCalls, 1, reason: 'the card performs its initial refresh');

    final refreshButton = find.byType(SkotiqIconButton);
    expect(refreshButton, findsOneWidget);
    await tester.tap(refreshButton);
    await tester.pump();

    expect(refreshCalls, 2);
    expect(
      tester.widget<SkotiqIconButton>(refreshButton).onPressed,
      isNull,
      reason: 'a second refresh cannot start while the first is pending',
    );

    manualRefresh.completeError(StateError('driver unavailable'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Channel refresh failed:'),
      findsOneWidget,
    );
    expect(tester.widget<SkotiqIconButton>(refreshButton).onPressed,
        isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('host switch unlocks refresh and discards the old failure',
      (tester) async {
    final serviceA = _MockDeviceService();
    final serviceB = _MockDeviceService();
    final resultA = Completer<void>();
    when(serviceA.refreshSwitchChannels).thenAnswer((_) => resultA.future);
    when(serviceB.refreshSwitchChannels).thenAnswer((_) async {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          _serviceSlotProvider.overrideWith((ref) => serviceA),
          deviceServiceProvider.overrideWith(
            (ref) => ref.watch(_serviceSlotProvider),
          ),
          switchStateProvider.overrideWith((ref) {
            final notifier = SwitchStateNotifier(ref);
            notifier.setConnecting('native:switch:test', 'Power Box');
            notifier.setConnected();
            notifier.setChannels(
              count: 1,
              names: const ['Mount Power'],
              states: const [true],
              descriptions: const ['12V relay'],
              isBoolean: const [true],
              values: const [1],
              minValues: const [0],
              maxValues: const [1],
              steps: const [1],
              canWrite: const [true],
              refreshedAt: DateTime.utc(2026, 7, 13),
            );
            return notifier;
          }),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: SwitchControlCard()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final refreshButton = find.byType(SkotiqIconButton);
    expect(
        tester.widget<SkotiqIconButton>(refreshButton).onPressed, isNull);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SwitchControlCard)),
    );
    container.read(_serviceSlotProvider.notifier).state = serviceB;
    await tester.pump();
    expect(tester.widget<SkotiqIconButton>(refreshButton).onPressed,
        isNotNull);

    await tester.tap(refreshButton);
    await tester.pump();
    verify(() => serviceB.refreshSwitchChannels()).called(1);

    resultA.completeError(StateError('old switch disconnected'));
    await tester.pumpAndSettle();
    expect(find.textContaining('old switch disconnected'), findsNothing);
  });
}
