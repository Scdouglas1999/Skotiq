// The headline's two numbers have to be about the same thing.
//
// One night, 4 masters of 3 frames and 6 s each, one master that produced no
// draft. When that master was UNREADABLE it stayed in `masters` and kept
// contributing its seconds, so the report read "Your 3 drafts are ready — 24 s
// integrated" — a draft count that excludes it beside a total that includes it.
// When the same master merely had NO PATH it was diverted to
// `mastersWithoutFile` and the same night read "18 s integrated". Two numbers
// for one practical outcome, decided by which way the master failed.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

DawnMaster _master(int id, String filter) => DawnMaster(
  masterId: id,
  targetId: null,
  name: 'Master · $filter',
  filter: filter,
  masterFitsPath: '/masters/session_$filter.fits',
  channels: 1,
  width: 100,
  height: 100,
  frameCount: 3,
  totalIntegrationSeconds: 6.0,
);

DawnMasterReport _drafted(int id, String filter) => DawnMasterReport(
  master: _master(id, filter),
  targetName: null,
  stats: DawnMasterStats.unrecorded,
  draft: DawnDraft(
    baseMasterRef: '/masters/session_$filter.fits',
    steps: const [],
    notes: const [],
  ),
  recipeId: id,
  draftRenderPath: '/drafts/session_$filter.jpg',
  failure: null,
);

/// A master whose pixels could not be read: no draft, no recipe, and it stays
/// in `masters` because the night did integrate it.
DawnMasterReport _unreadable(int id, String filter) => DawnMasterReport(
  master: _master(id, filter),
  targetName: null,
  stats: DawnMasterStats.unrecorded,
  draft: null,
  recipeId: null,
  draftRenderPath: null,
  failure:
      "cannot read '/masters/session_$filter.fits' as FITS: IO error: failed "
      'to fill whole buffer',
);

DawnJobReport _report({
  required List<DawnMasterReport> masters,
  List<DawnMasterWithoutFile> withoutFile = const [],
}) => DawnJobReport(
  jobId: 2,
  kind: 'dawn',
  sessionId: 1,
  startedAt: DateTime.utc(2026, 8, 18, 4),
  finishedAt: DateTime.utc(2026, 8, 18, 5),
  state: 'done',
  masters: masters,
  withoutFile: withoutFile,
  delivery: null,
  deliveryProblems: const [],
  notification: null,
  failure: null,
);

void main() {
  test('the headline counts the integration behind the drafts it names', () {
    final report = _report(
      masters: [
        _drafted(1, 'B'),
        _drafted(2, 'G'),
        _drafted(3, 'R'),
        _unreadable(4, 'L'),
      ],
    );

    expect(
      report.headline,
      'Your 3 drafts are ready — 18 s integrated; 1 master has no draft '
      '(6 s more integrated)',
    );
    expect(report.draftsRendered, 3);
    expect(report.draftedIntegrationSeconds, 18.0);
    // The night's own total is unchanged — it is what the session integrated,
    // and the report body and JSON still carry it.
    expect(report.integrationSeconds, 24.0);
    expect(report.body, contains('cannot read'));
    expect(report.toJson()['integrationSeconds'], 24.0);
    expect(report.toJson()['draftedIntegrationSeconds'], 18.0);
  });

  test('both ways of losing one master read the same in the headline', () {
    final unreadable = _report(
      masters: [
        _drafted(1, 'B'),
        _drafted(2, 'G'),
        _drafted(3, 'R'),
        _unreadable(4, 'L'),
      ],
    );
    final withoutFile = _report(
      masters: [_drafted(1, 'B'), _drafted(2, 'G'), _drafted(3, 'R')],
      withoutFile: const [
        DawnMasterWithoutFile(
          masterId: 4,
          name: 'Master · L',
          reason:
              'this master row records no linear FITS path, so there are no '
              'pixels to render a draft from',
        ),
      ],
    );

    expect(unreadable.headline, startsWith('Your 3 drafts are ready — 18 s'));
    expect(withoutFile.headline, startsWith('Your 3 drafts are ready — 18 s'));
    // A master with no file recorded no seconds anywhere, so the clause states
    // the master without inventing an integration total for it.
    expect(
      withoutFile.headline,
      'Your 3 drafts are ready — 18 s integrated; 1 master has no draft',
    );
  });

  test('a night whose masters all drafted says nothing extra', () {
    final report = _report(masters: [_drafted(1, 'B'), _drafted(2, 'G')]);

    expect(report.headline, 'Your 2 drafts are ready — 12 s integrated');
    expect(report.draftedIntegrationSeconds, report.integrationSeconds);
  });

  test('a night that drafted nothing still states what it integrated', () {
    final report = _report(masters: [_unreadable(1, 'L')]);

    expect(
      report.headline,
      'Your night — no draft was rendered; 6 s integrated',
    );
    expect(report.draftedIntegrationSeconds, 0.0);
  });

  test('a named target carries the same scoped total and clause', () {
    final report = _report(
      masters: [
        DawnMasterReport(
          master: _master(1, 'B'),
          targetName: 'NGC 7000',
          stats: DawnMasterStats.unrecorded,
          draft: const DawnDraft(
            baseMasterRef: '/masters/session_B.fits',
            steps: [],
            notes: [],
          ),
          recipeId: 1,
          draftRenderPath: '/drafts/session_B.jpg',
          failure: null,
        ),
        DawnMasterReport(
          master: _master(2, 'L'),
          targetName: 'NGC 7000',
          stats: DawnMasterStats.unrecorded,
          draft: null,
          recipeId: null,
          draftRenderPath: null,
          failure: 'the draft render stopped',
        ),
      ],
    );

    expect(
      report.headline,
      'NGC 7000 — 6 s integrated; 1 master has no draft (6 s more integrated)',
    );
  });
}
