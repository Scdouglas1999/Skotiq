// The per-filter row has to reach the filter that is actually running.
//
// With the profile's seven filters the Visualizations row runs past the window
// edge after `B` (a fifth card sliced in half). Without a scrollbar, arrow or
// any other affordance saying more cards exist, `Ha` — the filter with live data
// (`Ha / 7.86s / 13/30`) — plus OIII and SII are unreachable at the default
// 1600x900 window.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/flat_wizard/widgets/flat_preview_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

const _filters = ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'];

class _SeededWizard extends FlatWizardNotifier {
  _SeededWizard(super.ref, {required int capturingIndex}) {
    // ignore: invalid_use_of_protected_member
    state = state.copyWith(
      filterSettings: [
        for (var i = 0; i < _filters.length; i++)
          FlatFilterSettings(
            filterName: _filters[i],
            filterPosition: i,
            capturedCount: i == capturingIndex ? 13 : 0,
            status: i == capturingIndex
                ? FilterCalibrationStatus.capturing
                : FilterCalibrationStatus.pending,
          ),
      ],
      showFilterCards: true,
      showAduGraph: false,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the filter being captured is scrolled into view',
      (tester) async {
    await pumpAppScreen(
      tester,
      const FlatPreviewPanel(),
      // Narrower than seven 108px cards, which is the situation the row is in
      // on a real window once the wizard's settings column takes its share.
      size: const Size(520, 700),
      settle: false,
      extraOverrides: [
        flatWizardProvider.overrideWith(
          (ref) => _SeededWizard(ref, capturingIndex: 4),
        ),
      ],
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));

    // The row is scrollable and says so.
    expect(find.byType(Scrollbar), findsWidgets);

    final row = tester.getRect(find.byType(ListView).first);
    final active = tester.getRect(find.text('Ha'));
    expect(
      active.left >= row.left && active.right <= row.right,
      isTrue,
      reason:
          'the filter with live data was off-screen with no way to reach it',
    );
  });
}
