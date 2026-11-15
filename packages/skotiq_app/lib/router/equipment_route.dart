import 'query_word.dart';

/// The Equipment screen's page-header tabs, in display order.
enum EquipmentTab with QueryWord {
  devices('devices'),

  /// Also answers `optical-train`: the optics are a section of the profile
  /// editor this tab shows.
  profiles('profiles', olderWords: ['optical-train']);

  const EquipmentTab(this.word, {this.olderWords = const []});

  @override
  final String word;
  @override
  final List<String> olderWords;

  /// The tab a `?tab=` word names, or null.
  static EquipmentTab? fromQuery(String? word) => readQueryWord(values, word);
}
