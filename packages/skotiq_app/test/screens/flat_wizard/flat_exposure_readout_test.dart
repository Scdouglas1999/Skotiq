import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/flat_wizard/widgets/flat_preview_panel.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/harness.dart';

class _SeededWizard extends FlatWizardNotifier {
  _SeededWizard(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = state.copyWith(
      filterSettings: const [
        FlatFilterSettings(
          filterName: 'L',
          filterPosition: 0,
          calibratedExposure: 0.0015,
        ),
        FlatFilterSettings(
          filterName: 'Ha',
          filterPosition: 1,
          calibratedExposure: 12.34,
        ),
      ],
      mode: FlatWizardMode.batch,
      showAduGraph: false,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a 1.5 ms flat reads in milliseconds, not 0.00 s',
      (tester) async {
    await pumpAppScreen(
      tester,
      const FlatPreviewPanel(),
      settle: false,
      extraOverrides: [
        flatWizardProvider.overrideWith((ref) => _SeededWizard(ref)),
      ],
    );
    await tester.pump();

    expect(find.textContaining('1.5'), findsWidgets);
    expect(find.textContaining('ms'), findsWidgets);
    expect(find.textContaining('0.00'), findsNothing);
    expect(find.textContaining('12.3 s', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('12.3400', skipOffstage: false), findsNothing);
  });
}
