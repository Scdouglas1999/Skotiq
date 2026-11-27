// The editor's operation catalog and combine plan decoders read the replies
// the native registry writes: test_fixtures/ffi_replies/darkroom_registry.json
// and darkroom_composite.json are written by Rust tests from real registry
// replies, so a key renamed in Rust fails here instead of reaching the editor
// as a DarkroomRecipeFormatException or a control with no range.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_controller.dart';
import 'package:skotiq_app/screens/darkroom/edit/channel_combine.dart';

Map<String, dynamic> _reply(String name) => jsonDecode(
      File('../../test_fixtures/ffi_replies/$name.json').readAsStringSync(),
    ) as Map<String, dynamic>;

double? _number(Object? v) => (v as num?)?.toDouble();

void main() {
  test(
      'the catalog decodes every operation and parameter the registry '
      'publishes', () {
    final reply = _reply('darkroom_registry');
    final catalog = decodeDarkroomCatalog(reply);
    final ops = (reply['ops'] as List).cast<Map<String, dynamic>>();
    expect(catalog.ops, hasLength(ops.length));
    for (var i = 0; i < ops.length; i++) {
      final raw = ops[i];
      final op = catalog.ops[i];
      expect(op.id, raw['id']);
      expect(op.version, raw['version']);
      expect(op.stageWire, raw['stage']);
      expect(op.stage, isNot(DarkroomOpStage.unmodelled), reason: op.id);
      expect(op.summary, raw['summary']);
      final params = (raw['params'] as List).cast<Map<String, dynamic>>();
      expect(op.params, hasLength(params.length), reason: op.id);
      for (var j = 0; j < params.length; j++) {
        final p = params[j];
        final spec = op.params[j];
        final where = '${op.id}.${p['name']}';
        expect(spec.name, p['name'], reason: where);
        expect(spec.displayName, p['displayName'], reason: where);
        expect(spec.kindWire, p['kind'], reason: where);
        expect(
          spec.kind,
          isNot(DarkroomParamKind.unrepresented),
          reason: where,
        );
        expect(spec.required, p['required'], reason: where);
        expect(spec.independent, p['independent'], reason: where);
        expect(spec.min, _number(p['min']), reason: where);
        expect(spec.max, _number(p['max']), reason: where);
        expect(spec.length, p['length'], reason: where);
        expect(spec.allowed, p['allowed'] ?? const [], reason: where);
        expect(spec.defaultValue, p['default'], reason: where);
        expect(spec.summary, p['summary'], reason: where);
      }
    }
    final mixes = (reply['channelMixes'] as List).cast<Map<String, dynamic>>();
    expect(catalog.channelMixes, hasLength(mixes.length));
    for (var i = 0; i < mixes.length; i++) {
      expect(catalog.channelMixes[i].palette, mixes[i]['palette']);
      expect(catalog.channelMixes[i].name, mixes[i]['name']);
    }
  });

  test('the combine plan decodes the registry reply to an LRGB set', () {
    final reply = _reply('darkroom_composite');
    final composite = reply['composite'] as Map<String, dynamic>;
    final plan = DarkroomCombinePlan.fromReply(reply);
    expect(plan.combined, isTrue);
    expect(plan.palette!.id, composite['palette']);
    expect(plan.palette!.name, composite['paletteName']);
    expect(plan.reason, composite['reason']);
    expect(
      [for (final a in plan.alternatives) a.id],
      [for (final a in composite['alternatives'] as List) a['palette']],
    );
    expect(plan.excluded, hasLength((composite['excluded'] as List).length));
    expect(plan.referencePath, reply['masterPath']);
    expect(plan.worstOffsetPx, _number(composite['worstMedianOffsetPx']));
    final drafted = reply['draft']['recipe']['steps'] as List;
    expect(plan.steps, hasLength(drafted.length));
  });

  test('the catalog names what each three-channel operation requires', () {
    final catalog = decodeDarkroomCatalog(
      jsonDecode(
        File('../../test_fixtures/darkroom_ops/catalog.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>,
    );
    final requirements = {
      for (final op in catalog.ops)
        if (op.threeChannels != null) op.id: op.threeChannels,
    };
    expect(requirements, {
      'color_calibrate':
          'a color master with 3 channels; combine a per-filter mono master '
              'first',
      'saturation': 'a color master with 3 channels',
      'scnr': 'a color image with 3 channels',
      'chroma_denoise': 'a color image with 3 channels',
    });
  });
}
