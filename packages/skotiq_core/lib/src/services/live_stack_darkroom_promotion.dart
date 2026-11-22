/// Open in Darkroom for a live stack: the stack saved as a master in the
/// Darkroom library, with the operator's live Darkroom edit kept as a recipe.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/daos/integrated_masters_dao.dart';
import '../database/daos/recipes_dao.dart';
import '../models/darkroom/recipe.dart' show RecipeAuthor;
import '../models/imaging/integrated_master.dart';
import '../models/imaging/live_stacking_models.dart';
import '../models/imaging/live_stacking_state.dart';

/// The library rows Open in Darkroom created, which the editor opens.
class LiveStackDarkroomPromotion {
  final int masterId;
  final int? recipeId;
  final String masterFitsPath;

  const LiveStackDarkroomPromotion({
    required this.masterId,
    required this.masterFitsPath,
    this.recipeId,
  });
}

/// The live Darkroom edit as recipe steps, for a mono or color master.
typedef LiveRecipeSteps =
    List<Map<String, dynamic>> Function({required bool isColor});

/// Saves a live stack as a Darkroom master and registers it.
class LiveStackDarkroomPromoter {
  final Future<LiveStackingMasterSave> Function(String filePath) _saveMaster;
  final Future<LiveStackingMasterSave> Function(
    String filterKey,
    String filePath,
  )
  _saveMasterForFilter;
  final IntegratedMastersDao _masters;
  final RecipesDao _recipes;
  final DateTime Function() _now;
  final String Function() _tempDir;

  LiveStackDarkroomPromoter({
    required Future<LiveStackingMasterSave> Function(String filePath)
    saveMaster,
    required Future<LiveStackingMasterSave> Function(
      String filterKey,
      String filePath,
    )
    saveMasterForFilter,
    required IntegratedMastersDao masters,
    required RecipesDao recipes,
    DateTime Function() now = DateTime.now,
    String Function()? tempDir,
  }) : _saveMaster = saveMaster,
       _saveMasterForFilter = saveMasterForFilter,
       _masters = masters,
       _recipes = recipes,
       _now = now,
       _tempDir = tempDir ?? (() => Directory.systemTemp.path);

  /// Persist the live stack for [filterKey] as a linear FITS master in the
  /// Darkroom library and, when [recipeSteps] is given and yields steps, a
  /// recipe holding the live edit.
  ///
  /// The master is written in a `masters` folder beside the stack's
  /// reference frame, or in the system temp folder when the stack has none.
  Future<LiveStackDarkroomPromotion> promote({
    required LiveStackingState stack,
    required String filterKey,
    String? targetName,
    int? sessionId,
    LiveRecipeSteps? recipeSteps,
  }) async {
    final snap = stack.filterStacks[filterKey] ?? stack.activeFilterStack;
    final frames =
        snap?.stats.stackedFrameCount ?? stack.stats.stackedFrameCount;
    if (frames <= 0) {
      throw StateError('No stacked frames available to send to Darkroom.');
    }

    final target = targetName?.trim();
    final safeTarget = (target != null && target.isNotEmpty)
        ? target.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        : 'live_stack';
    final safeFilter = filterKey.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    final stamp = _now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;

    final refPath = snap?.referenceImagePath ?? stack.referenceImagePath;
    final String mastersDir;
    if (refPath != null && refPath.trim().isNotEmpty) {
      mastersDir = p.join(p.dirname(refPath), 'masters');
    } else {
      mastersDir = p.join(_tempDir(), 'skotiq_live_masters');
    }
    await Directory(mastersDir).create(recursive: true);

    final filePath = p.join(
      mastersDir,
      '${safeTarget}_${safeFilter}_${stamp}Z_${frames}f.fits',
    );

    final saved = stack.filterStacks.containsKey(filterKey)
        ? await _saveMasterForFilter(filterKey, filePath)
        : await _saveMaster(filePath);

    final width = snap?.previewWidth ?? stack.previewWidth;
    final height = snap?.previewHeight ?? stack.previewHeight;
    final channels =
        snap?.channels ??
        ((stack.previewData != null &&
                width * height > 0 &&
                stack.previewData!.length >= width * height * 3)
            ? 3
            : 1);

    final displayFilter = filterKey == kDefaultLiveStackFilterKey
        ? null
        : filterKey;
    final masterDisplayName = [
      if (target != null && target.isNotEmpty) target else 'Live stack',
      ?displayFilter,
      '($frames frames)',
    ].join(' · ');

    final masterId = await _masters.insertMaster(
      name: masterDisplayName,
      masterFitsPath: saved.filePath,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.runningWeightedMean,
      channels: channels,
      width: width,
      height: height,
      frameCount: saved.stackedFrameCount,
      totalIntegrationSeconds: saved.totalIntegrationSecs ?? 0.0,
      filter: displayFilter,
      settingsJson: jsonEncode(<String, dynamic>{
        'source': 'liveStack',
        if (target != null && target.isNotEmpty) 'target': target,
      }),
    );

    int? recipeId;
    final steps = recipeSteps?.call(isColor: channels >= 3);
    if (steps != null && steps.isNotEmpty) {
      recipeId = await _recipes.create(
        masterId: masterId,
        sessionId: sessionId,
        baseMasterPath: saved.filePath,
        name:
            'Live Darkroom${displayFilter != null ? ' ($displayFilter)' : ''}',
        stepsJson: jsonEncode(steps),
        createdBy: RecipeAuthor.user,
      );
    }

    return LiveStackDarkroomPromotion(
      masterId: masterId,
      recipeId: recipeId,
      masterFitsPath: saved.filePath,
    );
  }
}
