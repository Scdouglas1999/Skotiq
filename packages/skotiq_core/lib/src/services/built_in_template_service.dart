import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/sequence/sequence_models.dart';
import 'sequence_file_service.dart';

/// The templates Skotiq ships in the Sequencer > Templates tab, read from
/// `assets/sample_sequences/templates/` through the sequence-file parser.
///
/// Each file is named after its template id without the `template-` prefix.
/// The files carry no dates: a template's age is fixed here, and it is dated
/// that many days before it is loaded, which orders the catalog.
class BuiltInTemplateService {
  const BuiltInTemplateService();

  static const String assetDirectory =
      'packages/skotiq_core/assets/sample_sequences/templates';

  /// The catalog in display order.
  static const List<({String id, int ageDays})> catalog = [
    (id: 'template-first-light', ageDays: 35),
    (id: 'template-osc', ageDays: 33),
    (id: 'template-quick-capture', ageDays: 31),
    (id: 'template-dso-beginner', ageDays: 29),
    (id: 'template-basic-lrgb', ageDays: 27),
    (id: 'template-narrowband', ageDays: 25),
    (id: 'template-mosaic-panel', ageDays: 23),
    (id: 'template-ha-oiii', ageDays: 19),
    (id: 'template-sho', ageDays: 17),
    (id: 'template-lrgb-ha', ageDays: 15),
    (id: 'template-multi-target', ageDays: 13),
    (id: 'template-planetary', ageDays: 11),
    (id: 'template-unattended', ageDays: 9),
    (id: 'template-comet', ageDays: 7),
    (id: 'template-solar', ageDays: 6),
    (id: 'template-lunar', ageDays: 5),
    (id: 'template-remote', ageDays: 4),
  ];

  /// The asset a catalog entry is read from.
  static String assetPathFor(String id) =>
      '$assetDirectory/${id.replaceFirst('template-', '')}.json';

  /// Every built-in template, dated against [now].
  Future<List<Sequence>> load({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final parser = SequenceFileService();
    return [
      for (final entry in catalog)
        templateFromMap(
          entry,
          jsonDecode(await rootBundle.loadString(assetPathFor(entry.id)))
              as Map<String, dynamic>,
          parser: parser,
          now: at,
        ),
    ];
  }

  /// [json] read as the template [entry] names.
  static Sequence templateFromMap(
    ({String id, int ageDays}) entry,
    Map<String, dynamic> json, {
    required SequenceFileService parser,
    required DateTime now,
  }) {
    final dated = now.subtract(Duration(days: entry.ageDays));
    return parser
        .parseFromMap(json)
        .copyWith(id: entry.id, createdAt: dated, modifiedAt: dated);
  }
}
