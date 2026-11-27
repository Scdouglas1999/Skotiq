// The role is fixed for the life of the process. "Work locally" on a
// --remote-host launch restarts as this computer's host instead of putting the
// local backend under a client's role, where a run refused to start ("A linked
// client has no executor to configure").

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/connection/work_locally.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _Relauncher implements AppRelauncher {
  final reasons = <String>[];
  @override
  Future<bool> relaunch({required String reason}) async {
    reasons.add(reason);
    return false;
  }
}

class _Disconnected extends BackendNotifier {
  _Disconnected(super.ref) {
    state = DisconnectedBackend();
  }

  int localSwaps = 0;

  @override
  Future<void> useLocalBackend() async => localSwaps++;
}

void main() {
  testWidgets(
      'Work locally on a client launch asks to restart as this '
      'computer\'s host, and never swaps backends', (tester) async {
    _Disconnected? notifier;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          launchRoleProvider.overrideWithValue(LaunchRole.linkedClient),
          appRelauncherProvider.overrideWithValue(_Relauncher()),
          backendProvider.overrideWith((ref) => notifier = _Disconnected(ref)),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: Center(child: WorkLocallyButton())),
        ),
      ),
    );

    await tester.tap(find.text('Work locally'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Use this computer instead?'), findsOneWidget);
    expect(notifier?.localSwaps ?? 0, 0);
  });

  testWidgets('Work locally on a host launch puts the local backend back',
      (tester) async {
    late _Disconnected notifier;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith((ref) => notifier = _Disconnected(ref)),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: Center(child: WorkLocallyButton())),
        ),
      ),
    );

    await tester.tap(find.text('Work locally'));
    await tester.pumpAndSettle();

    expect(find.text('Use this computer instead?'), findsNothing);
    expect(notifier.localSwaps, 1);
  });
}
