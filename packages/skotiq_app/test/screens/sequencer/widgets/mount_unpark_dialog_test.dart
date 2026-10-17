import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mount_unpark_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../harness/harness.dart';

const _mountId = 'simulator:mount:preflight';

class _ParkedMountNotifier extends MountStateNotifier {
  _ParkedMountNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _mountId,
      deviceName: 'Preflight Mount',
      isParked: true,
    );
  }
}

Widget _launcher({
  required VoidCallback onContinue,
  required VoidCallback onCancel,
}) {
  return Builder(
    builder: (context) => TextButton(
      onPressed: () {
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => MountUnparkDialog(
            onUnparkAndContinue: onContinue,
            onCancel: onCancel,
          ),
        );
      },
      child: const Text('Open preflight'),
    ),
  );
}

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(find.text('Open preflight'));
  await tester.pump();
  expect(find.byType(MountUnparkDialog), findsOneWidget);
}

void main() {
  testWidgets('successful unpark updates authoritative mount state',
      (tester) async {
    final backend = mockBackend();
    when(() => backend.getMountCapabilities(_mountId)).thenAnswer(
      (_) async => const MountCapabilities(canUnpark: true),
    );
    when(() => backend.mountUnpark(_mountId)).thenAnswer((_) async {});
    var continued = false;

    final handle = await pumpAppScreen(
      tester,
      _launcher(
        onContinue: () => continued = true,
        onCancel: () {},
      ),
      backend: backend,
      settle: false,
      extraOverrides: [
        mountStateProvider.overrideWith(_ParkedMountNotifier.new),
      ],
    );
    await _openDialog(tester);

    await tester.tap(find.text('Unpark now'));
    await tester.pump();
    await tester.pump();

    expect(continued, isTrue);
    expect(handle.container.read(mountStateProvider).isParked, isFalse);
    expect(find.byType(MountUnparkDialog), findsNothing);
    verify(() => backend.mountUnpark(_mountId)).called(1);
  });

  testWidgets('unsupported unpark keeps preflight stopped', (tester) async {
    final backend = mockBackend();
    when(() => backend.getMountCapabilities(_mountId)).thenAnswer(
      (_) async => const MountCapabilities(canUnpark: false),
    );
    when(() => backend.mountUnpark(_mountId)).thenAnswer((_) async {});
    var continued = false;

    await pumpAppScreen(
      tester,
      _launcher(
        onContinue: () => continued = true,
        onCancel: () {},
      ),
      backend: backend,
      settle: false,
      extraOverrides: [
        mountStateProvider.overrideWith(_ParkedMountNotifier.new),
      ],
    );
    await _openDialog(tester);

    await tester.tap(find.text('Unpark now'));
    await tester.pump();
    await tester.pump();

    expect(continued, isFalse);
    expect(find.byType(MountUnparkDialog), findsOneWidget);
    expect(find.textContaining('unpark is unsupported'), findsOneWidget);
    verifyNever(() => backend.mountUnpark(_mountId));
  });
}
