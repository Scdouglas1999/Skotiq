import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _SwitchHarness extends StatefulWidget {
  const _SwitchHarness({required this.save});

  final Future<void> Function(bool) save;

  @override
  State<_SwitchHarness> createState() => _SwitchHarnessState();
}

class _SwitchHarnessState extends State<_SwitchHarness> {
  bool value = false;

  Future<void> _save(bool next) async {
    await widget.save(next);
    if (mounted) setState(() => value = next);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSwitch(value: value, onChanged: _save);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('failed async save rolls back the optimistic switch',
      (tester) async {
    await pumpAppScreen(
      tester,
      _SwitchHarness(
        save: (_) async => throw StateError('write failed'),
      ),
    );

    await tester.tap(find.byType(SkotiqSwitch));
    await tester.pump();
    expect(
        tester.widget<SkotiqSwitch>(find.byType(SkotiqSwitch)).value, isTrue);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(
        tester.widget<SkotiqSwitch>(find.byType(SkotiqSwitch)).value, isFalse);
  });

  testWidgets('rapid toggle back to the original value skips the write',
      (tester) async {
    final writes = <bool>[];
    await pumpAppScreen(
      tester,
      _SwitchHarness(save: (value) async => writes.add(value)),
    );

    await tester.tap(find.byType(SkotiqSwitch));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(SkotiqSwitch));
    await tester.pump(const Duration(milliseconds: 350));

    expect(writes, isEmpty);
    expect(
        tester.widget<SkotiqSwitch>(find.byType(SkotiqSwitch)).value, isFalse);
  });

  testWidgets('a newer toggle waits for an in-flight save', (tester) async {
    final started = <bool>[];
    final completions = <Completer<void>>[];
    await pumpAppScreen(
      tester,
      _SwitchHarness(
        save: (value) {
          started.add(value);
          final completion = Completer<void>();
          completions.add(completion);
          return completion.future;
        },
      ),
    );

    await tester.tap(find.byType(SkotiqSwitch));
    await tester.pump(const Duration(milliseconds: 350));
    expect(started, [true]);

    await tester.tap(find.byType(SkotiqSwitch));
    await tester.pump(const Duration(milliseconds: 350));
    expect(started, [true]);

    completions.first.complete();
    await tester.pump();
    expect(started, [true, false]);
    completions.last.complete();
    await tester.pump();

    expect(
        tester.widget<SkotiqSwitch>(find.byType(SkotiqSwitch)).value, isFalse);
  });

  testWidgets('disabled switch preserves its value and ignores taps',
      (tester) async {
    final writes = <bool>[];
    await pumpAppScreen(
      tester,
      SettingsSwitch(
        value: true,
        enabled: false,
        onChanged: (value) async => writes.add(value),
      ),
    );

    final switchWidget = tester.widget<SkotiqSwitch>(find.byType(SkotiqSwitch));
    expect(switchWidget.value, isTrue);
    expect(switchWidget.enabled, isFalse);
    await tester.tap(find.byType(SkotiqSwitch));
    await tester.pump(const Duration(milliseconds: 350));
    expect(writes, isEmpty);
  });
}
