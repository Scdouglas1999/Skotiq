/// Value types for the catalog-powered annotation layer drawn over a finished
/// master — a labelled, kinded marker at a pixel position, grouped into a layer
/// that carries the master's dimensions.
///
/// Pure, immutable value types with `fromJson`/`toJson` round-trips and value
/// equality, matching `integration_settings.dart`. Decoded defensively
/// (nullable + defaults) so a partial or forward-migrated blob never throws.
library;

/// The catalog kind of an [Annotation] marker. The wire token is the stable
/// persisted string and the JSON key.
enum AnnotationKind {
  /// A catalogued star (named bright star).
  star,

  /// A galaxy.
  galaxy,

  /// An emission / reflection / planetary nebula.
  nebula,

  /// An open or globular cluster.
  cluster,

  /// Anything else (asterism, unclassified DSO, user marker).
  other;

  /// Stable wire token for persistence / JSON.
  String get wire {
    switch (this) {
      case AnnotationKind.star:
        return 'star';
      case AnnotationKind.galaxy:
        return 'galaxy';
      case AnnotationKind.nebula:
        return 'nebula';
      case AnnotationKind.cluster:
        return 'cluster';
      case AnnotationKind.other:
        return 'other';
    }
  }

  /// Inverse of [wire]. An unknown persisted value forward-migrates to [other]
  /// rather than throwing on read.
  static AnnotationKind fromWire(String value) {
    switch (value) {
      case 'star':
        return AnnotationKind.star;
      case 'galaxy':
        return AnnotationKind.galaxy;
      case 'nebula':
        return AnnotationKind.nebula;
      case 'cluster':
        return AnnotationKind.cluster;
      case 'other':
      default:
        return AnnotationKind.other;
    }
  }
}

/// One annotation marker: a [label] at pixel ([x], [y]) of the given [kind],
/// sized [sizePx] (the catalogued object's apparent diameter in master pixels),
/// with an optional position angle [paDeg] for an elongated object.
class Annotation {
  final String label;

  /// Marker centre X (master px).
  final double x;

  /// Marker centre Y (master px).
  final double y;

  final AnnotationKind kind;

  /// Apparent size in master pixels (diameter), for drawing the marker circle /
  /// ellipse.
  final double sizePx;

  /// Position angle in degrees (for an elongated object), or null when round /
  /// unknown.
  final double? paDeg;

  const Annotation({
    required this.label,
    required this.x,
    required this.y,
    required this.kind,
    required this.sizePx,
    this.paDeg,
  });

  factory Annotation.fromJson(Map<String, dynamic> json) {
    return Annotation(
      label: json['label'] is String ? json['label'] as String : '',
      x: _asDouble(json['x']),
      y: _asDouble(json['y']),
      kind: json['kind'] is String
          ? AnnotationKind.fromWire(json['kind'] as String)
          : AnnotationKind.other,
      sizePx: _asDouble(json['sizePx']),
      paDeg: _asNullableDouble(json['paDeg']),
    );
  }

  Map<String, dynamic> toJson() => {
    'label': label,
    'x': x,
    'y': y,
    'kind': kind.wire,
    'sizePx': sizePx,
    if (paDeg != null) 'paDeg': paDeg,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Annotation &&
          other.label == label &&
          other.x == x &&
          other.y == y &&
          other.kind == kind &&
          other.sizePx == sizePx &&
          other.paDeg == paDeg;

  @override
  int get hashCode => Object.hash(label, x, y, kind, sizePx, paDeg);
}

/// A layer of [items] annotations sized to a master of [width] × [height] px.
class AnnotationLayer {
  final int width;
  final int height;
  final List<Annotation> items;

  const AnnotationLayer({
    required this.width,
    required this.height,
    required this.items,
  });

  /// An empty layer. Used as the fail-soft fallback.
  static const AnnotationLayer empty = AnnotationLayer(
    width: 0,
    height: 0,
    items: [],
  );

  factory AnnotationLayer.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    final items = <Annotation>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          items.add(Annotation.fromJson(item));
        }
      }
    }
    return AnnotationLayer(
      width: _asInt(json['width']),
      height: _asInt(json['height']),
      items: items,
    );
  }

  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'items': items.map((a) => a.toJson()).toList(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnnotationLayer &&
          other.width == width &&
          other.height == height &&
          _listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(width, height, Object.hashAll(items));
}

double _asDouble(Object? v) => v is num ? v.toDouble() : 0.0;

double? _asNullableDouble(Object? v) => v is num ? v.toDouble() : null;

int _asInt(Object? v) => v is num ? v.toInt() : 0;

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
