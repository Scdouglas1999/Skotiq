/// Open in Darkroom for a live stack: the stack saved as a master in the
/// Darkroom library, with the operator's live Darkroom edit kept as a recipe.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/daos/recipes_dao.dart';
import '../models/darkroom/recipe.dart' show RecipeAuthor;
import '../models/imaging/live_stacking_models.dart';
import '../models/imaging/live_stacking_state.dart';
import 'live_stack_master_library.dart';

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
  final LiveStackMasterLibrary _library;
  final RecipesDao _recipes;
  final DateTime Function() _now;
  final String Function() _tempDir;

  LiveStackDarkroomPromoter({
    required LiveStackMasterLibrary library,
    required RecipesDao recipes,
    DateTime Function() now = DateTime.now,
    String Function()? tempDir,
  }) : _library = library,
       _recipes = recipes,
       _now = now,
       _tempDir = tempDir ?? (() => Directory.systemTemp.path);

  /// Persist the live stack for [filterKey] through the master library, as
  /// Save does (with its thumbnail), and, when [recipeSteps] is given and
  /// yields steps, a recipe holding the live edit. The master is named for
  /// [targetName] and the unfiltered stack is filed under no filter, so
  /// Darkroom groups it with the masters this saved before.
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
    final hasSlot = stack.filterStacks.containsKey(filterKey);
    // The active-slot saver has no filter argument: using it for a filter
    // with no slot would label whichever slot is active with [filterKey].
    if (!hasSlot &&
        (stack.filterStacks.isNotEmpty ||
            filterKey != kDefaultLiveStackFilterKey)) {
      throw StateError(
        'There is no $filterKey live stack to send to Darkroom.',
      );
    }
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
    final named = target != null && target.isNotEmpty ? target : null;
    final library = await _library.save(
      filePath,
      filterKey: hasSlot ? filterKey : null,
      label: (
        name: [
          named ?? 'Live stack',
          ?displayFilter,
          '($frames frames)',
        ].join(' · '),
        band: displayFilter,
        target: named,
      ),
    );
    final masterId = library.masterId;
    if (masterId == null) {
      throw StateError('The live stack was not saved as a FITS master.');
    }
    final saved = library.saved;

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
