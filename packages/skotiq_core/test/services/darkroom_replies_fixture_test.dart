// The Darkroom reply models read the replies the native side writes: the
// registry and export samples in test_fixtures/ffi_replies/ are real engine
// replies over a synthetic master (processing/src/darkroom/tests.rs), the
// master-build sample is serialized from the builder's reply type.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

import '../harness/reply_fixture.dart';

void main() {
  test("a registry reply's draft names the recipe, its steps and notes", () {
    final reply = replyFixtureObject('darkroom_registry');
    final draft = DarkroomRegistryDraft.of(reply)!;
    final sample = (reply['draft'] as Map<String, dynamic>);
    final recipe = sample['recipe'] as Map<String, dynamic>;
    expect(draft.recipe, recipe);
    expect(draft.steps, recipe['steps']);
    expect(draft.steps, isNotEmpty);
    final notes = (sample['notes'] as List).cast<Map<String, dynamic>>();
    expect(draft.notes.map((n) => n.opId), [for (final n in notes) n['opId']]);
    expect(draft.notes.map((n) => n.outcome), [
      for (final n in notes) n['outcome'],
    ]);
    expect(draft.notes.map((n) => n.reason), [
      for (final n in notes) n['reason'],
    ]);
    final stretch = (recipe['steps'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['opId'] == 'stretch');
    expect(draft.paramsOf('stretch'), stretch['params']);
    expect(draft.paramsOf('stretch'), contains('blackPoint'));
  });

  test('a registry reply without a master carries no draft', () {
    final reply = Map<String, dynamic>.of(
      replyFixtureObject('darkroom_registry'),
    )..remove('draft');
    expect(DarkroomRegistryDraft.of(reply), isNull);
  });

  test('an export reply names every file it wrote', () {
    final reply = replyFixtureObject('darkroom_render_export');
    final (export, unread) = decodeRecordingReads(
      reply,
      DarkroomExportReply.fromJson,
    );
    // The sheet reports the files, the sidecar, the source pixels, the screen
    // transfer and the fingerprint; the rest describes the render itself.
    expect(unread, {
      'base',
      'base.channels',
      'base.height',
      'base.level',
      'base.levelCount',
      'base.scaleFromMaster',
      'base.width',
      'catalogStars',
      'historyCardCount',
      'masterPath',
      'outputs[].bitsPerSample',
      'outputs[].channels',
      'outputs[].pixelType',
      'recipeSchemaVersion',
      'renderId',
      'report',
      'report.cacheHits',
      'report.cacheMisses',
      'report.hasSkips',
      'report.level',
      'report.resumedAt',
      'report.steps',
      'report.steps[].index',
      'report.steps[].opId',
      'report.steps[].opVersion',
      'report.steps[].outcome',
      'screenTransferAffectsRecipe',
      'stage',
      'stage.index',
      'stage.kind',
    });
    final outputs = (reply['outputs'] as List).cast<Map<String, dynamic>>();
    expect(export.outputs, hasLength(outputs.length));
    for (var i = 0; i < outputs.length; i++) {
      final o = export.outputs[i];
      expect(o.format, outputs[i]['format']);
      expect(o.path, outputs[i]['path']);
      expect(o.bytes, outputs[i]['bytes']);
      expect(o.width, outputs[i]['width']);
      expect(o.height, outputs[i]['height']);
      expect(o.clampedSamples, outputs[i]['clampedSamples']);
      expect(o.quality, outputs[i]['quality']);
    }
    expect(export.outputs.last.quality, isNotNull);
    expect(export.sidecarPath, reply['sidecarPath']);
    expect(export.sidecarSkippedReason, reply['sidecarSkippedReason']);
    expect(export.sidecarSkippedReason, isNotEmpty);
    expect(export.sourceDomain, reply['sourceDomain']);
    expect(export.screenTransferApplied, reply['screenTransfer'] != null);
    expect(export.recipeFingerprint, reply['recipeFingerprint']);
  });

  test("a filter build reads the builder's reply for it", () {
    final reply = replyFixtureObject('master_build');
    final build = DarkroomFilterBuild.fromJson(reply);
    expect(build.filter, reply['filter']);
    expect(build.error, isNull);
    expect(build.frameCount, reply['frameCount']);
    expect(
      build.totalIntegrationSec,
      (reply['totalIntegrationSec'] as num).toDouble(),
    );
    expect(build.skippedCount, (reply['skipped'] as List).length);
  });

  test('a failed filter reads as its failure', () {
    final failed = DarkroomFilterBuild.fromJson({
      'filter': 'OIII',
      'error': 'too few frames',
    });
    expect(failed.filter, 'OIII');
    expect(failed.error, 'too few frames');
    expect(failed.frameCount, isNull);
    expect(failed.skippedCount, isNull);
  });

  test('a cancelled post-session run reads as a cancellation', () {
    final payload = replyFixtureObject('post_session_cancelled');
    final outcome = DarkroomCancelledOutcome.tryDecode(
      'post-session failed: ${jsonEncode(payload)}',
    )!;
    expect(outcome.id, payload['runId']);
    expect(outcome.phase, payload['stage']);
    expect(outcome.payload, payload);
  });

  test('a registration preview reads back to the native reply', () {
    final reply = replyFixtureObject('registration_preview');
    final preview = DarkroomRegistrationPreview.fromJson(reply);
    expect(jsonDecode(jsonEncode(preview.toJson())), reply);
    expect(preview.meetsMinimum, reply['meetsMinimum']);
    expect(preview.limiting, hasLength((reply['limiting'] as List).length));
  });
}
