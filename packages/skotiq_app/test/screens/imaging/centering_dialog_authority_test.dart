import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/centering_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _SwitchableBackendNotifier extends BackendNotifier {
  _SwitchableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void replaceBackend(SkotiqBackend backend) => state = backend;
}

class _DialogLauncher extends StatelessWidget {
  const _DialogLauncher();

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const CenteringDialog(
          targetRa: 12,
          targetDec: 30,
          targetName: 'M42',
        ),
      ),
      child: const Text('Open centering'),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('centering dialog closes when its imaging host changes',
      (tester) async {
    final backendA = mockBackend();
    late _SwitchableBackendNotifier backendNotifier;
    await pumpAppScreen(
      tester,
      const _DialogLauncher(),
      backend: backendA,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => backendNotifier = _SwitchableBackendNotifier(ref, backendA),
        ),
      ],
    );

    await tester.tap(find.text('Open centering'));
    await tester.pumpAndSettle();
    expect(find.text('Target Centering'), findsOneWidget);

    backendNotifier.replaceBackend(mockBackend());
    await tester.pumpAndSettle();

    expect(find.text('Target Centering'), findsNothing);
    expect(find.text('Open centering'), findsOneWidget);
  });
}
