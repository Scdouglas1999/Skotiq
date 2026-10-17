import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';

import '../../harness/harness.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _ColorHarness extends StatefulWidget {
  const _ColorHarness({required this.save});

  final Future<void> Function(String color) save;

  @override
  State<_ColorHarness> createState() => _ColorHarnessState();
}

/// The dark palette's first two accents (03 §1.4) — the swatch set the harness
/// renders, since the test theme is dark.
const String _firstAccent = '#A48CF2';
const String _secondAccent = '#6EB3EC';

class _ColorHarnessState extends State<_ColorHarness> {
  String color = _firstAccent;

  Future<void> _save(String next) async {
    await widget.save(next);
    if (mounted) setState(() => color = next);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsColorPicker(
      selectedColor: color,
      onColorSelected: _save,
    );
  }
}

/// Whether the swatch for [color] is drawn with the selection ring.
bool _colorIsRinged(WidgetTester tester, String color) {
  final circle = find.byKey(ValueKey('settings-color-$color'));
  final container = tester.widget<Container>(
    find.descendant(of: circle, matching: find.byType(Container)).first,
  );
  final decoration = container.decoration! as BoxDecoration;
  return (decoration.boxShadow ?? const <BoxShadow>[]).isNotEmpty;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('failed color save restores the confirmed selection',
      (tester) async {
    final completion = Completer<void>();
    await pumpAppScreen(
      tester,
      _ColorHarness(save: (_) => completion.future),
    );

    await tester
        .tap(find.byKey(const ValueKey('settings-color-$_secondAccent')));
    await tester.pump();
    expect(_colorIsRinged(tester, _secondAccent), isTrue);

    completion.completeError(StateError('write failed'));
    await tester.pump();
    await tester.pump();

    expect(_colorIsRinged(tester, _firstAccent), isTrue);
    expect(_colorIsRinged(tester, _secondAccent), isFalse);
    expect(tester.takeException(), isNull);
  });

  // Found live (coverage closeout, never-claimed cluster B): the accessibility
  // tree for Settings → Appearance listed "Accent color" with ZERO children —
  // seven bare GestureDetectors, no name, no role, no selected state — while
  // the switch in the row below reported itself as "toggle button … [off]".
  // A swatch whose only description is its own pixels is the control that most
  // needs a name, and the names were already sitting unused in accentColors.
  testWidgets('every accent swatch is a named, selectable control', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await pumpAppScreen(
      tester,
      _ColorHarness(save: (_) async {}),
    );

    for (final (hex, name) in SettingsColorPicker.accentColors) {
      final node = tester.getSemantics(
        find.byKey(ValueKey('settings-color-$hex')),
      );
      expect(
        node.label,
        contains(name),
        reason: 'the $hex swatch must announce its colour name',
      );
      expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(
        node.hasFlag(SemanticsFlag.isSelected),
        hex == _firstAccent,
        reason: 'only the active accent may report itself as selected',
      );
    }

    semantics.dispose();
  });

  testWidgets('path browse ignores repeat taps while the picker is active',
      (tester) async {
    var calls = 0;
    final completion = Completer<void>();
    await pumpAppScreen(
      tester,
      SettingsPathInput(
        path: '/images',
        onBrowse: () {
          calls++;
          return completion.future;
        },
      ),
    );

    await tester.tap(find.byType(GestureDetector));
    await tester.tap(find.byType(GestureDetector));
    await tester.pump();

    expect(calls, 1);
    expect(find.byType(SkotiqSpinner), findsOneWidget);

    completion.complete();
    await tester.pump();
    expect(find.byType(SkotiqSpinner), findsNothing);
  });

  testWidgets('path browse reports async picker failures', (tester) async {
    await pumpAppScreen(
      tester,
      SettingsPathInput(
        path: '',
        onBrowse: () async => throw StateError('picker unavailable'),
      ),
    );

    await tester.tap(find.byType(GestureDetector));
    await tester.pump();

    expect(find.textContaining('picker unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'path browse unlocks and ignores stale errors after authority change',
      (tester) async {
    final authority = ValueNotifier<Object>(Object());
    final completion = Completer<void>();
    addTearDown(authority.dispose);

    await pumpAppScreen(
      tester,
      ValueListenableBuilder<Object>(
        valueListenable: authority,
        builder: (context, value, child) => SettingsPathInput(
          path: '/images',
          authorityKey: value,
          onBrowse: () => completion.future,
        ),
      ),
    );

    await tester.tap(find.byType(GestureDetector));
    await tester.pump();
    expect(find.byType(SkotiqSpinner), findsOneWidget);

    authority.value = Object();
    await tester.pump();
    expect(find.byType(SkotiqSpinner), findsNothing);

    completion.completeError(StateError('old host failed'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('old host failed'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
