import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/mount_guard/mount_guard_recovery_dialog.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

class _DelayedMountGuardNotifier extends MountGuardNotifier {
  _DelayedMountGuardNotifier(this._completer);

  final Completer<void> _completer;

  @override
  List<MountGuardEntry> build() => const [];

  @override
  Future<void> confirmRehomed(String deviceId) => _completer.future;
}

void main() {
  testWidgets(
    'unmounting during confirm-rehomed ignores both success and failure',
    (tester) async {
      for (final fail in [false, true]) {
        final completer = Completer<void>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              mountGuardProvider.overrideWith(
                () => _DelayedMountGuardNotifier(completer),
              ),
            ],
            child: const MaterialApp(
              home: Scaffold(
                body: MountGuardRecoveryDialog(deviceId: 'mount-1'),
              ),
            ),
          ),
        );

        await tester.tap(find.text('It is at home'));
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        if (fail) {
          completer.completeError(StateError('mount disconnected'));
        } else {
          completer.complete();
        }
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.byType(MountGuardRecoveryDialog), findsNothing);
      }
    },
  );
}
