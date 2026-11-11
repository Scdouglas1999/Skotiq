/// The `{items, total}` envelope of the host's paginated reads.
library;

import '../json_fields.dart';

/// One page of rows; [total] counts every row that matches the filter, not
/// only the ones on this page.
class RemotePage<T> {
  const RemotePage({required this.items, required this.total});

  factory RemotePage.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) itemFromJson,
  ) {
    final rawItems = json['items'];
    if (rawItems is! List) {
      throw const FormatException(
        'Malformed paginated response: missing items list',
      );
    }
    final items = <T>[];
    for (var index = 0; index < rawItems.length; index++) {
      final raw = rawItems[index];
      if (raw is! Map) {
        throw FormatException('Paginated response row $index is not an object');
      }
      try {
        items.add(itemFromJson(raw.cast<String, dynamic>()));
      } on TypeError catch (error) {
        throw FormatException(
          'Paginated response row $index is malformed: $error',
          error,
        );
      }
    }
    final total = requiredInt(json, 'total', 'paginated response', min: 0);
    if (total < items.length) {
      throw FormatException(
        'Paginated response total $total is smaller than its ${items.length} rows',
      );
    }
    return RemotePage(items: List.unmodifiable(items), total: total);
  }

  final List<T> items;
  final int total;

  Map<String, dynamic> toJson(Map<String, dynamic> Function(T) itemToJson) => {
    'items': items.map(itemToJson).toList(),
    'total': total,
  };
}
