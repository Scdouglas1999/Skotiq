// Equipment Settings mixes two save models in one dialog, so the difference has
// to be structural: Camera / Mount / Focuser save on edit, while the Built-in
// Guider block alone has Reset + Apply.
//
// The guider genuinely cannot save on edit — it pushes eight interdependent
// values to a guider that may be running, and a half-typed max-pulse reaching a
// live mount is what atomic Apply prevents. So Apply is live ONLY while
// something is pending, and the pending state says so; otherwise eight
// hand-typed numbers can be abandoned by closing the dialog with nothing on
// screen having said so.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/tabs/settings_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

const _applyKey = ValueKey('builtin-guider-apply');
const _gainKey = ValueKey('builtin-guider-gain');
const _pendingKey = ValueKey('builtin-guider-pending');
const _maxPulseKey = ValueKey('builtin-guider-max-pulse');

Future<void> _pumpFrames(WidgetTester tester, [int count = 4]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

bool _applyEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(_applyKey)).onPressed != null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(BuiltinGuiderConfig.defaults));

  Future<MockBackend> pump(WidgetTester tester) async {
    final backend = mockBackend();
    when(backend.builtinGuiderGetConfig).thenAnswer(
      (_) async => BuiltinGuiderConfig.defaults.copyWith(gain: 111),
    );
    when(() => backend.builtinGuiderSetConfig(any())).thenAnswer((_) async {});
    await pumpAppScreen(
      tester,
      const EquipmentSettingsTab(),
      backend: backend,
      settle: false,
    );
    await _pumpFrames(tester);
    return backend;
  }

  testWidgets('nothing pending: Apply is inert and says nothing is waiting',
      (tester) async {
    await pump(tester);

    expect(_applyEnabled(tester), isFalse);
    expect(find.byKey(_pendingKey), findsNothing);
    expect(find.textContaining('Last applied:'), findsOneWidget);
  });

  testWidgets('an edit arms Apply and is announced as not yet applied',
      (tester) async {
    await pump(tester);

    await tester.enterText(find.byKey(_gainKey), '333');
    await _pumpFrames(tester);

    expect(_applyEnabled(tester), isTrue);
    expect(find.byKey(_pendingKey), findsOneWidget);
    expect(
      find.text('Not applied yet — press Apply to send these to the guider.'),
      findsOneWidget,
    );
  });

  testWidgets('applying clears the pending state', (tester) async {
    final backend = await pump(tester);

    await tester.enterText(find.byKey(_gainKey), '333');
    await _pumpFrames(tester);
    await tester.ensureVisible(find.byKey(_applyKey));
    await tester.tap(find.byKey(_applyKey));
    await _pumpFrames(tester);

    verify(() => backend.builtinGuiderSetConfig(any())).called(1);
    expect(_applyEnabled(tester), isFalse);
    expect(find.byKey(_pendingKey), findsNothing);
    expect(find.textContaining('gain 333'), findsOneWidget);
  });

  testWidgets('typing the same value back is not pending', (tester) async {
    // Pending has to mean "differs from what the guider is running", not
    // "has been touched" — otherwise the warning cries wolf.
    await pump(tester);

    await tester.enterText(find.byKey(_gainKey), '333');
    await _pumpFrames(tester);
    expect(_applyEnabled(tester), isTrue);

    await tester.enterText(find.byKey(_gainKey), '111');
    await _pumpFrames(tester);

    expect(_applyEnabled(tester), isFalse);
    expect(find.byKey(_pendingKey), findsNothing);
  });

  testWidgets('a whole-number decimal field stops crying wolf once applied',
      (tester) async {
    // The three decimal fields (exposure, min pulse, max pulse) are doubles.
    // Typing "3" into one of them and pressing Apply stores 3.0, so a
    // text-vs-toString comparison never agrees again: the card would go on
    // saying "Not applied yet" about a value the guider is already running,
    // with Apply live to re-send it. Pending must mean "differs numerically".
    final backend = await pump(tester);

    await tester.enterText(find.byKey(_maxPulseKey), '1500');
    await _pumpFrames(tester);
    expect(_applyEnabled(tester), isTrue);

    await tester.ensureVisible(find.byKey(_applyKey));
    await tester.tap(find.byKey(_applyKey));
    await _pumpFrames(tester);

    verify(() => backend.builtinGuiderSetConfig(any())).called(1);
    expect(_applyEnabled(tester), isFalse,
        reason: 'the guider is running exactly what is on screen');
    expect(find.byKey(_pendingKey), findsNothing);
  });

  testWidgets('a trailing zero is not a pending edit', (tester) async {
    await pump(tester);

    await tester.enterText(find.byKey(_gainKey), '0111');
    await _pumpFrames(tester);

    expect(_applyEnabled(tester), isFalse,
        reason: '0111 is the gain the guider is already running');
    expect(find.byKey(_pendingKey), findsNothing);
  });
}
