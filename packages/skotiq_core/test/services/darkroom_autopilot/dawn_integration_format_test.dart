// The one line the operator reads at 7am has to distinguish a short night from
// an empty one.
//
// The headline once rounded integration to whole minutes, and the report is
// built from it. A night that integrated 24 s therefore printed
// "Your 4 drafts are ready — 0m integrated", which is the identical string the
// function reserves for a night that integrated nothing — while the same
// report's own `integrationSeconds` field said 24.0 and the app's History row
// beside it said "24s integration".

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

DawnMaster _master(double seconds) => DawnMaster(
  masterId: 1,
  targetId: null,
  name: 'M42 L',
  filter: 'L',
  masterFitsPath: '/masters/m42_l.fits',
  channels: 1,
  width: 100,
  height: 100,
  frameCount: 4,
  totalIntegrationSeconds: seconds,
);

DawnJobReport _report(double seconds) => DawnJobReport(
  jobId: 1,
  kind: 'dawn',
  sessionId: 7,
  startedAt: DateTime.utc(2026, 8, 16, 4),
  finishedAt: DateTime.utc(2026, 8, 16, 5),
  state: 'done',
  masters: [
    DawnMasterReport(
      master: _master(seconds),
      targetName: null,
      stats: DawnMasterStats.unrecorded,
      draft: const DawnDraft(
        baseMasterRef: '/masters/m42_l.fits',
        steps: [],
        notes: [],
      ),
      recipeId: 1,
      draftRenderPath: '/drafts/m42_l.png',
      failure: null,
    ),
  ],
  withoutFile: const [],
  delivery: null,
  deliveryProblems: const [],
  notification: null,
  failure: null,
);

void main() {
  test('a sub-minute night states its seconds, never "0m"', () {
    expect(DurationFormat.seconds(24.0, style: DurationStyle.coarse, roundToMinute: true), '24s');
    expect(DurationFormat.seconds(1.0, style: DurationStyle.coarse, roundToMinute: true), '1s');
    // A fraction of a second rounds UP so it can never land back on the 0 the
    // zero branch owns.
    expect(DurationFormat.seconds(0.4, style: DurationStyle.coarse, roundToMinute: true), '1s');
  });

  test('a whole minute and above is unchanged', () {
    expect(DurationFormat.seconds(60.0, style: DurationStyle.coarse, roundToMinute: true), '1m');
    // 59.9s ceilings to 60 seconds, which is a minute — not "60 s".
    expect(DurationFormat.seconds(59.9, style: DurationStyle.coarse, roundToMinute: true), '1m');
    expect(DurationFormat.seconds(2520.0, style: DurationStyle.coarse, roundToMinute: true), '42m');
    expect(DurationFormat.seconds(11520.0, style: DurationStyle.coarse, roundToMinute: true), '3h 12m');
  });

  test('the morning headline for a 24 s night does not read "0m"', () {
    final headline = _report(24.0).headline;
    expect(headline, contains('24s integrated'));
    expect(headline, isNot(contains('0m')));
  });
}
