/// Every registered image the Edit tab can open, grouped by target.
///
/// A registered image is an `integrated_masters` row with a file on disk: a
/// per-filter master or a color composite. The rows are joined to the recipes
/// written over them by the master's FITS path, which is what
/// `recipes.base_master_path` stores, and grouped under the target name the
/// guided build keys its jobs by.
library;

import 'dart:convert';

import 'package:flutter/widgets.dart' show TextStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart' show SkotiqTypography;

/// One registered image and the recipes written over it.
class DarkroomLibraryImage {
  final IntegratedMaster master;

  /// The target this image belongs to; see [darkroomMasterTargetName].
  final String target;

  /// Every recipe over this image, newest first.
  final List<DarkroomRecipe> recipes;

  const DarkroomLibraryImage({
    required this.master,
    required this.target,
    this.recipes = const [],
  });

  /// The short name of what this image holds: the filter for a per-filter
  /// master (`L`, `R`, `Ha`), `RGB` or `LRGB` for a composite, or `Color` for
  /// a color master that names no filter.
  String get kind => darkroomMasterKind(master);

  /// True for an image with three channels.
  bool get isColor => master.channels >= 3;

  /// The newest recipe over this image, or null when it has none.
  DarkroomRecipe? get newest => recipes.isEmpty ? null : recipes.first;
}

/// One target's registered images, composites first.
class DarkroomLibraryTarget {
  final String name;
  final List<DarkroomLibraryImage> images;

  const DarkroomLibraryTarget({required this.name, required this.images});

  /// The per-filter masters of this target that can feed a channel combine:
  /// single-channel images, newest per filter.
  List<DarkroomLibraryImage> get channelMasters {
    final byKind = <String, DarkroomLibraryImage>{};
    for (final image in images) {
      if (image.isColor) continue;
      final existing = byKind[image.kind];
      if (existing == null ||
          image.master.createdAt.isAfter(existing.master.createdAt)) {
        byKind[image.kind] = image;
      }
    }
    final list = byKind.values.toList()
      ..sort((a, b) => _kindRank(a.kind).compareTo(_kindRank(b.kind)));
    return list;
  }

  /// When the newest image of this target was registered.
  DateTime get latest => images
      .map((i) => i.master.createdAt)
      .reduce((a, b) => a.isAfter(b) ? a : b);
}

/// Display order of image kinds within a target.
int _kindRank(String kind) {
  const order = [
    'LRGB',
    'RGB',
    'Color',
    'L',
    'R',
    'G',
    'B',
    'Ha',
    'OIII',
    'SII'
  ];
  final index = order.indexWhere((k) => k.toLowerCase() == kind.toLowerCase());
  return index < 0 ? order.length : index;
}

/// The short name of what [master] holds.
String darkroomMasterKind(IntegratedMaster master) {
  final filter = master.filter?.trim();
  if (filter != null && filter.isNotEmpty) return filter;
  return master.channels >= 3 ? 'Color' : 'Mono';
}

/// The target [master] belongs to.
///
/// The target row's name when the master carries one; otherwise the `target`
/// the guided build recorded in the master's settings; otherwise the master's
/// own name with its filter suffix taken off. The guided build keys its jobs by
/// the same name, so an image lands under the target the Targets tab lists.
String darkroomMasterTargetName(
  IntegratedMaster master,
  Map<int, String> targetNames,
) {
  final byId = master.targetId == null ? null : targetNames[master.targetId];
  if (byId != null && byId.trim().isNotEmpty) return byId.trim();
  try {
    final settings = jsonDecode(master.settingsJson);
    if (settings is Map && settings['target'] is String) {
      final name = (settings['target'] as String).trim();
      if (name.isNotEmpty) return name;
    }
  } on FormatException {
    // Settings that are not JSON name no target; the master's name does.
  }
  var name = master.name.trim();
  final filter = master.filter?.trim();
  if (filter != null && filter.isNotEmpty) {
    for (final separator in const [' · ', ' - ', ' ']) {
      final suffix = '$separator$filter';
      if (name.toLowerCase().endsWith(suffix.toLowerCase())) {
        name = name.substring(0, name.length - suffix.length).trim();
        break;
      }
    }
  }
  return name.isEmpty ? 'Unnamed target' : name;
}

/// Group [images] by target, newest target first and composites first within
/// a target.
List<DarkroomLibraryTarget> groupDarkroomLibrary(
  List<DarkroomLibraryImage> images,
) {
  final byTarget = <String, List<DarkroomLibraryImage>>{};
  for (final image in images) {
    byTarget.putIfAbsent(image.target, () => []).add(image);
  }
  final targets = [
    for (final entry in byTarget.entries)
      DarkroomLibraryTarget(
        name: entry.key,
        images: entry.value
          ..sort((a, b) {
            final rank = _kindRank(a.kind).compareTo(_kindRank(b.kind));
            if (rank != 0) return rank;
            return b.master.createdAt.compareTo(a.master.createdAt);
          }),
      ),
  ]..sort((a, b) => b.latest.compareTo(a.latest));
  return targets;
}

/// Every registered image with a file, grouped by target.
final darkroomImageLibraryProvider =
    FutureProvider.autoDispose<List<DarkroomLibraryTarget>>((ref) async {
  final masters = await ref.watch(integratedMastersDaoProvider).getAll();
  final recipesDao = ref.watch(recipesDaoProvider);
  final targetNames = {
    for (final t in await ref.watch(targetsDaoProvider).getAllTargets())
      t.id: t.name,
  };
  final images = <DarkroomLibraryImage>[];
  for (final master in masters) {
    final path = master.masterFitsPath;
    // A master whose integration never wrote a file has nothing to open.
    if (path == null || path.isEmpty) continue;
    images.add(
      DarkroomLibraryImage(
        master: master,
        target: darkroomMasterTargetName(master, targetNames),
        recipes: await recipesDao.listForMaster(path),
      ),
    );
  }
  return groupDarkroomLibrary(images);
});

/// The Darkroom's overline: Spline Sans Mono caps with open tracking, the
/// style the approved Darkroom design uses above names and for list headers.
final TextStyle kDarkroomOverline = SkotiqTypography.monoXs.copyWith(
  letterSpacing: 1.1,
);
