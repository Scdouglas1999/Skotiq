// Regression test: the Imaging > Guiding panel's control buttons must LOOK
// disabled when they are disabled.
//
// Observed on the running desktop build with the guider Disconnected: the
// panel correctly warned "No guider connected" and correctly greyed out Start,
// but Stop and Dither were drawn at full contrast with normal borders. Both
// were in fact already gated (`isEnabled: isConnected && isGuiding`), so
// clicking Dither did nothing at all — no snackbar, no log line, no state
// change. A dead click with no visible reason reads as the app swallowing the
// command, and "dither silently skipped" is exactly the failure an operator
// does not notice until stacking.
//
// The cause was the shared SmallButton: its OUTLINE variant rendered the
// disabled state as a full-strength `textMuted` border and label, which is how
// ordinary secondary text is drawn everywhere else in the app. Only the FILLED
// variant (used by Start) had a visible disabled treatment.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/guiding_panel.dart';
import 'package:skotiq_app/screens/imaging/widgets/panel_widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The border colour SmallButton painted for the given [label]. `.first` picks
/// the innermost AnimatedContainer, which is the button's own.
Color _borderColorOf(WidgetTester tester, String label) {
  final container = tester.widget<AnimatedContainer>(
    find
        .ancestor(
          of: find.text(label),
          matching: find.byType(AnimatedContainer),
        )
        .first,
  );
  final decoration = container.decoration! as BoxDecoration;
  return decoration.border!.top.color;
}

/// The label colour SmallButton painted for the given [label].
Color _labelColorOf(WidgetTester tester, String label) =>
    tester.widget<Text>(find.text(label)).style!.color!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'disconnected_guider_renders_dither_and_stop_as_visibly_disabled: the '
      'outline controls dim like the filled one instead of looking live',
      (tester) async {
    await pumpAppScreen(
      tester,
      const GuidingPanel(colors: SkotiqColors.dark),
      size: const Size(520, 1600),
      settle: false,
    );
    await _drain(tester);

    // Precondition: this is the disconnected state the report describes.
    expect(find.text('No guider connected'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Dither'), findsOneWidget);

    // Both outline controls are gated off, so neither may be drawn in the
    // colour the app uses for live secondary content.
    for (final label in ['Stop', 'Dither']) {
      expect(
        _borderColorOf(tester, label),
        isNot(SkotiqColors.dark.textMuted),
        reason: '$label is disabled, so a full-strength textMuted border — the '
            'same border an enabled secondary control gets — is a lie.',
      );
      expect(
        _borderColorOf(tester, label).a,
        lessThan(1.0),
        reason: '$label must be dimmed, not merely recoloured.',
      );
      expect(
        _labelColorOf(tester, label),
        _borderColorOf(tester, label),
        reason: 'Label and border must dim together so the whole control reads '
            'as unavailable.',
      );
    }
  });

  testWidgets(
      'enabled_outline_button_is_not_dimmed: the fix must not grey out live '
      'controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: Center(
            child: SmallButton(
              label: 'Dither',
              icon: Icons.shuffle,
              isOutline: true,
              colors: SkotiqColors.dark,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      _borderColorOf(tester, 'Dither'),
      SkotiqColors.dark.primary,
      reason: 'An enabled outline button keeps the full-strength primary '
          'border — dimming everything would just move the confusion.',
    );
  });
}
