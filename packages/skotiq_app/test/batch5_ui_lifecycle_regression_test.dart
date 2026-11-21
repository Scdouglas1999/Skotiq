import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_status_banner.dart';
import 'package:skotiq_app/widgets/mount_guard/mount_guard_recovery_dialog.dart';
import 'package:skotiq_core/database.dart';
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
  group('Batch 5 UI lifecycle, error hygiene, and DAO regressions', () {
    testWidgets(
      'MountGuardRecoveryDialog ignores completion when unmounted mid-await (success and error)',
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

          // Unmount the dialog BEFORE the async operation resolves.
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();

          if (fail) {
            completer.completeError(StateError('mount disconnected'));
          } else {
            completer.complete();
          }
          await tester.pump();

          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets(
      'ScienceStatusBanner strips raw Exception prefix via userFacingError',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              scienceProcessingStatusProvider.overrideWith(
                (ref) => Stream<ScienceProcessingStatusSnapshot>.error(
                  Exception('Photometry worker offline'),
                ),
              ),
            ],
            child: const MaterialApp(
              home: Scaffold(body: ScienceStatusBanner()),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Science status unavailable'), findsOneWidget);
        expect(find.text('Photometry worker offline'), findsOneWidget);
        expect(find.textContaining('Exception:'), findsNothing);
      },
    );

    test(
      'IntegratedMastersDao.getImprovementCurveJson returns persisted curve JSON or null',
      () async {
        final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final dao = IntegratedMastersDao(db);

        final id = await dao.insertMaster(
          name: 'M31_L',
          status: IntegratedMasterStatus.finalized,
          accumulationMode: AccumulationMode.batch,
        );

        expect(await dao.getImprovementCurveJson(id), isNull);

        const curveJson =
            '{"points":[{"count":1,"snr":12.5}],"population":["a.fits"]}';
        await dao.updateSmartFields(id, improvementCurveJson: curveJson);
        expect(await dao.getImprovementCurveJson(id), curveJson);
        expect(await dao.getImprovementCurveJson(id + 999), isNull);
      },
    );
  });
}
