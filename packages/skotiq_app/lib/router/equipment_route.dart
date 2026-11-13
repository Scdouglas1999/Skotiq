import 'query_word.dart';

/// The Equipment screen's page-header tabs, in display order.
enum EquipmentTab with QueryWord {
  devices('devices'),
  profiles('profiles'),
  opticalTrain('optical-train');

  const EquipmentTab(this.word);

  @override
  final String word;
  @override
  List<String> get olderWords => const [];

  /// The tab a `?tab=` word names, or null.
  static EquipmentTab? fromQuery(String? word) => readQueryWord(values, word);
}
