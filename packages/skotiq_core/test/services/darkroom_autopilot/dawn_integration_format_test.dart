// The one line the operator reads at 7am has to distinguish a short night from
// an empty one.
//
// `formatDawnIntegration` rounds to whole minutes, and the report headline is
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
  test('a night that integrated nothing keeps the zero sentinel', () {
    expect(formatDawnIntegration(0), '0m');
    expect(formatDawnIntegration(-1), '0m');
  });

  test('a sub-minute night states its seconds, never "0m"', () {
    expect(formatDawnIntegration(24.0), '24 s');
    expect(formatDawnIntegration(1.0), '1 s');
    // A fraction of a second rounds UP so it can never land back on the 0 the
    // zero branch owns.
    expect(formatDawnIntegration(0.4), '1 s');
  });

  test('a whole minute and above is unchanged', () {
    expect(formatDawnIntegration(60.0), '1m');
    // 59.9s ceilings to 60 seconds, which is a minute — not "60 s".
    expect(formatDawnIntegration(59.9), '1m');
    expect(formatDawnIntegration(2520.0), '42m');
    expect(formatDawnIntegration(11520.0), '3h 12m');
  });

  test('the morning headline for a 24 s night does not read "0m"', () {
    final headline = _report(24.0).headline;
    expect(headline, contains('24 s integrated'));
    expect(headline, isNot(contains('0m')));
  });
}
