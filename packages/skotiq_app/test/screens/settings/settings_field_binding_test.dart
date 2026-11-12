import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';

import '../../harness/harness.dart';

enum _Mode { slow, fast }

class _State {
  const _State();
  int get count => 5;
  _Mode get mode => _Mode.slow;
  bool get on => false;
}

Future<void> _blur(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('elsewhere')));
  await tester.pump();
}

Widget _host(Widget child) => Column(
      children: [
        SettingRow(
          icon: Icons.abc,
          title: 'Dither every',
          trailing: child,
        ),
        const TextField(key: ValueKey('elsewhere')),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingWriter', () {
    test('writes in order and skips a value replaced before it started',
        () async {
      final started = <int>[];
      final gates = <Completer<void>>[];
      final writer =
          SettingWriter<int>(initial: 0, onRollback: (_, __, ___) {});
      Future<void> write(int value) {
        started.add(value);
        gates.add(Completer<void>());
        return gates.last.future;
      }

      writer.submit(1, write);
      await pumpEventQueue();
      writer.submit(2, write);
      writer.submit(3, write);
      await pumpEventQueue();
      expect(started, [1]);
      gates.first.complete();
      await pumpEventQueue();
      expect(started, [1, 3], reason: '2 was replaced by 3 before it began');
      gates.last.complete();
      await pumpEventQueue();
      expect(writer.confirmed, 3);
      expect(writer.busy, isFalse);
    });

    test('a failed latest write rolls back to the stored value', () async {
      final rollbacks = <(int, int)>[];
      final writer = SettingWriter<int>(
        initial: 7,
        onRollback: (restored, attempted, _) =>
            rollbacks.add((restored, attempted)),
      );
      writer.submit(9, (_) => Future<void>.error(StateError('refused')));
      await pumpEventQueue();
      expect(rollbacks, [(7, 9)]);
      expect(writer.target, 7);
    });

    test('a host push during a write becomes the rollback value', () async {
      final gate = Completer<void>();
      int? restored;
      final writer = SettingWriter<int>(
        initial: 1,
        onRollback: (value, _, __) => restored = value,
      );
      writer.submit(2, (_) => gate.future);
      await pumpEventQueue();
      expect(writer.accept(5), isFalse, reason: 'optimistic value stays up');
      gate.completeError(StateError('refused'));
      await pumpEventQueue();
      expect(restored, 5);
    });

    test('an authority change retires queued writes and their results',
        () async {
      final hostA = Object();
      final hostB = Object();
      final written = <int>[];
      final gate = Completer<void>();
      var rolledBack = false;
      final writer = SettingWriter<int>(
        initial: 1,
        authority: hostA,
        onRollback: (_, __, ___) => rolledBack = true,
      );
      writer.submit(2, (value) {
        written.add(value);
        return gate.future;
      });
      await pumpEventQueue();
      writer.submit(3, (value) async => written.add(value));
      await pumpEventQueue();
      expect(writer.accept(40, authority: hostB), isTrue);
      gate.completeError(StateError('host A went away'));
      await pumpEventQueue();
      expect(written, [2], reason: '3 was meant for host A');
      expect(rolledBack, isFalse);
      expect(writer.confirmed, 40);
    });

    test('a debounced value that returns to the stored one writes nothing',
        () async {
      final written = <bool>[];
      final writer =
          SettingWriter<bool>(initial: false, onRollback: (_, __, ___) {});
      const delay = Duration(milliseconds: 20);
      writer.submit(true, written.add, debounce: delay);
      writer.submit(false, written.add, debounce: delay);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(written, isEmpty);
    });

    test('close sends a value still waiting out its debounce', () async {
      final written = <bool>[];
      final writer =
          SettingWriter<bool>(initial: false, onRollback: (_, __, ___) {});
      writer.submit(true, written.add, debounce: const Duration(seconds: 5));
      writer.close();
      await pumpEventQueue();
      expect(written, [true]);
    });
  });

  group('codecs', () {
    test('number: names the range for text that is not a number', () {
      const codec = NumberCodec(min: 0.5, max: 600, decimals: 1, unit: 's');
      final result = codec.parse('abc');
      expect(result.isOk, isFalse);
      expect(result.invalid, 'Enter a number from 0.5 to 600 s.');
    });

    test('number: clamps and says which bound applied', () {
      const codec = NumberCodec(min: 0.5, max: 600, decimals: 1, unit: 's');
      final high = codec.parse('9999');
      expect(high.value, 600);
      expect(high.note, 'The highest allowed value is 600 s.');
      final low = codec.parse('0');
      expect(low.value, 0.5);
      expect(low.note, 'The lowest allowed value is 0.5 s.');
      expect(codec.parse('12.5').note, isNull);
    });

    test('optional: empty text is "not set"', () {
      const codec = OptionalCodec(IntCodec(min: 0, max: 100));
      expect(codec.parse('  ').isOk, isTrue);
      expect(codec.parse('  ').value, isNull);
      expect(codec.parse('250').value, 100);
      expect(codec.format(null), '');
    });
  });

  testWidgets(
      'an unparseable number restores the value and says what is '
      'expected', (tester) async {
    final writes = <double>[];
    await pumpAppScreen(
      tester,
      _host(
        SettingsNumberInput(
          authoritativeValue: 5,
          suffix: 'frames',
          min: 1,
          max: 50,
          decimals: 0,
          parse: (text) => double.tryParse(text),
          onChanged: writes.add,
        ),
      ),
    );
    await tester.enterText(find.byType(SettingsNumberInput), 'lots');
    await _blur(tester);
    await tester.pump();

    expect(find.text('Enter a number from 1 to 50 frames.'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(writes, isEmpty);

    await tester.pump(SettingsFieldNotice.visibleFor);
    await tester.pump();
    expect(find.text('Enter a number from 1 to 50 frames.'), findsNothing);
  });

  testWidgets('an out-of-range number is clamped, written, and explained',
      (tester) async {
    final writes = <double>[];
    await pumpAppScreen(
      tester,
      _host(
        SettingsNumberInput(
          authoritativeValue: 5,
          suffix: 'frames',
          min: 1,
          max: 50,
          decimals: 0,
          onChanged: writes.add,
        ),
      ),
    );
    await tester.enterText(find.byType(SettingsNumberInput), '999');
    await _blur(tester);
    await tester.pump();

    expect(writes, [50]);
    expect(
        find.text('The highest allowed value is 50 frames.'), findsOneWidget);
    await tester.pump(SettingsFieldNotice.visibleFor);
  });

  testWidgets('a failed save names the setting and restores the value',
      (tester) async {
    await pumpAppScreen(
      tester,
      _host(
        SettingsSwitch(
          value: false,
          onChanged: (_) => Future<void>.error(StateError('host is offline')),
        ),
      ),
    );
    await tester.tap(find.byType(SettingsSwitch));
    await tester.pump(SettingsSwitch.writeDelay);
    await tester.pump();

    expect(
      find.text(
        '"Dither every" was not saved: host is offline. '
        'The previous value is shown.',
      ),
      findsOneWidget,
    );
    await tester.pump(SettingsFieldNotice.visibleFor);
  });

  testWidgets('a write that reported its own failure is not reported twice',
      (tester) async {
    await pumpAppScreen(
      tester,
      _host(
        SettingsTextInput(
          authoritativeValue: 'before',
          onChanged: (_) =>
              throw SettingWriteHandled(StateError('shown elsewhere')),
        ),
      ),
    );
    await tester.enterText(find.byType(SettingsTextInput), 'after');
    await _blur(tester);
    await tester.pump();

    expect(find.byKey(const ValueKey('settings-field-notice')), findsNothing);
    expect(find.text('before'), findsOneWidget);
  });

  testWidgets('a choice carries its typed value, not its label',
      (tester) async {
    final picked = <_Mode>[];
    await pumpAppScreen(
      tester,
      _host(
        SettingsChoice<_Mode>(
          value: _Mode.slow,
          values: _Mode.values,
          // Two values that read the same must still be distinct choices.
          labelOf: (_) => 'Same label',
          onChanged: picked.add,
        ),
      ),
    );
    await tester.tap(find.byType(SettingsChoice<_Mode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Same label').last);
    await tester.pumpAndSettle();
    expect(picked, [_Mode.fast]);
  });

  testWidgets('a slider writes once per drag, not once per step',
      (tester) async {
    final writes = <double>[];
    await pumpAppScreen(
      tester,
      _host(
        SettingsCompactSlider(
          value: 0,
          min: 0,
          max: 100,
          divisions: 100,
          format: (value) => '${value.round()}%',
          onChanged: writes.add,
        ),
      ),
    );
    await tester.drag(find.byType(Slider), const Offset(60, 0));
    await tester.pump(SettingsCompactSlider.writeDelay);
    await tester.pump();
    expect(writes, hasLength(1));
    expect(find.text('${writes.single.round()}%'), findsOneWidget);
  });

  testWidgets(
      'a field built from a descriptor reads, checks and writes '
      'through it', (tester) async {
    final writes = <Object?>[];
    final count = SettingField<_State, int>(
      label: 'Frames between dithers',
      read: (state) => state.count,
      write: (ref, value) => writes.add(value),
      codec: const IntCodec(min: 1, max: 20, unit: 'frames'),
    );
    final mode = SettingField<_State, _Mode>(
      label: 'Mode',
      read: (state) => state.mode,
      write: (ref, value) => writes.add(value),
      choices: _Mode.values,
      choiceLabel: (value) => value.name,
    );
    final on = SettingField<_State, bool>(
      label: 'Enabled',
      read: (state) => state.on,
      write: (ref, value) => writes.add(value),
    );
    const state = _State();
    await pumpAppScreen(
      tester,
      ProviderScope(
        child: Column(
          children: [
            SettingsField<_State, int>(field: count, state: state),
            SettingsField<_State, _Mode>(field: mode, state: state),
            SettingsField<_State, bool>(field: on, state: state),
            const TextField(key: ValueKey('elsewhere')),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(SettingsValueField<int>), '99');
    await _blur(tester);
    await tester.pump();
    expect(writes, [20]);
    expect(
      find.text('The highest allowed value is 20 frames.'),
      findsOneWidget,
    );

    await tester.tap(find.byType(SettingsSwitch));
    await tester.pump(SettingsSwitch.writeDelay);
    await tester.pump();
    expect(writes, [20, true]);
    await tester.pump(SettingsFieldNotice.visibleFor);
  });

  testWidgets('inputs read the form factor from the scope', (tester) async {
    await pumpAppScreen(
      tester,
      SettingsFormScope(
        narrow: true,
        child: SettingRow(
          icon: Icons.abc,
          title: 'Stacks on a phone',
          stackWhenNarrow: true,
          trailing: SettingsSwitch(value: false, onChanged: (_) {}),
        ),
      ),
    );
    final title = tester.getTopLeft(find.text('Stacks on a phone'));
    final toggle = tester.getTopLeft(find.byType(SettingsSwitch));
    expect(toggle.dy, greaterThan(title.dy), reason: 'control under the title');
  });
}
