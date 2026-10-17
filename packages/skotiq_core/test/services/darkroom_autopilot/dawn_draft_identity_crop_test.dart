// A draft carries a crop only when the rectangle actually crops something.
//
// `crop@1`'s auto rectangle is the area every registered frame covers. A night
// whose frames all landed on the same pixels — an undithered run, and every
// simulated master — leaves that rectangle equal to the frame, and the draft
// then wrote `{x: 0, y: 0, width: 1920, height: 1080}` over a 1920×1080 master.
// Its card read "Crop · Applied by the last render" over an operation that
// moved no pixel, which is the same "step that changes nothing" the draft
// already refuses to carry for `saturation` and `curves`.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A Darkroom seam that answers the registry with one crop step.
///
/// A draft whose only step is the crop never reaches a preview: nothing here
/// retries a background fit or proves a colour balance, so the composition is
/// the identity rule and nothing else.
class _CropOnlyDarkroom implements DarkroomSeam {
  _CropOnlyDarkroom({required this.masterPath, required this.rect});

  final String masterPath;
  final Map<String, dynamic> rect;

  @override
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args) async {
    return {
      'draft': {
        'recipe': {
          'baseMasterRef': masterPath,
          'steps': [
            {'opId': 'crop', 'opVersion': 1, 'params': rect, 'enabled': true},
          ],
        },
        'notes': <Map<String, dynamic>>[],
      },
    };
  }

  @override
  Future<DarkroomRenderedPreview> renderPreview({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    throw StateError('this draft issues no preview');
  }

  @override
  Future<Map<String, dynamic>> renderExport({
    required String recipeJson,
    required Map<String, dynamic> args,
  }) async {
    throw StateError('this draft issues no export');
  }

  @override
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    throw StateError('this draft issues no validation');
  }

  @override
  Future<Map<String, dynamic>> cancel(Map<String, dynamic> args) async => {};
}

const _master = DawnMaster(
  masterId: 4,
  targetId: 1,
  name: 'Master · B',
  filter: 'B',
  masterFitsPath: '/captures/masters/master-b.fits',
  channels: 1,
  width: 1920,
  height: 1080,
  frameCount: 32,
  totalIntegrationSeconds: 960,
);

Future<DawnDraft> _draftWithCrop(Map<String, dynamic> rect) {
  return DawnDraftBuilder(
    darkroom: _CropOnlyDarkroom(masterPath: _master.masterFitsPath, rect: rect),
  ).build(
    master: _master,
    recipeId: 'recipe-1',
    photometry: const DawnPhotometry.resolved([]),
    renderId: 'render-1',
  );
}

void main() {
  group('darkroomCropIsIdentity', () {
    test('the whole frame is the identity', () {
      expect(
        darkroomCropIsIdentity(
          {'x': 0, 'y': 0, 'width': 1920, 'height': 1080},
          width: 1920,
          height: 1080,
        ),
        isTrue,
      );
    });

    test('a rectangle that trims one row is not', () {
      expect(
        darkroomCropIsIdentity(
          {'x': 0, 'y': 0, 'width': 1920, 'height': 1079},
          width: 1920,
          height: 1080,
        ),
        isFalse,
      );
    });

    test('an offset rectangle of full size is not', () {
      expect(
        darkroomCropIsIdentity(
          {'x': 4, 'y': 0, 'width': 1920, 'height': 1080},
          width: 1920,
          height: 1080,
        ),
        isFalse,
      );
    });

    test('a rectangle it cannot read is not claimed to be the identity', () {
      // Each of these is a rectangle whose emptiness this cannot prove, and a
      // draft that dropped a step on a guess would remove a crop the registry
      // meant.
      expect(
        darkroomCropIsIdentity(
          {'x': 0, 'y': 0, 'width': 1920},
          width: 1920,
          height: 1080,
        ),
        isFalse,
        reason: 'a missing edge is not a full-frame rectangle',
      );
      expect(
        darkroomCropIsIdentity(
          {'x': 0, 'y': 0, 'width': '1920', 'height': 1080},
          width: 1920,
          height: 1080,
        ),
        isFalse,
        reason: 'a non-numeric edge is not a full-frame rectangle',
      );
      expect(
        darkroomCropIsIdentity(
          {'x': 0, 'y': 0, 'width': 1920.5, 'height': 1080},
          width: 1920,
          height: 1080,
        ),
        isFalse,
        reason: 'a fractional edge is not a whole-pixel full frame',
      );
      expect(
        darkroomCropIsIdentity(
          {'x': 0, 'y': 0, 'width': 0, 'height': 0},
          width: 0,
          height: 0,
        ),
        isFalse,
        reason: 'a master with no dimensions cannot answer the question',
      );
    });
  });

  test('a full-frame crop is left out, and the draft says why', () async {
    final draft = await _draftWithCrop({
      'x': 0,
      'y': 0,
      'width': 1920,
      'height': 1080,
    });

    expect(
      draft.indexOfOp('crop'),
      -1,
      reason: 'the rectangle is the whole master, so the step renders nothing',
    );
    final note = draft.notes.singleWhere((n) => n.opId == 'crop');
    expect(note.outcome, 'omitted');
    expect(note.reason, contains('whole 1920×1080 frame'));
    expect(
      note.reason,
      contains('changes no pixel'),
      reason: 'the account states the rule it applied, not just the outcome',
    );
  });

  test('a crop that trims the registration edge is carried', () async {
    final draft = await _draftWithCrop({
      'x': 8,
      'y': 6,
      'width': 1900,
      'height': 1060,
    });

    expect(draft.indexOfOp('crop'), 0);
    expect(
      draft.steps.single['params'],
      {'x': 8, 'y': 6, 'width': 1900, 'height': 1060},
      reason: 'the rectangle the registry measured is carried unchanged',
    );
    final note = draft.notes.singleWhere((n) => n.opId == 'crop');
    expect(note.outcome, 'included');
  });
}
