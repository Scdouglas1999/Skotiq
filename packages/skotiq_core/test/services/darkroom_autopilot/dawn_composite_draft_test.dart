// The color composite draft: what the builder asks the engine for, how it
// proves the color step on a field with no catalog photometry, and that the
// stretch it re-measures stays a color-preserving one.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

const _referencePath = '/masters/ngc891_L.fits';

DawnMaster _master(int id, String filter) => DawnMaster(
  masterId: id,
  targetId: 7,
  name: 'NGC 891 · $filter',
  filter: filter,
  masterFitsPath: '/masters/ngc891_$filter.fits',
  channels: 1,
  width: 4656,
  height: 3520,
  frameCount: 16,
  totalIntegrationSeconds: 1800,
);

final _masters = [
  _master(1, 'L'),
  _master(2, 'R'),
  _master(3, 'G'),
  _master(4, 'B'),
];

/// A Darkroom seam scripted with the engine's composite answers.
class _CompositeDarkroom implements DarkroomSeam {
  _CompositeDarkroom({this.combined = true});

  final bool combined;
  final registryCalls = <Map<String, dynamic>>[];
  final previewCalls =
      <({Map<String, dynamic> recipe, Map<String, dynamic> context})>[];

  @override
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args) async {
    registryCalls.add(args);
    if (!combined) {
      return {
        'composite': {
          'combined': false,
          'reason':
              'a color image needs red, green and blue masters and this set '
              'has no B master',
        },
      };
    }
    return {
      'masterPath': _referencePath,
      'base': {'width': 4656, 'height': 3520, 'channels': 1},
      'composite': {
        'combined': true,
        'palette': 'lrgb',
        'paletteName': 'LRGB',
        'reason': 'LRGB from L, R, G and B',
        'reference': {'filter': 'L', 'path': _referencePath},
        'worstMedianOffsetPx': 0.19,
      },
      'draft': {
        'recipe': {
          'baseMasterRef': _referencePath,
          'steps': [
            {
              'opId': 'channel_combine',
              'opVersion': 1,
              'params': {'palette': 'lrgb'},
              'enabled': true,
            },
            {
              'opId': 'background_extract',
              'opVersion': 1,
              'params': {'modelOrder': 3},
              'enabled': true,
            },
            {
              'opId': 'color_calibrate',
              'opVersion': 1,
              'params': {'neutralizeBackground': true},
              'enabled': true,
            },
            {
              'opId': 'denoise',
              'opVersion': 1,
              'params': <String, dynamic>{},
              'enabled': true,
            },
            {
              'opId': 'stretch',
              'opVersion': 1,
              'params': {
                'blackPoint': 2000.0,
                'whitePoint': 7000.0,
                'd': 4.0,
                'b': 0.0,
                'symmetryPoint': 0.0,
                'colorMode': 'luminance',
              },
              'enabled': true,
            },
          ],
        },
        'notes': [
          {
            'opId': 'crop',
            'outcome': 'omitted',
            'reason':
                'the channel combination already crops to the area every '
                'master covers',
          },
        ],
      },
    };
  }

  @override
  Future<DarkroomRenderedPreview> renderPreview({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    final recipe = jsonDecode(recipeJson) as Map<String, dynamic>;
    previewCalls.add((recipe: recipe, context: context));
    final stopAfter = context['stopAfter'] as int;
    final Map<String, dynamic> report;
    if (context['encoding'] == 'screen') {
      report = {
        'encoding': {
          'screenTransfer': {
            'blackPoint': 2100.0,
            'whitePoint': 7200.0,
            'd': 4.5,
            'b': 0.0,
            'symmetryPoint': 0.0,
          },
        },
        'report': {'steps': <Map<String, dynamic>>[]},
      };
    } else {
      report = {
        'report': {
          'steps': [
            {
              'index': stopAfter,
              'opId': 'color_calibrate',
              'outcome': 'applied',
              'measured': {
                'source': 'averageStar',
                'channelScale': [0.76, 1.0, 0.57],
                'channelOffset': [266.1, -125.0, -141.1],
                'matchedStars': 3056,
              },
            },
          ],
        },
      };
    }
    return DarkroomRenderedPreview(
      width: 1,
      height: 1,
      isColor: true,
      rgba: Uint8List(4),
      report: report,
    );
  }

  @override
  Future<Map<String, dynamic>> renderExport({
    required String recipeJson,
    required Map<String, dynamic> args,
  }) async => {};

  @override
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async => {};

  @override
  Future<Map<String, dynamic>> cancel(Map<String, dynamic> args) async => {};
}

Future<DawnCompositeDraft> _build(_CompositeDarkroom darkroom) {
  return DawnDraftBuilder(darkroom: darkroom).buildComposite(
    masters: _masters,
    recipeId: 'job-1-composite-7',
    photometry: (_) => const DawnPhotometry.unavailable(
      'this master carries no solved astrometry',
    ),
    renderId: 'render-1',
  );
}

void main() {
  test('the composite request names every master with its filter', () async {
    final darkroom = _CompositeDarkroom();
    await _build(darkroom);

    final inputs =
        (darkroom.registryCalls.single['composite'] as Map)['inputs'] as List;
    expect(inputs, hasLength(4));
    expect(inputs.map((i) => (i as Map)['filter']), ['L', 'R', 'G', 'B']);
    expect((inputs.first as Map)['path'], '/masters/ngc891_L.fits');
  });

  test('with no catalog photometry the color step balances on the field stars '
      'and pins the scales and offsets', () async {
    final darkroom = _CompositeDarkroom();
    final composite = await _build(darkroom);
    final draft = composite.draft!;

    expect(draft.baseMasterRef, _referencePath);
    expect(composite.reference!.filter, 'L');
    final proof = darkroom.previewCalls.firstWhere(
      (c) => c.context['encoding'] == 'unit',
    );
    expect(proof.context['level'], 0);
    expect(proof.context.containsKey('catalogStars'), isFalse);
    final provedStep = (proof.recipe['steps'] as List)[2] as Map;
    expect((provedStep['params'] as Map)['whiteReference'], 'averageStar');

    final color = draft.steps[draft.indexOfOp('color_calibrate')];
    final params = color['params'] as Map<String, dynamic>;
    expect(params['whiteReference'], 'averageStar');
    expect(params['neutralizeBackground'], true);
    expect(params['channelScale'], [0.76, 1.0, 0.57]);
    expect(params['channelOffset'], [266.1, -125.0, -141.1]);

    final note = draft.notes.firstWhere((n) => n.opId == 'color_calibrate');
    expect(note.outcome, 'included');
    expect(note.reason, contains("median color of the field's own stars"));
    expect(note.reason, contains('no solved astrometry'));
  });

  test('the re-measured stretch keeps its color-preserving mode', () async {
    final draft = (await _build(_CompositeDarkroom())).draft!;
    final stretch =
        draft.steps[draft.indexOfOp('stretch')]['params']
            as Map<String, dynamic>;
    expect(stretch['blackPoint'], 2100.0);
    expect(stretch['colorMode'], 'luminance');
    expect(draft.steps.first['opId'], kCompositeOpId);
  });

  test('a set that does not combine returns the reason and no draft', () async {
    final composite = await _build(_CompositeDarkroom(combined: false));
    expect(composite.draft, isNull);
    expect(composite.reference, isNull);
    expect(composite.plan['reason'], contains('no B master'));
  });

  test('the report leads with the color draft and links to it', () {
    final composite = DawnCompositeReport(
      targetName: 'NGC 891',
      masters: _masters,
      plan: const {
        'combined': true,
        'paletteName': 'LRGB',
        'reason': 'LRGB from L, R, G and B',
        'reference': {'filter': 'L'},
        'worstMedianOffsetPx': 0.19,
      },
      recipeId: 42,
      draftRenderPath: '/darkroom/job_1_master_1_lrgb_draft.jpg',
      linearCompositePath: '/darkroom/job_1_master_1_lrgb_linear.fits',
      draftSteps: const [],
      draftNotes: const [],
      failure: null,
    );
    final report = DawnJobReport(
      jobId: 1,
      kind: 'manual',
      sessionId: 71,
      startedAt: DateTime.utc(2026, 10, 21, 12),
      finishedAt: DateTime.utc(2026, 10, 21, 12, 1),
      state: 'done',
      masters: const [],
      composites: [composite],
      withoutFile: const [],
      delivery: null,
      deliveryProblems: const [],
      notification: null,
      failure: null,
    );
    expect(report.colorDraftsRendered, 1);
    expect(
      report.body,
      contains(
        'NGC 891 color draft: LRGB from L, R, G and B. Registered onto L, '
        'stars within 0.19 px.',
      ),
    );
    final json = report.toJson();
    expect(
      json.keys.toList().indexOf('composites'),
      lessThan(json.keys.toList().indexOf('masters')),
    );
    expect(draftDeepLinkFor(report), endsWith(':42'));
  });
}
