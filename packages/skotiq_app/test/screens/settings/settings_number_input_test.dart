import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';

import '../../harness/harness.dart';

class _NumberInputHarness extends StatelessWidget {
  const _NumberInputHarness({
    required this.controller,
    required this.onChanged,
    this.authoritativeValue,
    this.authorityKey,
    this.min = 0,
    this.max = 100,
    this.decimals = 0,
  });

  final TextEditingController controller;
  final FutureOr<void> Function(double) onChanged;
  final double? authoritativeValue;
  final Object? authorityKey;
  final double min;
  final double max;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SettingsNumberInput(
          controller: controller,
          authoritativeValue: authoritativeValue,
          authorityKey: authorityKey,
          suffix: '',
          min: min,
          max: max,
          decimals: decimals,
          onChanged: onChanged,
        ),
        const TextField(key: ValueKey('other-field')),
      ],
    );
  }
}

Future<void> _focusElsewhere(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('other-field')));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('text settings persist on blur rather than every keystroke',
      (tester) async {
    final controller = TextEditingController(text: 'localhost');
    addTearDown(controller.dispose);
    final changes = <String>[];

    await pumpAppScreen(
      tester,
      Column(
        children: [
          SettingsTextInput(controller: controller, onChanged: changes.add),
          const TextField(key: ValueKey('other-field')),
        ],
      ),
    );

    await tester.enterText(find.byType(SettingsTextInput), '10.0.0.5');
    await tester.pump();
    expect(changes, isEmpty);

    await _focusElsewhere(tester);
    expect(changes, ['10.0.0.5']);
  });

  testWidgets('text submit followed by blur does not persist twice',
      (tester) async {
    final controller = TextEditingController(text: 'before');
    addTearDown(controller.dispose);
    final changes = <String>[];

    await pumpAppScreen(
      tester,
      Column(
        children: [
          SettingsTextInput(controller: controller, onChanged: changes.add),
          const TextField(key: ValueKey('other-field')),
        ],
      ),
    );

    await tester.enterText(find.byType(SettingsTextInput), 'after');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await _focusElsewhere(tester);

    expect(changes, ['after']);
  });

  testWidgets('failed async text save restores the confirmed value',
      (tester) async {
    final controller = TextEditingController(text: 'before');
    addTearDown(controller.dispose);
    final completion = Completer<void>();

    await pumpAppScreen(
      tester,
      Column(
        children: [
          SettingsTextInput(
            controller: controller,
            onChanged: (_) => completion.future,
          ),
          const TextField(key: ValueKey('other-field')),
        ],
      ),
    );

    await tester.enterText(find.byType(SettingsTextInput), 'after');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(controller.text, 'after');

    completion.completeError(StateError('write failed'));
    await tester.pump();
    expect(controller.text, 'before');
  });

  testWidgets(
      'same-authority text push preserves a dirty edit and becomes rollback',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final authority = Object();
    var authoritative = 'host value';
    late StateSetter rebuild;

    await pumpAppScreen(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return Column(
            children: [
              SettingsTextInput(
                controller: controller,
                authoritativeValue: authoritative,
                authorityKey: authority,
                onChanged: (_) => Future<void>.error(
                  StateError('write failed'),
                ),
              ),
              const TextField(key: ValueKey('other-field')),
            ],
          );
        },
      ),
    );

    await tester.enterText(find.byType(SettingsTextInput), 'my unsaved edit');
    rebuild(() => authoritative = 'other client value');
    await tester.pump();

    expect(controller.text, 'my unsaved edit');
    await _focusElsewhere(tester);
    await tester.pump();
    expect(controller.text, 'other client value');
  });

  testWidgets('backend switch replaces focused text and retires old save',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final hostA = Object();
    final hostB = Object();
    var authority = hostA;
    var authoritative = 'host A';
    final oldSave = Completer<void>();
    final changes = <String>[];
    late StateSetter rebuild;

    await pumpAppScreen(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return Column(
            children: [
              SettingsTextInput(
                controller: controller,
                authoritativeValue: authoritative,
                authorityKey: authority,
                onChanged: (value) {
                  changes.add(value);
                  return oldSave.future;
                },
              ),
              const TextField(key: ValueKey('other-field')),
            ],
          );
        },
      ),
    );

    await tester.enterText(find.byType(SettingsTextInput), 'host A edit');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(changes, ['host A edit']);

    rebuild(() {
      authority = hostB;
      authoritative = 'host B';
    });
    await tester.pump();
    expect(controller.text, 'host B');

    oldSave.completeError(StateError('old host disconnected'));
    await tester.pump();
    expect(controller.text, 'host B');
  });

  testWidgets('persists once on blur instead of once per keystroke',
      (tester) async {
    final controller = TextEditingController(text: '10');
    addTearDown(controller.dispose);
    final changes = <double>[];

    await pumpAppScreen(
      tester,
      _NumberInputHarness(controller: controller, onChanged: changes.add),
    );

    await tester.enterText(find.byType(SettingsNumberInput), '25');
    await tester.pump();
    expect(changes, isEmpty);

    await _focusElsewhere(tester);
    expect(changes, [25]);
  });

  testWidgets('clamps both the persisted value and visible text on blur',
      (tester) async {
    final controller = TextEditingController(text: '10');
    addTearDown(controller.dispose);
    final changes = <double>[];

    await pumpAppScreen(
      tester,
      _NumberInputHarness(controller: controller, onChanged: changes.add),
    );

    await tester.enterText(find.byType(SettingsNumberInput), '999');
    await _focusElsewhere(tester);

    expect(changes, [100]);
    expect(controller.text, '100');
  });

  testWidgets('failed async number save restores the confirmed value',
      (tester) async {
    final controller = TextEditingController(text: '10');
    addTearDown(controller.dispose);
    final completion = Completer<void>();

    await pumpAppScreen(
      tester,
      _NumberInputHarness(
        controller: controller,
        onChanged: (_) => completion.future,
      ),
    );

    await tester.enterText(find.byType(SettingsNumberInput), '25');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(controller.text, '25');

    completion.completeError(StateError('write failed'));
    await tester.pump();
    expect(controller.text, '10');
  });

  testWidgets('empty input restores the last committed value', (tester) async {
    final controller = TextEditingController(text: '42');
    addTearDown(controller.dispose);
    final changes = <double>[];

    await pumpAppScreen(
      tester,
      _NumberInputHarness(controller: controller, onChanged: changes.add),
    );

    await tester.enterText(find.byType(SettingsNumberInput), '');
    await _focusElsewhere(tester);

    expect(changes, isEmpty);
    expect(controller.text, '42');
  });

  testWidgets('formatter rejects malformed decimals and excess precision',
      (tester) async {
    final controller = TextEditingController(text: '1.5');
    addTearDown(controller.dispose);

    await pumpAppScreen(
      tester,
      _NumberInputHarness(
        controller: controller,
        min: -100,
        max: 100,
        decimals: 2,
        onChanged: (_) {},
      ),
    );

    final editable = find.descendant(
      of: find.byType(SettingsNumberInput),
      matching: find.byType(EditableText),
    );
    await tester.tap(editable);
    await tester.enterText(editable, '12.34');
    await tester.enterText(editable, '12.34.5');
    expect(controller.text, '12.34');
    await tester.enterText(editable, '12.345');
    expect(controller.text, '12.34');
  });

  testWidgets('submit followed by blur does not persist twice', (tester) async {
    final controller = TextEditingController(text: '10');
    addTearDown(controller.dispose);
    final changes = <double>[];

    await pumpAppScreen(
      tester,
      _NumberInputHarness(controller: controller, onChanged: changes.add),
    );

    await tester.enterText(find.byType(SettingsNumberInput), '20');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await _focusElsewhere(tester);

    expect(changes, [20]);
  });

  testWidgets('backend switch replaces a dirty number without saving it',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final hostA = Object();
    final hostB = Object();
    var authority = hostA;
    var authoritative = 10.0;
    final changes = <double>[];
    late StateSetter rebuild;

    await pumpAppScreen(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return _NumberInputHarness(
            controller: controller,
            authoritativeValue: authoritative,
            authorityKey: authority,
            onChanged: changes.add,
          );
        },
      ),
    );

    await tester.enterText(find.byType(SettingsNumberInput), '25');
    rebuild(() {
      authority = hostB;
      authoritative = 42;
    });
    await tester.pump();
    expect(controller.text, '42');

    await _focusElsewhere(tester);
    expect(changes, isEmpty);
  });
}
