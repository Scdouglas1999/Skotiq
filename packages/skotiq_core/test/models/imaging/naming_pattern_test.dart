import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/src/backend/skotiq_exception.dart'
    show ValidationException;
import 'package:skotiq_core/src/services/imaging_service.dart';

final _runTokens =
    jsonDecode(
          File(
            '../../test_fixtures/frame_naming/run_tokens.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

NamingStep _step(FrameType frameType) => NamingStep(
  frameType: frameType,
  gain: 100,
  offset: 10,
  binX: 1,
  binY: 1,
  session: DateTime.utc(2026, 11, 13, 4),
);

NamingFrame _frame({String? target, String? filter}) => NamingFrame(
  target: target,
  filter: filter,
  exposureSeconds: 1,
  number: 1,
  takenAt: DateTime.utc(2026, 11, 13, 4),
);

/// Patterns with good, unknown-token, traversal, absolute, empty and
/// unsafe-character cases.
const _corpus = <String>[
  r'$TARGET_$FILTER_$DATE_$SEQ',
  r'$TARGET/$FRAMETYPE/$TARGET_$FILTER_$EXPTIME_$FRAMENUM',
  r'$SESSION/$CAMERA/$TELESCOPE_$BINNING_$GAIN_$OFFSET_$TEMP_$FRAMENUM',
  r'$DATETIME_$TIME_$EXPOSURE_$SEQUENCE',
  'literal_name',
  r'$TARGET_$BANANA',
  r'$NOPE',
  r'../../../pwned/$NOPE',
  r'../$TARGET',
  r'$TARGET/../$FILTER',
  r'/abs/$TARGET',
  r'C:\abs\$TARGET',
  '',
  '   ',
  r'$TARGET//$FILTER',
  r'$TARGET:$FILTER',
  r'$TARGET\$FILTER',
  r'$target',
  r'$TARGET$',
];

void main() {
  test('a run fills in the per-frame tokens the sequencer resolves', () {
    final placeholders = (_runTokens['run_placeholders'] as Map)
        .cast<String, String>();
    expect({
      for (final token in NamingToken.values)
        if (token.runPlaceholder != null) token.text: token.runPlaceholder,
    }, placeholders);
  });

  test('a token has a run placeholder exactly when the step cannot fix it', () {
    for (final token in NamingToken.values) {
      for (final frameType in FrameType.values) {
        expect(
          token.valueFor(_step(frameType)) == null,
          token.runPlaceholder != null,
          reason: token.text,
        );
        expect(token.valueFor(_step(frameType), _frame()), isNotNull);
      }
    }
  });

  test('a frame with no filter or target gets the run\'s labels', () {
    expect(NamingPattern.noFilterLabel, _runTokens['no_filter_label']);
    final labels = (_runTokens['no_target_label'] as Map)
        .cast<String, String>();
    for (final frameType in FrameType.values) {
      expect(
        NamingPattern.noTargetLabel(frameType),
        labels[frameType.imageType],
        reason: frameType.imageType,
      );
    }
  });

  test('a manual dark with no filter or target lands in the run\'s folder', () {
    const pattern = r'$TARGET/$FILTER/$FRAMETYPE_$FRAMENUM';
    final manual = NamingPattern.segments(
      pattern,
      NamingPattern.values(_step(FrameType.dark), _frame(filter: '  ')),
    );
    final labels = (_runTokens['no_target_label'] as Map)
        .cast<String, String>();
    expect(manual, [
      labels['Dark'],
      _runTokens['no_filter_label'],
      'dark_0001',
    ]);
    expect(
      NamingPattern.runTemplate(pattern, _step(FrameType.dark)),
      r'${target.name}/${filter}/dark_${frame:04}',
    );
  });

  test('the editor accepts every token and nothing else', () {
    for (final token in NamingToken.values) {
      expect(
        NamingPattern.check(token.text).isValid,
        isTrue,
        reason: token.text,
      );
    }
    expect(
      NamingPattern.check(r'$TARGET_$BANANA').error,
      allOf(contains(r'Unknown variable $BANANA'), contains(r'$SESSION')),
    );
  });

  group('the editor decides as the capture pipeline does', () {
    final now = DateTime.utc(2026, 8, 3, 21, 34, 56);
    final values = ImagingService.manualFrameValues(
      exposureSettings: const ExposureSettings(
        exposureTime: 120,
        gain: 100,
        offset: 10,
        filter: 'L',
      ),
      targetName: 'M31',
      frameNumber: 1,
      timestamp: now,
      sensorTempC: -10,
    );
    String? pipelinePath(String pattern) {
      try {
        return ImagingService.buildImageFilePath(
          pattern: pattern,
          basePath: '/base',
          extension: 'fits',
          values: values,
          pathContext: p.posix,
        );
      } on ValidationException {
        return null;
      }
    }

    for (final pattern in _corpus) {
      test('"$pattern"', () {
        expect(
          NamingPattern.check(pattern, now: now).isValid,
          pipelinePath(pattern) != null,
        );
      });
    }

    test('the preview is the example frame\'s path', () {
      expect(
        NamingPattern.check(
          r'$TARGET/$FILTER_$DATE_$FRAMENUM',
          now: now,
        ).preview,
        'M31/L_2026-08-03_0001.fits',
      );
    });
  });
}
