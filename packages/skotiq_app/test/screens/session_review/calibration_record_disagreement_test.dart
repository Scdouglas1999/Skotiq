// The Night Doctor's verdict against the night's own calibration record.
//
// The verdict is a session-level degradation score built from session-level
// findings. The calibration record is written somewhere else entirely — the
// integration stores it on the master's row, the master FITS carries it as
// CALWARN, and the dawn pass's morning report prints every sentence of it — and
// none of it reaches the score. So a night whose integration recorded twenty
// calibration warnings scored 100 / 100 under "a clean night, no problems
// detected", and nothing on the review page said otherwise.
//
// Unit-level, because the reconciliation is a claim and a claim is exactly what
// a unit test can hold. It states; it does not score — decision #20 owns
// whether a calibration warning should move the number.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/narrative_view.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

IntegratedMaster _master({required String statsJson, String name = 'M31 L'}) =>
    IntegratedMaster(
      id: 4,
      targetId: 1,
      name: name,
      masterFitsPath: '/masters/m31_L.fits',
      previewPngPath: null,
      sidecarPath: null,
      rejectionMapPath: null,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: 1,
      width: 4000,
      height: 3000,
      frameCount: 40,
      totalIntegrationSeconds: 12000,
      filter: 'L',
      settingsJson: '{}',
      statsJson: statsJson,
      createdAt: DateTime.utc(2026, 8, 15),
      updatedAt: DateTime.utc(2026, 8, 16),
    );

/// One slot as the native applied-masters report writes it.
String _slot(
  String kind, {
  required bool applied,
  required String quality,
  bool stale = false,
}) =>
    '{"kind": "$kind", "path": ${applied ? '"/cal/$kind.fits"' : 'null'}, '
    '"applied": $applied, "quality": "$quality", "stale": $stale, '
    '"mismatches": [], "unverified": []}';

String _stats(List<String> slots, {bool anchorUnreadable = false}) =>
    '{"calibration": {"anchorUnreadable": $anchorUnreadable, '
    '"masters": [${slots.join(',')}]}}';

/// A controller that publishes ONE state: a perfect, finding-free verdict over
/// a master whose integration warned about its calibration.
///
/// The whole shape of the defect in one seed — the two records the screen has
/// to reconcile, disagreeing.
class _CleanVerdictWarnedMaster extends SessionReviewController {
  _CleanVerdictWarnedMaster(super.ref, super.scope, {required this.master});

  final IntegratedMaster master;

  @override
  Future<void> loadSmartData({bool recomputeNightReport = false}) async {
    state = state.copyWith(
      loading: false,
      loadingSmartData: false,
      title: 'M31',
      reviewedMaster: master,
      masters: [master],
      nightReport: NightReport(
        sessionId: 1,
        score: 100,
        headline: 'A clean night, no problems detected',
        createdAt: DateTime.utc(2026, 8, 16, 5),
      ),
    );
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> loadComposites() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the review states the record beside a 100/100 verdict', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = mockDatabase();
    addTearDown(db.close);
    const scope = SessionReviewScope.session(1);
    final master = _master(
      statsJson: _stats([
        _slot('dark', applied: true, quality: 'exact'),
        _slot('flat', applied: false, quality: 'missing'),
      ]),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionReviewControllerProvider(scope).overrideWith(
            (ref) => _CleanVerdictWarnedMaster(ref, scope, master: master),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: const Scaffold(
            body: NarrativeView(scope: scope),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    // The verdict is printed exactly as the Doctor computed it — the
    // reconciliation states, it does not re-grade.
    expect(find.text('A clean night, no problems detected'), findsOneWidget);
    // And, on the same page, what the night's own integration recorded.
    expect(
      find.textContaining('No master flat was applied'),
      findsOneWidget,
    );
  });

  group('a clean record says nothing', () {
    test('no master at all', () {
      expect(calibrationRecordMessage(master: null), isNull);
    });

    test('a row with no stats recorded', () {
      // An empty payload is not evidence of a calibration problem. Warning on
      // it would be the cry-wolf defect pointed the other way.
      expect(
        calibrationRecordMessage(master: _master(statsJson: '{}')),
        isNull,
      );
    });

    test('a payload this build cannot parse', () {
      expect(
        calibrationRecordMessage(master: _master(statsJson: 'not json')),
        isNull,
      );
    });

    test('every slot matched exactly', () {
      final stats = _stats([
        _slot('dark', applied: true, quality: 'exact'),
        _slot('flat', applied: true, quality: 'exact'),
        _slot('bias', applied: false, quality: 'notRequired'),
      ]);
      expect(
        calibrationRecordMessage(master: _master(statsJson: stats)),
        isNull,
      );
    });
  });

  group('a warned record is stated beside the verdict', () {
    test('a missing flat is named, in the record\'s own words', () {
      final stats = _stats([
        _slot('dark', applied: true, quality: 'exact'),
        _slot('flat', applied: false, quality: 'missing'),
      ]);
      final message =
          calibrationRecordMessage(master: _master(statsJson: stats));
      expect(message, isNotNull);
      expect(message, contains('one calibration warning'));
      expect(message, contains('No master flat was applied'));
      // Named, so a multi-master night says which one this is about.
      expect(message, contains('"M31 L"'));
    });

    test('several warnings are counted', () {
      final stats = _stats([
        _slot('dark', applied: true, quality: 'fallback'),
        _slot('flat', applied: false, quality: 'missing'),
        _slot('bias', applied: true, quality: 'exact', stale: true),
      ]);
      final message =
          calibrationRecordMessage(master: _master(statsJson: stats));
      expect(message, contains('3 calibration warnings'));
    });

    test('a long record quotes a few and counts the rest', () {
      // The shape a real unreadable-anchor night produces: a sentence per slot
      // plus the anchor's own, more than fits beside a verdict.
      final stats = _stats(
        [
          _slot('dark', applied: false, quality: 'missing'),
          _slot('flat', applied: false, quality: 'missing'),
          _slot('bias', applied: false, quality: 'missing'),
        ],
        anchorUnreadable: true,
      );
      final message =
          calibrationRecordMessage(master: _master(statsJson: stats))!;
      expect(message, contains('4 calibration warnings'));
      expect(message, contains('…and 1 more recorded against this master.'));
    });

    test('the sentence never claims to have changed the score', () {
      final stats = _stats([_slot('flat', applied: false, quality: 'missing')]);
      final message =
          calibrationRecordMessage(master: _master(statsJson: stats))!;
      // It reconciles two records; it does not re-grade the night. A sentence
      // that implied the verdict had been adjusted would contradict the number
      // printed directly above it.
      expect(message, contains('does not read the calibration record'));
    });
  });
}
