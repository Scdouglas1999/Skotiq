import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_app/screens/darkroom/darkroom_previews.dart';
import 'package:skotiq_app/screens/darkroom/targets/darkroom_targets_model.dart';
import 'package:skotiq_app/screens/darkroom/targets/darkroom_targets_providers.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'targets/owner_nights_fixture.dart';

IntegratedMaster _master(int id, String filter, {int channels = 1}) =>
    IntegratedMaster(
      id: id,
      targetId: 1,
      name: 'NGC 891 $filter',
      masterFitsPath: '/m/$filter.fits',
      previewPngPath: '/m/$filter.png',
      sidecarPath: null,
      rejectionMapPath: null,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.runningWeightedMean,
      channels: channels,
      width: 4656,
      height: 3520,
      frameCount: 20,
      totalIntegrationSeconds: 1800,
      filter: filter,
      settingsJson: '{}',
      statsJson: '{}',
      createdAt: DateTime(2026, 10, 24),
      updatedAt: DateTime(2026, 10, 24),
    );

DarkroomRecipe _recipe(int id, String base, DateTime updated) => DarkroomRecipe(
      id: id,
      baseMasterPath: base,
      name: 'r$id',
      stepsJson: '[]',
      createdBy: RecipeAuthor.user,
      schemaVersion: 1,
      createdAt: updated,
      updatedAt: updated,
    );

DarkroomTarget _target(
        List<IntegratedMaster> masters, Map<int, String> drafts) =>
    DarkroomTarget(
      key: 'NGC 891',
      frames: const [],
      nights: const [],
      masters: masters,
      channels: [
        for (final m in masters)
          if (m.channels == 1)
            DarkroomChannel(
              filter: m.filter!,
              keptSubs: 20,
              keptSeconds: 1800,
              master: m,
            ),
      ],
      draftPreviews: drafts,
    );

void main() {
  test('a recipe draft is kept beside its master, one file per recipe', () {
    expect(
      darkroomRecipePreviewPath('/data/Masters/NGC_891/L.fits', 7),
      '/data/Masters/NGC_891/previews/recipe-7.jpg',
    );
  });

  test('the newest recipe whose draft is on disk is the one shown', () {
    final recipes = [
      _recipe(1, '/m/L.fits', DateTime(2026, 10, 20)),
      _recipe(2, '/m/L.fits', DateTime(2026, 10, 24)),
      _recipe(3, '/m/L.fits', DateTime(2026, 10, 22)),
    ];
    final onDisk = {'/m/previews/recipe-1.jpg', '/m/previews/recipe-3.jpg'};
    expect(
      darkroomRecipeDraftPreview(recipes, exists: onDisk.contains),
      '/m/previews/recipe-3.jpg',
    );
    expect(darkroomRecipeDraftPreview(recipes, exists: (_) => false), isNull);
  });

  group('the hero picture', () {
    final l = _master(1, 'L');
    final r = _master(2, 'R');
    final lrgb = _master(3, 'LRGB', channels: 3);

    test('is a rendered draft first', () {
      expect(
        _target([lrgb, l, r], {1: '/m/previews/recipe-9.jpg'}).heroImagePath,
        '/m/previews/recipe-9.jpg',
      );
    });

    test('then the auto-stretched composite', () {
      expect(_target([lrgb, l, r], const {}).heroImagePath, '/m/LRGB.png');
    });

    test('then the auto-stretched luminance master', () {
      expect(_target([r, l], const {}).heroImagePath, '/m/L.png');
    });
  });

  test('a rendered frame is saved as a scaled JPEG thumbnail', () async {
    final dir = await Directory.systemTemp.createTemp('darkroom-previews');
    addTearDown(() => dir.delete(recursive: true));
    const width = 2000, height = 1000;
    final rgba = Uint8List(width * height * 4);
    for (var i = 0; i < width * height; i++) {
      rgba[i * 4] = 90;
      rgba[i * 4 + 1] = 70;
      rgba[i * 4 + 2] = 60;
      rgba[i * 4 + 3] = 255;
    }
    final path = '${dir.path}/previews/recipe-4.jpg';
    await saveDarkroomRecipePreview(
      path: path,
      width: width,
      height: height,
      rgba: rgba,
    );
    final saved = img.decodeJpg(File(path).readAsBytesSync())!;
    expect(saved.width, kDarkroomDraftPreviewWidth);
    expect(saved.height, 480);
    expect(saved.getPixel(10, 10).r, closeTo(90, 3));
  });

  test('only a stretched or screen-lifted render is kept as a picture', () {
    expect(darkroomRenderIsDisplayable('screen', 'linear'), isTrue);
    expect(darkroomRenderIsDisplayable('unit', 'stretched'), isTrue);
    expect(darkroomRenderIsDisplayable('unit', 'linear'), isFalse);
  });

  test('a saved draft becomes the target\'s hero once the lists read again',
      () async {
    final owner = await seedOwnerNights();
    addTearDown(owner.db.close);
    final dir = await Directory.systemTemp.createTemp('darkroom-hero');
    addTearDown(() => dir.delete(recursive: true));
    final colorId = owner.masters['RGB']!;
    final masterPath = '${dir.path}/LRGB_linear.fits';
    await owner.db.customUpdate(
      'UPDATE integrated_masters SET master_fits_path = ? WHERE id = ?',
      variables: [Variable<String>(masterPath), Variable<int>(colorId)],
    );
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(owner.db)],
    );
    addTearDown(container.dispose);
    final sub = container.listen(darkroomTargetsProvider, (_, __) {});
    addTearDown(sub.close);

    DarkroomTarget target(List<DarkroomTarget> all) =>
        all.singleWhere((t) => t.key == 'NGC 891');
    final before = target(await container.read(darkroomTargetsProvider.future));
    expect(before.heroImagePath, '/masters/NGC0891_LRGB.jpg');

    final recipe = await RecipesDao(owner.db).create(
      masterId: colorId,
      baseMasterPath: masterPath,
      createdBy: RecipeAuthor.user,
    );
    final draft = darkroomRecipePreviewPath(masterPath, recipe);
    await File(draft).create(recursive: true);
    container.read(darkroomDraftPreviewRevisionProvider.notifier).state++;

    final after = target(await container.read(darkroomTargetsProvider.future));
    expect(after.heroImagePath, draft);
  });
}
