part of '../sequence_models.dart';

/// Where a node is stored. Both stores use the same field keys; they differ
/// only in how a few values are spelled (see [FieldCodec]).
enum NodeStore {
  /// The `sequence_nodes.properties` blob of a saved sequence.
  database,

  /// A node map inside a sequence document: exported files, version
  /// snapshots, backups, remote sequence sync, smart-night plans, snippets.
  document,
}

/// What one node type is: its names, how it looks and behaves in the tree,
/// what it captures, and the field table both stores and the version diff
/// are built from.
///
/// One instance per [SequenceNode] subtype, listed in [NodeKind.all]. The
/// stored type name is [wireName]; the native sequencer's serde tags are a
/// separate vocabulary owned by the executor serializer.
final class NodeKind<N extends SequenceNode> {
  NodeKind({
    required this.wireName,
    required this.icon,
    required this.category,
    required N Function() create,
    required this.fields,
    required N Function(FieldValues<N> values) build,
    required String Function(N node) describe,
    this.diff = const [],
    List<CaptureRun> Function(N node)? captures,
    this.legacyNames = const [],
    this.isContainer = false,
    this.requiredDevices = const {},
    this.stage = NodeStage.free,
    String Function(N node)? autoName,
    List<String?> Function(N node)? filters,
    N Function(N node, String Function(String filter) rename)? renameFilter,
  }) : _autoName = autoName,
       _filters = filters,
       _renameFilter = renameFilter,
       _create = create,
       _build = build,
       _describe = describe,
       _captures = captures;

  /// The type name stored in `sequence_nodes.specific_type` and a document's
  /// `nodeType`, and returned by [SequenceNode.nodeType].
  final String wireName;

  /// Other spellings older builds stored. The database reader matches them
  /// exactly; the document reader matches them ignoring case and separators.
  final List<String> legacyNames;

  /// Icon vocabulary name (see [SequenceNode.iconName]).
  final String icon;

  final NodeCategory category;

  /// Whether the tree lets this type hold children, even while it has none.
  final bool isContainer;

  final Set<DeviceType> requiredDevices;

  /// Where a step of this type belongs among a target's steps.
  final NodeStage stage;

  /// Every value-carrying field of the type, in stored order.
  final List<NodeField<N, Object?>> fields;

  /// What the version diff reports for this type, in display order.
  final List<NodeDiffLine<N>> diff;

  final N Function() _create;
  final N Function(FieldValues<N> values) _build;
  final String Function(N node) _describe;
  final List<CaptureRun> Function(N node)? _captures;
  final String Function(N node)? _autoName;
  final List<String?> Function(N node)? _filters;
  final N Function(N node, String Function(String filter) rename)?
  _renameFilter;

  /// A node of this type with every field at its default.
  N create() => _create();

  /// The frames [node] takes each time it runs, by filter; empty for a step
  /// that captures nothing or whose frame count the run decides.
  List<CaptureRun> captures(N node) => _captures?.call(node) ?? const [];

  /// The node's one-line label in the version diff.
  String describe(N node) => _describe(node);

  late final N _defaults = _create();

  /// The name a new node of this type gets.
  String get displayName => _defaults.name;

  /// [next]'s name after an edit from [before]. A name that only said what
  /// the step is set to (the type's default name, or the name its settings
  /// give it) follows the new settings; a name the operator chose stays.
  String nameAfterEdit(N before, N next) {
    final autoName = _autoName;
    if (autoName == null || next.name != before.name) return next.name;
    if (before.name != displayName && before.name != autoName(before)) {
      return next.name;
    }
    final followed = autoName(next).trim();
    return followed.isEmpty ? displayName : followed;
  }

  /// The wheel filters [node] names, by name.
  List<String> filtersOf(N node) => [
    for (final filter in _filters?.call(node) ?? const <String?>[])
      if (filter != null && filter.trim().isNotEmpty) filter,
  ];

  /// [node] with every filter it names replaced as [renames] says. Its name
  /// follows when it only said its filter (see [nameAfterEdit]).
  N renameFilters(N node, Map<String, String> renames) {
    final rename = _renameFilter;
    if (rename == null || !filtersOf(node).any(renames.containsKey)) {
      return node;
    }
    final renamed = rename(node, (filter) => renames[filter] ?? filter);
    return renamed.copyWith(name: nameAfterEdit(node, renamed)) as N;
  }

  /// What changed between two nodes of this type, as the version diff shows
  /// it: label, text before, text after.
  List<(String, String, String)> changes(N before, N after) => [
    for (final line in diff)
      if (line.changed(before, after))
        (line.label, line.text(before), line.text(after)),
  ];

  /// The type-specific fields of [node] as [store] writes them.
  Map<String, Object?> encodeFields(N node, NodeStore store) => {
    for (final field in fields)
      if (!(field.omitWhenNull && field.read(node) == null))
        field.key: field.encode(node, store),
  };

  /// A node of this type from the fields in [stored], with every base field
  /// (id, name, tree position, comment) at its default.
  N decodeFields(Map<String, dynamic> stored, NodeStore store) =>
      _build(FieldValues._(this, stored, store));

  static final Map<String, NodeKind> _byStoredName = {
    for (final kind in all)
      for (final name in [kind.wireName, ...kind.legacyNames]) name: kind,
  };

  static final Map<String, NodeKind> _byLooseName = {
    for (final MapEntry(:key, :value) in _byStoredName.entries)
      normalizeNodeTypeName(key): value,
  };

  /// The type stored as [name] in the database, or null.
  static NodeKind? forDatabaseName(String name) => _byStoredName[name];

  /// The type a document names [name], ignoring case and separators, or null.
  static NodeKind? forDocumentName(String name) =>
      _byLooseName[normalizeNodeTypeName(name)];

  static List<NodeKind> get all => nodeKinds;
}

/// Where a step belongs in a target's run: what a newly added step is placed
/// before, and what the order check holds the plan to.
enum NodeStage {
  /// Puts the telescope on the target. Frames taken before it are of
  /// whatever sky the mount was left on.
  aim,

  /// Readies the camera, focus or guider for the frames.
  prepare,

  /// Takes the frames.
  capture,

  /// Goes wherever the operator puts it.
  free;

  /// Whether a new step of this stage goes ahead of the frames it serves.
  bool get precedesCapture => this == aim || this == prepare;
}

/// Frames one capture step takes per run through a filter.
typedef CaptureRun = ({String? filter, int count, double exposureSecs});

/// [name] lower-cased with everything but letters and digits removed.
String normalizeNodeTypeName(String name) =>
    name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();

/// One stored field of a node type.
final class NodeField<N extends SequenceNode, T> {
  NodeField(
    this.key,
    this.read,
    this.codec, {
    this.alternateKeys = const [],
    this.absentIn = const {},
    this.requiredIn = const {},
    this.omitWhenNull = false,
  });

  final String key;
  final T Function(N node) read;
  final FieldCodec<T> codec;

  /// Older spellings of [key] the readers also accept, tried in order.
  final List<String> alternateKeys;

  /// The value a store reads when the key is absent or unreadable, where it
  /// is not the type's default (a nullable field reads null).
  final Map<NodeStore, T> absentIn;

  /// Stores where a missing value makes the whole node unreadable.
  final Set<NodeStore> requiredIn;

  /// Leave the key out instead of writing null.
  final bool omitWhenNull;

  Object? encode(N node, NodeStore store) => codec.encode(read(node), store);

  T _decode(
    NodeKind<N> kind,
    Map<String, dynamic> stored,
    NodeStore store,
  ) {
    Object? raw = stored[key];
    for (final alternate in alternateKeys) {
      raw ??= stored[alternate];
    }
    final decoded = raw == null ? null : codec.decode(raw, store);
    if (decoded != null) return decoded;
    if (requiredIn.contains(store)) {
      throw FormatException(
        '${kind.displayName} node missing required fields',
      );
    }
    if (absentIn.containsKey(store)) return absentIn[store] as T;
    if (null is T) return null as T;
    return read(kind._defaults);
  }
}

/// The decoded fields handed to a [NodeKind]'s builder.
final class FieldValues<N extends SequenceNode> {
  FieldValues._(this._kind, this._stored, this._store);

  final NodeKind<N> _kind;
  final Map<String, dynamic> _stored;
  final NodeStore _store;

  T call<T>(NodeField<N, T> field) => field._decode(_kind, _stored, _store);
}

/// How one field's value is written and read back.
///
/// Decoding returns null for an absent or unrecognised value; the field then
/// falls back to its absent value.
abstract class FieldCodec<T> {
  const FieldCodec();

  Object? encode(T value, NodeStore store);
  T? decode(Object raw, NodeStore store);

  static const FieldCodec<double> real = _Real();
  static const FieldCodec<double?> optionalReal = _Real();
  static const FieldCodec<int> integer = _Integer();
  static const FieldCodec<int?> optionalInteger = _Integer();
  static const FieldCodec<bool> flag = _Flag();
  static const FieldCodec<String> text = _Text();
  static const FieldCodec<String?> optionalText = _Text();
  static const FieldCodec<List<String>> texts = _Texts();
  static const FieldCodec<DateTime?> instant = _Instant();
  static const FieldCodec<List<Map<String, dynamic>>> objects = _Objects();

  static FieldCodec<E> named<E extends Enum>(List<E> values) =>
      _Named<E>(values);

  static FieldCodec<E?> optionalNamed<E extends Enum>(List<E> values) =>
      _Named<E>(values);

  static FieldCodec<T> json<T>(
    Map<String, dynamic> Function(T value) toJson,
    T Function(Map<String, dynamic> json) fromJson,
  ) => _Json<T>(toJson, fromJson);

  static FieldCodec<T> custom<T>({
    required Object? Function(T value, NodeStore store) encode,
    required T? Function(Object raw, NodeStore store) decode,
  }) => _Custom<T>(encode, decode);
}

final class _Real<T extends double?> extends FieldCodec<T> {
  const _Real();
  @override
  Object? encode(T value, NodeStore store) => value;
  @override
  T? decode(Object raw, NodeStore store) => (raw as num).toDouble() as T;
}

final class _Integer<T extends int?> extends FieldCodec<T> {
  const _Integer();
  @override
  Object? encode(T value, NodeStore store) => value;
  @override
  T? decode(Object raw, NodeStore store) => (raw as num).toInt() as T;
}

final class _Flag extends FieldCodec<bool> {
  const _Flag();
  @override
  Object? encode(bool value, NodeStore store) => value;
  @override
  bool? decode(Object raw, NodeStore store) => raw as bool;
}

final class _Text<T extends String?> extends FieldCodec<T> {
  const _Text();
  @override
  Object? encode(T value, NodeStore store) => value;
  @override
  T? decode(Object raw, NodeStore store) => raw as T;
}

final class _Texts extends FieldCodec<List<String>> {
  const _Texts();
  @override
  Object? encode(List<String> value, NodeStore store) => value;
  @override
  List<String>? decode(Object raw, NodeStore store) =>
      (raw as List).map((e) => e.toString()).toList(growable: false);
}

/// The database stores milliseconds since the epoch; documents store ISO 8601.
/// Either reads both.
final class _Instant extends FieldCodec<DateTime?> {
  const _Instant();
  @override
  Object? encode(DateTime? value, NodeStore store) => switch (store) {
    NodeStore.database => value?.millisecondsSinceEpoch,
    NodeStore.document => value?.toIso8601String(),
  };
  @override
  DateTime? decode(Object raw, NodeStore store) => switch (raw) {
    int() => DateTime.fromMillisecondsSinceEpoch(raw),
    String() => DateTime.parse(raw),
    _ => null,
  };
}

final class _Objects extends FieldCodec<List<Map<String, dynamic>>> {
  const _Objects();
  @override
  Object? encode(List<Map<String, dynamic>> value, NodeStore store) => value;
  @override
  List<Map<String, dynamic>>? decode(Object raw, NodeStore store) =>
      (raw as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false);
}

final class _Named<E extends Enum> extends FieldCodec<E> {
  const _Named(this.values);
  final List<E> values;
  @override
  Object? encode(E? value, NodeStore store) => value?.name;
  @override
  E? decode(Object raw, NodeStore store) => enumFromWire(values, raw);
}

final class _Json<T> extends FieldCodec<T> {
  const _Json(this.toJson, this.fromJson);
  final Map<String, dynamic> Function(T value) toJson;
  final T Function(Map<String, dynamic> json) fromJson;
  @override
  Object? encode(T value, NodeStore store) =>
      value == null ? null : toJson(value);
  @override
  T? decode(Object raw, NodeStore store) =>
      raw is Map ? fromJson(raw.cast<String, dynamic>()) : null;
}

final class _Custom<T> extends FieldCodec<T> {
  const _Custom(this._encode, this._decode);
  final Object? Function(T value, NodeStore store) _encode;
  final T? Function(Object raw, NodeStore store) _decode;
  @override
  Object? encode(T value, NodeStore store) => _encode(value, store);
  @override
  T? decode(Object raw, NodeStore store) => _decode(raw, store);
}

/// One line of the version diff for a node type.
final class NodeDiffLine<N extends SequenceNode> {
  /// A field, compared by value and shown with [show] (default `toString`).
  static NodeDiffLine<N> of<N extends SequenceNode, T>(
    NodeField<N, T> field,
    String label, [
    String Function(T value)? show,
  ]) => NodeDiffLine._(
    label,
    (n) => show == null ? '${field.read(n)}' : show(field.read(n)),
    (n) => field.read(n),
  );

  /// A summary of the node (a count, a flag), compared by its text.
  NodeDiffLine.summary(this.label, this.text) : _value = null;

  NodeDiffLine._(this.label, this.text, this._value);

  final String label;
  final String Function(N node) text;
  final Object? Function(N node)? _value;

  bool changed(N before, N after) {
    final value = _value;
    return value == null
        ? text(before) != text(after)
        : value(before) != value(after);
  }
}
