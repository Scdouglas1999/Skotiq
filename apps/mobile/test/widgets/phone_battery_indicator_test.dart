import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/battery_service.dart';
import 'package:skotiq_mobile/widgets/phone_battery_indicator.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pump(WidgetTester tester, PhoneBatteryState? battery) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        batteryStateProvider.overrideWith(
          (ref) => battery == null
              ? const Stream<PhoneBatteryState>.empty()
              : Stream.value(battery),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: Center(child: PhoneBatteryIndicator())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('draws nothing before a reading or while the battery is fine', (
    tester,
  ) async {
    await _pump(tester, null);
    expect(find.textContaining('%'), findsNothing);

    await _pump(
      tester,
      const PhoneBatteryState(level: 64, isCharging: false, isLowPower: false),
    );
    expect(find.textContaining('%'), findsNothing);

    await _pump(tester, PhoneBatteryState.unknown);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('a low battery shows its level and explains the slower checks', (
    tester,
  ) async {
    await _pump(
      tester,
      const PhoneBatteryState(level: 14, isCharging: false, isLowPower: true),
    );
    expect(find.text('14%'), findsOneWidget);

    await tester.tap(find.text('14%'));
    await tester.pump();
    expect(
      find.text(
        'Phone battery at 14%. Skotiq checks the rig a third as often until '
        'the phone is charging. Alerts still arrive at once.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('battery saver shows the level with its own explanation', (
    tester,
  ) async {
    await _pump(
      tester,
      const PhoneBatteryState(
        level: 72,
        isCharging: false,
        isLowPower: false,
        isSaverOn: true,
      ),
    );
    expect(find.text('72%'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('^Battery saver is on')),
      findsOneWidget,
    );
  });

  testWidgets('the indicator is a full-height touch target', (tester) async {
    await _pump(
      tester,
      const PhoneBatteryState(level: 9, isCharging: false, isLowPower: true),
    );
    final size = tester.getSize(find.byType(InkWell));
    expect(size.height, greaterThanOrEqualTo(44));
    expect(size.width, greaterThanOrEqualTo(44));
  });
}
