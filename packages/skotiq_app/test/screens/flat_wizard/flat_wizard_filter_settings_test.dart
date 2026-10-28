import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/flat_wizard/flat_wizard_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _ConfiguredWizard extends FlatWizardNotifier {
  _ConfiguredWizard(super.ref) {
    state = state.copyWith(
      mode: FlatWizardMode.batch,
      filterSettings: const [
        FlatFilterSettings(filterName: 'L', filterPosition: 0),
        FlatFilterSettings(filterName: 'Ha', filterPosition: 4),
      ],
    );
  }
}

void main() {
  testWidgets('batch flats let the operator edit gain and offset per filter',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const FlatWizardScreen(),
      size: const Size(1280, 800),
      settle: false,
      extraOverrides: [
        flatWizardProvider.overrideWith((ref) => _ConfiguredWizard(ref)),
      ],
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Multi-filter batch'));
    await tester.pump(const Duration(milliseconds: 400));
    final gain = find.byKey(const ValueKey('flat-filter-gain-4'));
    final offset = find.byKey(const ValueKey('flat-filter-offset-4'));
    expect(gain, findsOneWidget,
        reason: 'Ha needs its own gain rather than a read-only profile value');
    expect(offset, findsOneWidget);
    await tester.ensureVisible(gain);
    await tester.enterText(gain, '139');
    await tester.enterText(offset, '21');
    await tester.pump();
    final ha = handle.container.read(flatWizardProvider).filterSettings[1];
    expect((ha.gainOverride, ha.offsetOverride), (139, 21));
    expect(
        handle.container
            .read(flatWizardProvider)
            .filterSettings[0]
            .gainOverride,
        isNull);
    await tester.enterText(gain, '0');
    await tester.pump();
    expect(
        handle.container
            .read(flatWizardProvider)
            .filterSettings[1]
            .gainOverride,
        0);
    await tester.enterText(gain, '');
    await tester.pump();
    expect(
        handle.container
            .read(flatWizardProvider)
            .filterSettings[1]
            .gainOverride,
        isNull);
    expect(tester.takeException(), isNull);
  });
}
