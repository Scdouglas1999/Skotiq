import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/integrated_masters_dao.dart';
import 'package:skotiq_core/src/database/daos/recipes_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/live_stacking_models.dart';
import 'package:skotiq_core/src/models/imaging/live_stacking_state.dart';
import 'package:skotiq_core/src/services/frame_header.dart';
import 'package:skotiq_core/src/services/live_stack_darkroom_promotion.dart';
import 'package:skotiq_core/src/services/live_stack_master_library.dart';

void main() {
  late SkotiqDatabase db;
  late IntegratedMastersDao masters;
  late RecipesDao recipes;
  late Directory temp;
  late List<String> saves;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    masters = IntegratedMastersDao(db);
    recipes = RecipesDao(db);
    temp = Directory.systemTemp.createTempSync('live_promote_');
    saves = [];
  });
  tearDown(() async {
    await db.close();
    temp.deleteSync(recursive: true);
  });

  LiveStackingMasterSave fits(String path) => LiveStackingMasterSave(
    filePath: path,
    stackedFrameCount: 12,
    format: LiveStackingMasterFormat.fitsMaster,
    totalIntegrationSecs: 1440,
  );

  const result = LiveStackingResult(
    width: 4,
    height: 3,
    data: [],
    stats: LiveStackingStats(stackedFrameCount: 12),
  );

  LiveStackDarkroomPromoter promoter() => LiveStackDarkroomPromoter(
    library: LiveStackMasterLibrary(
      currentResult: () async => result,
      currentResultForFilter: (_) async => result,
      saveMaster: (path) async {
        saves.add('active $path');
        return fits(path);
      },
      saveMasterForFilter: (filterKey, path) async {
        saves.add('$filterKey $path');
        return fits(path);
      },
      writePreview: (path, _) async => saves.add('preview $path'),
      masters: masters,
      // The frames name another target and filter; Open in Darkroom keeps
      // the session's names.
      readHeader: (_) async =>
          FrameHeader(const {'OBJECT': 'NGC 891', 'FILTER': 'Ha'}),
    ),
    recipes: recipes,
    now: () => DateTime.utc(2026, 11, 22, 3, 4, 5),
    tempDir: () => temp.path,
  );

  FilterStackSnapshot slot(String key, {String? reference}) =>
      FilterStackSnapshot(
        filterKey: key,
        stats: const LiveStackingStats(stackedFrameCount: 12),
        previewWidth: 4,
        previewHeight: 3,
        channels: 1,
        referenceImagePath: reference,
      );

  test('a filter slot is saved beside its reference and named for the '
      'session target', () async {
    final reference = '${temp.path}/lights/L_0001.fits';
    final stack = LiveStackingState(
      status: LiveStackingStatus.running,
      filterStacks: {'L': slot('L', reference: reference)},
      selectedFilterKey: 'L',
    );

    final promoted = await promoter().promote(
      stack: stack,
      filterKey: 'L',
      targetName: ' M31 ',
      recipeSteps: ({required isColor}) => [
        {'op': 'stretch', 'isColor': isColor},
      ],
    );

    final path =
        '${temp.path}/lights/masters/M31_L_2026-11-22T03-04-05Z_12f.fits';
    expect(saves, ['L $path', 'preview ${path.replaceAll('.fits', '.png')}']);
    final row = (await masters.getAll()).single;
    expect(row.previewPngPath, path.replaceAll('.fits', '.png'));
    expect(row.id, promoted.masterId);
    expect(row.name, 'M31 · L · (12 frames)');
    expect(row.filter, 'L');
    expect(row.masterFitsPath, path);
    expect((row.width, row.height, row.channels), (4, 3, 1));
    expect(jsonDecode(row.settingsJson), {
      'source': 'liveStack',
      'target': 'M31',
    });
    final recipe = await recipes.getById(promoted.recipeId!);
    expect(recipe!.name, 'Live Darkroom (L)');
    expect(recipe.masterId, promoted.masterId);
  });

  test(
    'the unfiltered stack has no filter and no recipe without steps',
    () async {
      final stack = LiveStackingState(
        status: LiveStackingStatus.running,
        filterStacks: {
          kDefaultLiveStackFilterKey: slot(kDefaultLiveStackFilterKey),
        },
      );

      final promoted = await promoter().promote(
        stack: stack,
        filterKey: kDefaultLiveStackFilterKey,
      );

      expect(promoted.recipeId, isNull);
      final row = (await masters.getAll()).single;
      expect(row.name, 'Live stack · (12 frames)');
      expect(row.filter, isNull);
      expect(
        row.masterFitsPath,
        startsWith('${temp.path}/skotiq_live_masters/live_stack_Unfiltered_'),
      );
    },
  );

  test('a stack with no frames is not promoted', () async {
    await expectLater(
      promoter().promote(stack: const LiveStackingState(), filterKey: 'L'),
      throwsStateError,
    );
    expect(saves, isEmpty);
    expect(await masters.getAll(), isEmpty);
  });

  test('a filter with no live stack is refused, not saved as the active '
      'slot under its name', () async {
    final stack = LiveStackingState(
      status: LiveStackingStatus.running,
      filterStacks: {'L': slot('L')},
      selectedFilterKey: 'L',
    );

    await expectLater(
      promoter().promote(stack: stack, filterKey: 'Ha'),
      throwsStateError,
    );
    expect(saves, isEmpty);
    expect(await masters.getAll(), isEmpty);
  });
}
