// The "What this will do at sequence start" card is the only place the app
// explains the strictness knob, so every check it names has to be one the
// pre-flight rules will actually raise. Two of them were hard-coded and lied:
// stale polar alignment was listed even at max-age 0 (where
// PolarAlignmentFreshnessRule returns nothing), directly contradicting the
// "check is disabled" line printed under it, and Lax promised that time drift
// becomes an info note when TimeSyncRule blocks >30 s in every mode.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/preflight_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._initial);

  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

Future<void> _pumpPreflight(
  WidgetTester tester, {
  required PreflightStrictness strictness,
  required int polarAgeDays,
}) async {
  await pumpAppScreen(
    tester,
    const PreflightSettings(),
    size: const Size(1000, 1200),
    extraOverrides: [
      appSettingsProvider.overrideWith(
        () => _StubAppSettingsNotifier(
          AppSettingsState(
            preflightStrictness: strictness,
            polarAlignmentMaxAgeDays: polarAgeDays,
          ),
        ),
      ),
    ],
  );
  await tester.pump();
}

/// Every bullet rendered inside the preview card, joined. The card is the only
/// place these phrases appear, so a substring match over it is unambiguous.
String _previewText(WidgetTester tester) {
  final bullets = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .where((s) => s.startsWith('• '));
  return bullets.join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('strict preview drops polar alignment when the age check is off',
      (tester) async {
    await _pumpPreflight(
      tester,
      strictness: PreflightStrictness.strict,
      polarAgeDays: 0,
    );

    final preview = _previewText(tester);
    expect(preview, contains('Sequence start is blocked on:'));
    expect(preview, contains('Polar alignment age check is disabled'));
    // The card must not name a rule that returns nothing at max-age 0.
    expect(preview, isNot(contains('stale polar alignment')));
  });

  testWidgets('strict preview names polar alignment when the age check is on',
      (tester) async {
    await _pumpPreflight(
      tester,
      strictness: PreflightStrictness.strict,
      polarAgeDays: 7,
    );

    final preview = _previewText(tester);
    expect(preview, contains('stale polar alignment'));
    expect(preview, contains('older than 7 days'));
  });

  testWidgets('normal preview drops polar alignment when the age check is off',
      (tester) async {
    await _pumpPreflight(
      tester,
      strictness: PreflightStrictness.normal,
      polarAgeDays: 0,
    );

    final preview = _previewText(tester);
    expect(preview, contains('Sequence start surfaces a warnings list for:'));
    expect(preview, isNot(contains('stale polar alignment')));
  });

  testWidgets('lax preview does not promise that a >30s clock skew is advisory',
      (tester) async {
    await _pumpPreflight(
      tester,
      strictness: PreflightStrictness.lax,
      polarAgeDays: 0,
    );

    final preview = _previewText(tester);
    expect(preview, isNot(contains('stale polar alignment')));
    // TimeSyncRule never degrades the 30 s error under Lax.
    expect(
      preview,
      contains('Clock drift over 30s still blocks the run in every mode'),
    );
  });

  testWidgets('graded-check wording matches the rule thresholds',
      (tester) async {
    await _pumpPreflight(
      tester,
      strictness: PreflightStrictness.strict,
      polarAgeDays: 3,
    );

    final preview = _previewText(tester);
    // The graded band starts at the warning threshold, not the error one.
    expect(
      preview,
      contains(
        'clock drift over '
        '${TimeSyncRule.warningThresholdSecs.toStringAsFixed(0)}s',
      ),
    );
  });
}
