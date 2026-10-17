import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/collaborative_sky/collaborative_sky_format.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('mosaicCompletionFraction', () {
    test('clamps and divides', () {
      expect(mosaicCompletionFraction(uploaded: 0, total: 12), 0.0);
      expect(mosaicCompletionFraction(uploaded: 6, total: 12), 0.5);
      expect(mosaicCompletionFraction(uploaded: 12, total: 12), 1.0);
    });

    test('guards a zero or negative total', () {
      expect(mosaicCompletionFraction(uploaded: 3, total: 0), 0.0);
      expect(mosaicCompletionFraction(uploaded: 3, total: -1), 0.0);
    });

    test('never exceeds 1', () {
      expect(mosaicCompletionFraction(uploaded: 20, total: 12), 1.0);
    });
  });

  group('formatPanelProgress', () {
    test('pluralises the unit', () {
      expect(formatPanelProgress(uploaded: 7, total: 12), '7 of 12 panels');
      expect(formatPanelProgress(uploaded: 0, total: 1), '0 of 1 panel');
    });
  });

  group('formatRigCount', () {
    test('pluralises rigs', () {
      expect(formatRigCount(1), '1 rig');
      expect(formatRigCount(4), '4 rigs');
    });
  });

  group('formatContributorCredits', () {
    test('returns the empty label when no one is credited', () {
      expect(
        formatContributorCredits(const [null, '', '  ']),
        'No contributors yet',
      );
      expect(
        formatContributorCredits(const [], emptyLabel: '4 rigs'),
        '4 rigs',
      );
    });

    test('renders a single name verbatim', () {
      expect(formatContributorCredits(const ['Ada']), 'Ada');
    });

    test('de-duplicates and joins with an ampersand', () {
      expect(
        formatContributorCredits(const ['Ada', 'Carl', 'Ada']),
        'Ada & Carl',
      );
      expect(
        formatContributorCredits(const ['Ada', 'Carl', 'Priya']),
        'Ada, Carl & Priya',
      );
    });

    test('caps the list with an "+N others" tail', () {
      expect(
        formatContributorCredits(const ['Ada', 'Carl', 'Priya', 'Bo', 'Mei']),
        'Ada, Carl, Priya & 2 others',
      );
      expect(
        formatContributorCredits(const ['Ada', 'Carl', 'Priya', 'Bo']),
        'Ada, Carl, Priya & 1 other',
      );
    });
  });

  group('formatMosaicStatus', () {
    test('maps the hub lifecycle words', () {
      expect(formatMosaicStatus('open'), 'Open for panels');
      expect(formatMosaicStatus('assembling'), 'Assembling');
      expect(formatMosaicStatus('complete'), 'Complete');
      expect(formatMosaicStatus('weird'), 'Open for panels');
    });
  });

  group('formatSessionStatus', () {
    test('reads closed first', () {
      expect(
        formatSessionStatus(active: false, batonHolderDisplayName: 'Ada'),
        'Closed',
      );
    });

    test('names the active imager when the baton is held', () {
      expect(
        formatSessionStatus(active: true, batonHolderDisplayName: 'Ada'),
        'Live · Ada imaging now',
      );
    });

    test('falls back to awaiting when the baton is free', () {
      expect(
        formatSessionStatus(active: true, batonHolderDisplayName: null),
        'Live · awaiting an imager',
      );
      expect(
        formatSessionStatus(active: true, batonHolderDisplayName: '  '),
        'Live · awaiting an imager',
      );
    });
  });

  group('mosaicContributorCredits', () {
    CollabMosaic mosaicWith({
      String? owner = 'Owner',
      List<String?> uploadedPanelNames = const [],
    }) {
      return CollabMosaic.fromJson({
        'mosaicId': 'mos-1',
        'ownerDisplayName': owner,
        'name': 'M31',
        'rows': 2,
        'cols': 2,
        'status': 'open',
        'panels': [
          for (var i = 0; i < uploadedPanelNames.length; i++)
            {
              'panelIndex': i,
              'status': 'uploaded',
              'assignedDisplayName': uploadedPanelNames[i],
              'uploaded': true,
            },
        ],
      });
    }

    ArtifactAttribution attributionWith(List<String> names) {
      return ArtifactAttribution.fromJson({
        'artifactType': 'mosaic',
        'artifactRef': 'mos-1',
        'contributors': [
          for (final n in names) {'displayName': n, 'anonymous': false},
        ],
      });
    }

    test('prefers the authoritative attribution over embedded names', () {
      final credits = mosaicContributorCredits(
        mosaicWith(owner: 'Owner', uploadedPanelNames: ['LocalOnly']),
        attribution: attributionWith(['Ada', 'Anonymous contributor']),
      );
      // The hub's consent-aware list wins — the embedded 'LocalOnly' name is
      // never trusted once attribution is available.
      expect(credits, 'Ada & Anonymous contributor');
    });

    test(
        'falls back to embedded owner + panel names when attribution is '
        'null (still loading)', () {
      final credits = mosaicContributorCredits(
        mosaicWith(owner: 'Owner', uploadedPanelNames: ['Ada']),
        attribution: null,
      );
      expect(credits, 'Owner & Ada');
    });

    test('falls back when the hub has no attribution on record yet', () {
      final credits = mosaicContributorCredits(
        mosaicWith(owner: 'Owner'),
        attribution: attributionWith(const []),
      );
      expect(credits, 'Owner');
    });
  });

  group('sessionContributorCredits', () {
    CoImagingSession sessionWith(List<String?> participantNames) {
      return CoImagingSession.fromJson({
        'sessionId': 'sess-1',
        'targetName': 'M42',
        'status': 'active',
        'participants': [
          for (final n in participantNames)
            {'rigId': 'rig-$n', 'displayName': n},
        ],
      });
    }

    test('prefers the authoritative attribution over the roster', () {
      final credits = sessionContributorCredits(
        sessionWith(['LocalRig']),
        rigCount: 1,
        attribution: ArtifactAttribution.fromJson({
          'contributors': [
            {'displayName': 'Ada', 'anonymous': false},
            {'displayName': 'Anonymous contributor', 'anonymous': true},
          ],
        }),
      );
      expect(credits, 'Ada & Anonymous contributor');
    });

    test('falls back to the roster names when attribution is null', () {
      final credits = sessionContributorCredits(
        sessionWith(['Ada', 'Carl']),
        rigCount: 2,
        attribution: null,
      );
      expect(credits, 'Ada & Carl');
    });

    test('uses the rig-count label when no one is credited yet', () {
      final credits = sessionContributorCredits(
        sessionWith(const []),
        rigCount: 3,
        attribution: ArtifactAttribution.fromJson(const {'contributors': []}),
      );
      expect(credits, '3 rigs');
    });
  });
}
