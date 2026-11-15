// The per-filter results have to reach the filter that is running.
//
// A batch over the profile's seven filters lists more rows than the results
// panel shows at once. The list scrolls and follows the run, so the filter
// with live counts is on screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/flat_wizard/widgets/flat_preview_panel.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

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
      mode: FlatWizardMode.batch,
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
      // Short enough that seven rows do not fit the results panel.
      size: const Size(520, 600),
      settle: false,
      extraOverrides: [
        flatWizardProvider.overrideWith(
          (ref) => _SeededWizard(ref, capturingIndex: 4),
        ),
      ],
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));

    final active = find.text('Ha');
    final list = tester.getRect(
      find.ancestor(of: active, matching: find.byType(Scrollable)).first,
    );
    final row = tester.getRect(active);
    expect(
      row.top >= list.top && row.bottom <= list.bottom,
      isTrue,
      reason: 'the filter with live data must be inside the visible list',
    );
    expect(find.text('13 / 30'), findsOneWidget);
    expect(find.text('Capturing'), findsOneWidget);
  });
}
