import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _DropdownHarness extends StatefulWidget {
  const _DropdownHarness({required this.save});

  final Future<void> Function(String value) save;

  @override
  State<_DropdownHarness> createState() => _DropdownHarnessState();
}

class _DropdownHarnessState extends State<_DropdownHarness> {
  String value = 'First';

  Future<void> _save(String next) async {
    await widget.save(next);
    if (mounted) setState(() => value = next);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDropdown(
      value: value,
      items: const ['First', 'Second', 'Third'],
      onChanged: _save,
    );
  }
}

Future<void> _choose(WidgetTester tester, String value) async {
  await tester.tap(find.byType(SkotiqDropdown));
  await tester.pumpAndSettle();
  await tester.tap(find.text(value).last);
  await tester.pump();
}

String? _visibleValue(WidgetTester tester) =>
    tester.widget<SkotiqDropdown>(find.byType(SkotiqDropdown)).value;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('failed async save restores the confirmed selection',
      (tester) async {
    final completion = Completer<void>();
    await pumpAppScreen(
      tester,
      _DropdownHarness(save: (_) => completion.future),
    );

    await _choose(tester, 'Second');
    expect(_visibleValue(tester), 'Second');

    completion.completeError(StateError('write failed'));
    await tester.pump();

    expect(_visibleValue(tester), 'First');
    expect(tester.takeException(), isNull);
  });

  testWidgets('later selections wait for an in-flight save', (tester) async {
    final started = <String>[];
    final completions = <Completer<void>>[];
    await pumpAppScreen(
      tester,
      _DropdownHarness(
        save: (value) {
          started.add(value);
          final completion = Completer<void>();
          completions.add(completion);
          return completion.future;
        },
      ),
    );

    await _choose(tester, 'Second');
    expect(started, ['Second']);
    await _choose(tester, 'Third');
    expect(started, ['Second']);
    expect(_visibleValue(tester), 'Third');

    completions.first.complete();
    await tester.pump();
    expect(started, ['Second', 'Third']);
    completions.last.complete();
    await tester.pump();

    expect(_visibleValue(tester), 'Third');
  });
}
