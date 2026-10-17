import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/stretch_controls.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _TestAutoStretchNotifier extends AutoStretchSettingsNotifier {
  _TestAutoStretchNotifier(
    super.ref, {
    required AutoStretchSettings initial,
    this.failWrites = false,
  }) {
    state = initial;
  }

  final bool failWrites;
  int updateCalls = 0;

  @override
  Future<void> update(AutoStretchSettings newSettings) async {
    updateCalls++;
    if (failWrites) throw StateError('write failed');
    state = newSettings;
  }
}

Widget _harness(
  AutoStretchSettings initial, {
  required void Function(_TestAutoStretchNotifier) captureNotifier,
  bool failWrites = false,
}) {
  return ProviderScope(
    overrides: [
      settingsDaoProvider.overrideWith(
        (ref) => throw StateError('unused by the test notifier'),
      ),
      autoStretchSettingsProvider.overrideWith((ref) {
        final notifier = _TestAutoStretchNotifier(
          ref,
          initial: initial,
          failWrites: failWrites,
        );
        captureNotifier(notifier);
        return notifier;
      }),
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: const Scaffold(body: StretchControls()),
    ),
  );
}

void main() {
  testWidgets('failed compact changes report the save error', (tester) async {
    late _TestAutoStretchNotifier notifier;
    await tester.pumpWidget(
      _harness(
        AutoStretchSettings.defaults(),
        failWrites: true,
        captureNotifier: (value) => notifier = value,
      ),
    );

    await tester.tap(find.byType(SkotiqSwitch));
    await tester.pumpAndSettle();

    expect(notifier.updateCalls, 1);
    expect(
      find.text('Could not save the auto-stretch settings.'),
      findsOneWidget,
    );
  });

  testWidgets('closing advanced settings discards edits without saving',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late _TestAutoStretchNotifier notifier;
    final initial = AutoStretchSettings.defaults().copyWith(enabled: true);
    await tester.pumpWidget(
      _harness(initial, captureNotifier: (value) => notifier = value),
    );

    await tester.tap(find.byIcon(SkotiqIcons.settings2));
    await tester.pumpAndSettle();
    final linkedChannels = find.descendant(
      of: find.widgetWithText(SkotiqSwitchRow, 'Linked channels'),
      matching: find.byType(SkotiqSwitch),
    );
    await tester.tap(linkedChannels);
    await tester.pump();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Close'));
    await tester.pumpAndSettle();

    expect(notifier.updateCalls, 0);
    expect(notifier.state, initial);
  });

  testWidgets('failed Apply keeps advanced settings open for retry',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late _TestAutoStretchNotifier notifier;
    final initial = AutoStretchSettings.defaults().copyWith(enabled: true);
    await tester.pumpWidget(
      _harness(
        initial,
        failWrites: true,
        captureNotifier: (value) => notifier = value,
      ),
    );

    await tester.tap(find.byIcon(SkotiqIcons.settings2));
    await tester.pumpAndSettle();
    final linkedChannels = find.descendant(
      of: find.widgetWithText(SkotiqSwitchRow, 'Linked channels'),
      matching: find.byType(SkotiqSwitch),
    );
    await tester.tap(linkedChannels);
    await tester.pump();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Apply'));
    await tester.pumpAndSettle();

    expect(notifier.updateCalls, 1);
    expect(find.text('Auto-Stretch Settings'), findsOneWidget);
    expect(
      find.text('Could not save the auto-stretch settings.'),
      findsOneWidget,
    );
  });
}
