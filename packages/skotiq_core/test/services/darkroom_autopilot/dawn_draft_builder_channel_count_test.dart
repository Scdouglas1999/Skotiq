// The draft's own account of why it left the colour step out, read the way the
// operator reads it in the Darkroom's Recipe panel.
//
// The panel printed 'this master has 1 channel(s) and the colour fit needs
// three' while the start offer 200px away on the same screen printed 'This
// linear master is 1920×1080, 1 channel.' — two vocabularies for one number.
// The count is known at the moment the sentence is written, so the sentence
// says it.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A Darkroom seam that answers the registry and nothing else.
///
/// A draft whose only step is `color_calibrate` never reaches a preview: the
/// colour proof drops the step before any render is issued, which is exactly
/// the path under test.
class _RegistryOnlyDarkroom implements DarkroomSeam {
  _RegistryOnlyDarkroom(this.masterPath);

  final String masterPath;

  @override
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args) async {
    return {
      'draft': {
        'recipe': {
          'baseMasterRef': masterPath,
          'steps': [
            {
              'opId': 'color_calibrate',
              'opVersion': 1,
              'params': <String, dynamic>{},
              'enabled': true,
            },
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

DawnMaster _master({required int channels}) {
  return DawnMaster(
    masterId: 4,
    targetId: 1,
    name: 'Master · B',
    filter: 'B',
    masterFitsPath: '/captures/masters/master-b.fits',
    channels: channels,
    width: 1920,
    height: 1080,
    frameCount: 32,
    totalIntegrationSeconds: 960,
  );
}

Future<String> _colourOmissionReason(int channels) async {
  final master = _master(channels: channels);
  final draft =
      await DawnDraftBuilder(
        darkroom: _RegistryOnlyDarkroom(master.masterFitsPath),
      ).build(
        master: master,
        recipeId: 'recipe-1',
        photometry: const DawnPhotometry.resolved([]),
        renderId: 'render-1',
      );
  return draft.notes
      .firstWhere(
        (note) => note.opId == 'color_calibrate' && note.outcome == 'omitted',
      )
      .reason;
}

void main() {
  test('a mono master is one channel, not "1 channel(s)"', () async {
    final reason = await _colourOmissionReason(1);

    expect(reason, contains('this master has 1 channel and'));
    expect(reason, isNot(contains('channel(s)')));
  });

  test('a master with more channels than one says channels', () async {
    // Four channels is a base the colour fit still cannot take — it wants
    // exactly three — so the same sentence is written with a plural count.
    final reason = await _colourOmissionReason(4);

    expect(reason, contains('this master has 4 channels and'));
  });
}
