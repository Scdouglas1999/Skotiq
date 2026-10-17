// Regression guard for: "Flat wizard's 'Flat capture failed - no frames were
// saved' gives no reason and no next step".
//
// The wizard already computed the reason (the solver returns "Max exposure
// reached but still under target" and the notifier stored it on
// FlatWizardState.warningMessage) but NOTHING under screens/flat_wizard/ read
// that field, and the only rendered message was the terminal literal. These
// tests assert on the RENDERED banner, so cutting the diagnosis out of
// action_buttons.dart fails them.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/flat_wizard/flat_wizard_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

/// Pins the wizard to a terminal state without running a capture. Also stubs
/// out the filter-wheel load the screen kicks off in its post-frame callback so
/// it cannot overwrite the seeded filter list.
class _TerminalStateNotifier extends FlatWizardNotifier {
  _TerminalStateNotifier(super.ref, this._seed) {
    // ignore: invalid_use_of_protected_member
    state = _seed;
  }

  final FlatWizardState _seed;

  @override
  Future<void> loadFiltersFromWheel() async {}
}

FlatWizardState _failedRun({
  required List<AduMeasurement> history,
  double maxExposure = 30.0,
  double minExposure = 0.001,
  double histogramTarget = 50.0,
  String? warningMessage,
}) {
  return FlatWizardState(
    globalSettings: FlatWizardGlobalSettings(
      histogramTarget: histogramTarget,
      minExposure: minExposure,
      maxExposure: maxExposure,
      frameCount: 5,
    ),
    filterSettings: const [
      FlatFilterSettings(
        filterName: 'R',
        filterPosition: 1,
        status: FilterCalibrationStatus.failed,
      ),
    ],
    aduHistory: history,
    errorMessage: 'Flat capture failed - no frames were saved.',
    warningMessage: warningMessage,
  );
}

AduMeasurement _m(double exposure, double adu) =>
    AduMeasurement(exposure: exposure, adu: adu, timestamp: DateTime(2026));

Future<void> _pump(WidgetTester tester, FlatWizardState seed) async {
  await pumpAppScreen(
    tester,
    const FlatWizardScreen(),
    extraOverrides: [
      flatWizardProvider
          .overrideWith((ref) => _TerminalStateNotifier(ref, seed)),
    ],
    settle: false,
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('names an unilluminated panel instead of just "failed"',
      (tester) async {
    // The audited run verbatim: 0.17 s -> 30 s (176x more exposure) moved the
    // frame from ~1050 to 1364 ADU. That is not an exposure problem.
    await _pump(
      tester,
      _failedRun(
        history: [
          _m(0.17, 1049),
          _m(2.39, 1102),
          _m(13.79, 1198),
          _m(30.0, 1364),
        ],
        warningMessage: 'R: Max exposure reached but still under target',
      ),
    );

    // SkotiqBanner draws the title and the message as ONE Text.rich, so
    // the assertions read the rich text rather than a per-sentence Text.
    expect(
      find.textContaining(
        'Flat capture failed - no frames were saved.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'brightness barely changed while the exposure grew 176x',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('1364 ADU against 1049', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Check the flat panel is switched on',
        findRichText: true,
      ),
      findsOneWidget,
    );
    // The solver's own per-filter reason, surfaced rather than dropped.
    expect(
      find.textContaining(
        'R: Max exposure reached but still under target',
        findRichText: true,
      ),
      findsOneWidget,
    );
  });

  testWidgets('quotes the exposure ceiling and the measured shortfall',
      (tester) async {
    // ADU DOES track exposure here, so the panel is fine — the run simply ran
    // out of exposure headroom.
    await _pump(
      tester,
      _failedRun(
        history: [
          _m(0.5, 900),
          _m(8.0, 9400),
          _m(30.0, 20120),
        ],
      ),
    );

    expect(
      find.textContaining(
          'at the 30.0 s maximum exposure the frame only reached 20120 ADU'),
      findsOneWidget,
    );
    expect(find.textContaining('short of the 50% target'), findsOneWidget);
    expect(
      find.textContaining('Raise the panel brightness or the camera gain'),
      findsOneWidget,
    );
  });

  testWidgets('names an over-bright panel at the exposure floor',
      (tester) async {
    await _pump(
      tester,
      _failedRun(
        history: [
          _m(0.5, 61000),
          _m(0.001, 48000),
        ],
      ),
    );

    expect(
      find.textContaining(
        'even at the 0.001 s minimum exposure the frame reached 48000 ADU',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Dim the panel or lower the camera gain',
        findRichText: true,
      ),
      findsOneWidget,
    );
  });

  testWidgets('shows only the wizard message when nothing was ever measured',
      (tester) async {
    await _pump(tester, _failedRun(history: const []));

    // SkotiqBanner draws the title and the message as ONE Text.rich, so
    // the assertions read the rich text rather than a per-sentence Text.
    expect(
      find.textContaining(
        'Flat capture failed - no frames were saved.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('maximum exposure', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('brightness barely changed', findRichText: true),
      findsNothing,
    );
  });
}
