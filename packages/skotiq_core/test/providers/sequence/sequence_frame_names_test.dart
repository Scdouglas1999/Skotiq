// A sequence's frames are named by the Settings "File naming pattern", as a
// manual capture is: each capture step's `save_to` is that pattern, with the
// step's own values filled in and the per-frame tokens left to the run.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_core/src/backend/skotiq_exception.dart'
    show ValidationException;

const _pattern =
    r'$SEQUENCE/$TARGET/$FRAMETYPE/$TARGET_$FILTER_$EXPTIME_$GAIN_$FRAMENUM';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(fileNamingPattern: _pattern);
}

Sequence _plan() => Sequence.create(
  id: 'seq',
  name: 'M31: LRGB',
  rootNodeId: 'root',
  nodes: {
    'root': InstructionSetNode(id: 'root', childIds: const ['l', 'smart']),
    'l': ExposureNode(
      id: 'l',
      parentId: 'root',
      durationSecs: 120,
      count: 3,
      filter: 'L',
      gain: 139,
    ),
    'smart': SmartExposureNode(
      id: 'smart',
      parentId: 'root',
      plans: [
        FilterPlan(filterName: 'Ha', count: 2, durationSecs: 300, gain: 200),
      ],
    ),
  },
);

void main() {
  test('every capture step saves its frames by the Settings pattern', () async {
    final container = ProviderContainer(
      overrides: [appSettingsProvider.overrideWith(_Settings.new)],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    final serializer = container.read(
      Provider((ref) => SequenceSerializer(ref: ref, warn: (_) {})),
    );

    final wire = jsonEncode(jsonDecode(serializer.sequenceToJson(_plan())));
    const expose =
        r'M31_ LRGB/${target.name}/light/${target.name}_${filter}_'
        r'${exposure.duration:.1f}_139_${frame:04}';
    const smart =
        r'M31_ LRGB/${target.name}/light/${target.name}_${filter}_'
        r'${exposure.duration:.1f}_200_${frame:04}';
    expect(wire, contains(jsonEncode(expose)));
    expect(wire, contains(jsonEncode(smart)));
  });

  test('every pattern token is filled in by the plan or by the run', () {
    final step = NamingStep(
      frameType: FrameType.dark,
      gain: 1,
      offset: 2,
      binX: 2,
      binY: 2,
      camera: 'Cam',
      telescope: 'Scope',
      sequence: r'Odd ${name}',
      session: DateTime.utc(2026, 11, 12, 23, 59),
    );
    final all = NamingToken.values.map((t) => t.text).join('_');
    final template = ImagingService.runFrameSaveTemplate(all, step);
    expect(template, isNot(contains(RegExp(r'\$[A-Z]'))));
    expect(template, contains(r'Odd $${name}'));
    expect(template, contains('20261112'));
    expect(
      () => ImagingService.runFrameSaveTemplate(r'../$TARGET', step),
      throwsA(isA<ValidationException>()),
    );
  });

  test('a secondary camera names its frames by the same Settings pattern', () {
    expect(
      ImagingService.runFrameSaveTemplate(
        r'$TARGET/$CAMERA_$FRAMETYPE_$GAIN_$BINNING_$EXPTIME_$FRAMENUM',
        NamingStep.secondaryRig(
          rigLabel: 'Wide Field',
          gain: 120,
          offset: null,
          binX: 2,
          binY: 2,
          session: DateTime.utc(2026, 11, 13, 3),
        ),
      ),
      r'${target.name}/Wide Field_light_120_2x2_${exposure.duration:.1f}_'
      r'${frame:04}',
    );
  });

  test('a value is one path segment by the rule the run applies', () {
    final fixture = File(
      '../../test_fixtures/path_segment/cases.json',
    ).readAsStringSync();
    for (final c in (jsonDecode(fixture)['cases'] as List).cast<Map>()) {
      expect(
        NamingPattern.pathSegment(c['value'] as String),
        c['segment'],
        reason: '${c['value']}',
      );
    }
  });
}
