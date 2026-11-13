// Generates the event wire codec from the flutter_rust_bridge event unions.
//
// Run from the repository root after FRB codegen:
//   dart run packages/skotiq_bridge/tool/generate_event_wire.dart
//
// Reads `lib/src/event/*.dart` and writes
// `lib/src/event_wire/event_wire.g.dart` (the codec),
// `test/event_wire_samples.g.dart` (one full and one sparse value of every
// variant, for the round-trip test) and the web pages' table of event types,
// `apps/desktop/web_run_watch/js/wire-events.js`. `--check` writes nothing and
// exits 1 when any of them is out of date.
//
// A variant is encoded as its name and its fields under snake_case keys.
// Everything that differs from that rule is listed in `event_wire_spec.dart`.

import 'dart:io';

import 'event_wire_spec.dart';

const _unionFiles = [
  'bus',
  'depthlock_events',
  'equipment',
  'guiding',
  'imaging',
  'sequencer',
  'system',
];

class Field {
  Field(this.type, this.name);
  final String type;
  final String name;

  bool get nullable => type.endsWith('?');
  String get base => nullable ? type.substring(0, type.length - 1) : type;
}

class Variant {
  Variant(this.union, this.factory, this.className, this.fields, this.named);
  final String union;
  final String factory;
  final String className;
  final List<Field> fields;
  final bool named;

  String get pascal => className.substring(union.length + 1);
}

class Model {
  final Map<String, List<Variant>> unions = {};
  final Map<String, List<Field>> classes = {};
  final Map<String, List<String>> enums = {};
}

String snake(String name) => name
    .replaceAllMapped(RegExp(r'(?<!^)([A-Z])'), (m) => '_${m[1]}')
    .toLowerCase();

String _stripComments(String source) =>
    source.replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');

List<String> _splitTopLevel(String text) {
  final parts = <String>[];
  var depth = 0;
  final current = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    if (char == '<' || char == '(') depth++;
    if (char == '>' || char == ')') depth--;
    if (char == ',' && depth == 0) {
      parts.add(current.toString());
      current.clear();
    } else {
      current.write(char);
    }
  }
  parts.add(current.toString());
  return [
    for (final part in parts)
      if (part.trim().isNotEmpty) part.trim(),
  ];
}

Field _field(String declaration) {
  final text = declaration
      .replaceFirst(RegExp(r'^required\s+'), '')
      .replaceFirst(RegExp(r'^final\s+'), '')
      .trim();
  final split = text.lastIndexOf(RegExp(r'\s'));
  if (split < 0) throw FormatException('Unreadable field "$declaration"');
  return Field(
    text.substring(0, split).replaceAll(RegExp(r'\s+'), ' ').trim(),
    text.substring(split + 1).trim(),
  );
}

/// Files outside `event/` that declare enums the events carry.
const _enumFiles = ['../device'];

Model readModel(Directory eventDir) {
  final model = Model();
  for (final name in [..._unionFiles, ..._enumFiles]) {
    final source = _stripComments(
      File('${eventDir.path}/$name.dart').readAsStringSync(),
    );
    if (_enumFiles.contains(name)) {
      for (final match in RegExp(
        r'^enum (\w+) \{(.*?)\}',
        dotAll: true,
        multiLine: true,
      ).allMatches(source)) {
        model.enums[match[1]!] = [
          for (final value in match[2]!.split(RegExp(r'[,;]')))
            if (value.trim().isNotEmpty) value.trim(),
        ];
      }
      continue;
    }
    for (final match in RegExp(
      r'const factory (\w+)\.(\w+)\(([^;]*?)\)\s*=\s*(\w+);',
      dotAll: true,
    ).allMatches(source)) {
      var params = match[3]!.trim();
      final named = params.startsWith('{');
      if (named) params = params.substring(1, params.lastIndexOf('}'));
      model.unions
          .putIfAbsent(match[1]!, () => [])
          .add(
            Variant(match[1]!, match[2]!, match[4]!, [
              for (final part in _splitTopLevel(params)) _field(part),
            ], named),
          );
    }
    for (final match in RegExp(
      r'^enum (\w+) \{(.*?)\}',
      dotAll: true,
      multiLine: true,
    ).allMatches(source)) {
      model.enums[match[1]!] = [
        for (final value in match[2]!.split(RegExp(r'[,;]')))
          if (value.trim().isNotEmpty) value.trim(),
      ];
    }
    for (final match in RegExp(
      r'^class (\w+) \{(.*?)^\}',
      dotAll: true,
      multiLine: true,
    ).allMatches(source)) {
      model.classes[match[1]!] = [
        for (final field in RegExp(
          r'^\s*final ([^;=(]+?) (\w+);',
          multiLine: true,
        ).allMatches(match[2]!))
          Field(field[1]!.trim(), field[2]!),
      ];
    }
  }
  return model;
}

/// The unions an event of each wire family can be, in decode order.
const _families = <String, List<String>>{
  'equipment': ['EquipmentEvent'],
  'imaging': ['DepthLockEvent', 'ImagingEvent'],
  'guiding': ['GuidingEvent'],
  'sequencer': ['SequencerEvent'],
  'safety': ['SafetyEvent'],
  'system': ['SystemEvent'],
};

/// The `EventPayload` factory that wraps each union.
const _payloadFactory = <String, String>{
  'EquipmentEvent': 'equipment',
  'ImagingEvent': 'imaging',
  'GuidingEvent': 'guiding',
  'SequencerEvent': 'sequencer',
  'SafetyEvent': 'safety',
  'SystemEvent': 'system',
  'DepthLockEvent': 'depthLock',
};

/// The plain classes `EventPayload` carries under the polar alignment family,
/// with the event type each is sent as.
const _polarClasses = <String, String>{
  'PolarAlignmentEvent': 'PolarAlignment',
  'PolarAlignmentStatus': 'PolarAlignmentStatus',
  'PolarAlignmentImageEvent': 'PolarAlignmentImage',
};

class Generator {
  Generator(this.model);
  final Model model;
  final StringBuffer out = StringBuffer();

  /// The enums an event field carries; only these get a codec.
  final Set<String> usedEnums = {};

  String wireType(Variant v) =>
      variantSpecs[v.className]?.type ??
      '${unionTypePrefix[v.union] ?? ''}${v.pascal}';

  String key(String owner, Field f) =>
      variantSpecs[owner]?.keys[f.name] ?? snake(f.name);

  String encodeValue(String owner, Field f, String access) {
    final base = f.base;
    final q = f.nullable ? '?' : '';
    if (base == 'BigInt') return '$access$q.toInt()';
    if (model.enums.containsKey(base)) {
      usedEnums.add(base);
      return f.nullable
          ? '$access == null ? null : encode$base($access!)'
          : 'encode$base($access)';
    }
    if (model.classes.containsKey(base)) {
      return f.nullable
          ? '$access == null ? null : encode$base($access!)'
          : 'encode$base($access)';
    }
    final list = RegExp(r'^List<(\w+)>$').firstMatch(base);
    if (list != null && model.classes.containsKey(list[1])) {
      return '$access$q.map(encode${list[1]}).toList()';
    }
    return access;
  }

  String decodeValue(String owner, Field f, String map) {
    final k = "'${key(owner, f)}'";
    final base = f.base;
    final fallback = variantSpecs[owner]?.defaults[f.name];
    if (fallback != null) {
      final optional = decodeValue(
        '',
        Field('$base?', f.name),
        map,
      ).replaceFirst("'${snake(f.name)}'", k);
      return '$optional ?? $fallback';
    }
    if (variantSpecs[owner]?.required.contains(f.name) ?? false) {
      final optional = decodeValue(
        '',
        Field('$base?', f.name),
        map,
      ).replaceFirst("'${snake(f.name)}'", k);
      return 'wireRequired($optional, $k)';
    }
    final opt = f.nullable;
    switch (base) {
      case 'String':
        return opt ? 'wireOptString($map, $k)' : 'wireString($map, $k)';
      case 'int' || 'PlatformInt64':
        return opt ? 'wireOptInt($map, $k)' : 'wireInt($map, $k)';
      case 'double':
        return opt ? 'wireOptDouble($map, $k)' : 'wireDouble($map, $k)';
      case 'bool':
        return opt ? 'wireOptBool($map, $k)' : 'wireBool($map, $k)';
      case 'BigInt':
        return opt ? 'wireOptBigInt($map, $k)' : 'wireBigInt($map, $k)';
      case 'List<String>':
        return opt ? 'wireOptStringList($map, $k)' : 'wireStringList($map, $k)';
      case 'Uint8List':
        return 'wireBytes($map, $k)';
    }
    if (model.enums.containsKey(base)) {
      return opt
          ? 'decode$base($map[$k])'
          : 'wireRequired(decode$base($map[$k]), $k)';
    }
    if (model.classes.containsKey(base)) {
      if (variantSpecs[owner]?.flatten.contains(f.name) ?? false) {
        return 'decode$base($map)';
      }
      return opt
          ? '$map[$k] == null ? null : decode$base(wireMap($map[$k]))'
          : 'decode$base(wireMap($map[$k]))';
    }
    final list = RegExp(r'^List<(\w+)>$').firstMatch(base);
    if (list != null && model.classes.containsKey(list[1])) {
      return 'wireMapList($map, $k).map(decode${list[1]}).toList()';
    }
    throw StateError('No wire codec for $owner.${f.name}: ${f.type}');
  }

  void mapLiteral(String owner, List<Field> fields, String access) {
    final spec = variantSpecs[owner];
    out.writeln('<String, Object?>{');
    for (final f in fields) {
      if (spec?.flatten.contains(f.name) ?? false) {
        out.writeln('...${encodeValue(owner, f, '$access.${f.name}')},');
        continue;
      }
      final value = encodeValue(owner, f, '$access.${f.name}');
      if (spec?.omitNull.contains(f.name) ?? false) {
        out.writeln(
          "if ($access.${f.name} != null) '${key(owner, f)}': $value,",
        );
      } else {
        out.writeln("'${key(owner, f)}': $value,");
      }
    }
    out.write('}');
  }

  void constructorCall(String owner, String ctor, List<Field> fields) {
    out.writeln('$ctor(');
    for (final f in fields) {
      out.writeln('${f.name}: ${decodeValue(owner, f, 'd')},');
    }
    out.write(')');
  }

  String generate() {
    out.writeln('''
// GENERATED by tool/generate_event_wire.dart from lib/src/event/*.dart.
// Do not edit: change the Rust event, regenerate FRB, then run the tool.
// Names that differ from the Rust ones are listed in tool/event_wire_spec.dart.

// ignore_for_file: require_trailing_commas, unnecessary_non_null_assertion

import '../device.dart' show FrameType;
import '../event.dart';
import 'event_wire_custom.dart';
import 'wire_values.dart';

/// An event payload as it travels between a host and its clients: the event
/// type and its fields.
typedef WireEvent = (String type, Map<String, Object?> data);

/// The wire form of [payload].
WireEvent encodeEventPayload(EventPayload payload) => switch (payload) {''');
    for (final v in model.unions['EventPayload']!) {
      final inner = v.fields.single.type;
      if (_polarClasses.containsKey(inner)) {
        out.writeln(
          "${v.className}(:final field0) => "
          "('${_polarClasses[inner]}', encode$inner(field0)),",
        );
      } else {
        out.writeln(
          '${v.className}(:final field0) => _encode$inner(field0),',
        );
      }
    }
    out.writeln('''
};

/// The payload a [category] event of [type] carries, or null when this build
/// has no event of that name in that family. Throws [FormatException] when
/// [data] lacks a field the event cannot be built without.
EventPayload? decodeEventPayload(
  EventCategory category,
  String type,
  Map<String, Object?> data, {
  EventSeverity severity = EventSeverity.info,
}) {
  switch (category) {''');
    for (final entry in _families.entries) {
      out.writeln('case EventCategory.${entry.key}:');
      for (final union in entry.value) {
        final name = 'decoded$union';
        out.writeln('final $name = _decode$union(type, data, severity);');
        out.writeln(
          'if ($name != null) return '
          'EventPayload.${_payloadFactory[union]}($name);',
        );
      }
      out.writeln('return null;');
    }
    out.writeln('case EventCategory.polarAlignment:');
    out.writeln('switch (type) {');
    for (final entry in _polarClasses.entries) {
      final factory = model.unions['EventPayload']!
          .firstWhere((v) => v.fields.single.type == entry.key)
          .factory;
      out.writeln(
        "case '${entry.value}': return EventPayload.$factory("
        'decode${entry.key}(data));',
      );
    }
    out.writeln('}\nreturn null;\n}\n}\n');

    for (final union in _payloadFactory.keys) {
      _union(union);
    }
    for (final entry in model.classes.entries) {
      if (entry.key == 'SkotiqEvent') continue;
      _class(entry.key, entry.value);
    }
    for (final name in {...usedEnums, ...customCodecEnums}.toList()..sort()) {
      _enum(name, model.enums[name]!);
    }
    out.writeln('''
/// Every event type this build sends, by family, for tests and tables that
/// must cover them all.
const Map<EventCategory, List<String>> eventWireTypes = {''');
    for (final entry in _families.entries) {
      out.writeln('EventCategory.${entry.key}: [');
      for (final union in entry.value) {
        for (final v in model.unions[union]!) {
          final custom = variantSpecs[v.className]?.customTypes;
          for (final type in custom ?? [wireType(v)]) {
            out.writeln("'$type',");
          }
        }
      }
      out.writeln('],');
    }
    out.writeln('EventCategory.polarAlignment: [');
    for (final type in _polarClasses.values) {
      out.writeln("'$type',");
    }
    out.writeln('],\n};');
    return out.toString();
  }

  void _union(String union) {
    final variants = model.unions[union]!;
    out.writeln('WireEvent _encode$union($union event) => switch (event) {');
    for (final v in variants) {
      final spec = variantSpecs[v.className];
      if (spec?.customTypes != null) {
        out.writeln(
          '${v.className}() => encode${v.union}${v.pascal}(event),',
        );
        continue;
      }
      out.write("${v.className}() => ('${wireType(v)}', ");
      mapLiteral(v.className, v.fields, 'event');
      out.writeln('),');
    }
    out.writeln('};\n');

    out.writeln(
      '$union? _decode$union('
      'String type, Map<String, Object?> d, EventSeverity severity) {',
    );
    out.writeln('switch (type) {');
    final byType = <String, List<Variant>>{};
    for (final v in variants) {
      final spec = variantSpecs[v.className];
      if (spec?.customTypes != null) {
        for (final type in spec!.customTypes!) {
          out.writeln("case '$type':");
        }
        out.writeln(
          'return decode${v.union}${v.pascal}(type, d, severity);',
        );
        continue;
      }
      byType.putIfAbsent(wireType(v), () => []).add(v);
    }
    for (final entry in byType.entries) {
      out.writeln("case '${entry.key}':");
      final sharing = [...entry.value]
        ..sort((a, b) {
          final aKeyed = variantSpecs[a.className]?.whenKey != null;
          final bKeyed = variantSpecs[b.className]?.whenKey != null;
          return aKeyed == bKeyed ? 0 : (aKeyed ? -1 : 1);
        });
      if (sharing.where((v) => variantSpecs[v.className]?.whenKey == null).length >
          1) {
        throw StateError('${entry.key} is sent by two variants of $union');
      }
      for (final v in sharing) {
        for (final alias in variantSpecs[v.className]?.aliases ?? const <String>[]) {
          out.writeln("case '$alias':");
        }
      }
      for (final v in sharing) {
        final whenKey = variantSpecs[v.className]?.whenKey;
        if (whenKey != null) out.writeln("if (d['$whenKey'] != null) {");
        out.write('return ');
        if (v.fields.isEmpty) {
          out.write('const $union.${v.factory}()');
        } else {
          constructorCall(v.className, '$union.${v.factory}', v.fields);
        }
        out.writeln(';');
        if (whenKey != null) out.writeln('}');
      }
      if (sharing.every((v) => variantSpecs[v.className]?.whenKey != null)) {
        out.writeln('return null;');
      }
    }
    out.writeln('}\nreturn null;\n}\n');
  }

  void _class(String name, List<Field> fields) {
    out.write('Map<String, Object?> encode$name($name value) => ');
    mapLiteral(name, fields, 'value');
    out.writeln(';\n');
    out.write('$name decode$name(Map<String, Object?> d) => ');
    constructorCall(name, name, fields);
    out.writeln(';\n');
  }

  String _enumWire(String name, String value) =>
      enumWireNames[name]?[value] ?? snake(value);

  void _enum(String name, List<String> values) {
    out.writeln('String encode$name($name value) => switch (value) {');
    for (final value in values) {
      out.writeln("$name.$value => '${_enumWire(name, value)}',");
    }
    out.writeln('};\n');
    out.writeln('$name? decode$name(Object? raw) => switch (raw) {');
    for (final value in values) {
      out.writeln("'${_enumWire(name, value)}' => $name.$value,");
    }
    out.writeln('_ => null,\n};\n');
  }
}

class SampleGenerator {
  SampleGenerator(this.model);
  final Model model;
  int _n = 0;

  String value(Field f, {required bool full, int depth = 0}) {
    if (f.nullable && !full) return 'null';
    final base = f.base;
    _n++;
    switch (base) {
      case 'String':
        return "'${f.name}$_n'";
      case 'int' || 'PlatformInt64':
        return '$_n';
      case 'double':
        return '$_n.5';
      case 'bool':
        return _n.isEven ? 'true' : 'false';
      case 'BigInt':
        return 'BigInt.from($_n)';
      case 'List<String>':
        return "['a$_n', 'b$_n']";
      case 'Uint8List':
        return 'Uint8List.fromList([1, 2, $_n % 256])';
    }
    if (model.enums.containsKey(base)) {
      final values = model.enums[base]!;
      return '$base.${values[_n % values.length]}';
    }
    if (model.classes.containsKey(base)) {
      return construct(base, model.classes[base]!, full: full);
    }
    if (model.unions.containsKey(base)) {
      final variants = model.unions[base]!;
      final v = variants[_n % variants.length];
      return v.fields.isEmpty
          ? 'const $base.${v.factory}()'
          : construct('$base.${v.factory}', v.fields, full: full);
    }
    final list = RegExp(r'^List<(\w+)>$').firstMatch(base);
    if (list != null && model.classes.containsKey(list[1])) {
      return '[${construct(list[1]!, model.classes[list[1]]!, full: full)}]';
    }
    throw StateError('No sample for ${f.type}');
  }

  String construct(String ctor, List<Field> fields, {required bool full}) {
    final args = [
      for (final f in fields) '${f.name}: ${value(f, full: full)}',
    ];
    return '$ctor(${args.join(', ')})';
  }

  String generate() {
    final out = StringBuffer('''
// GENERATED by tool/generate_event_wire.dart. Do not edit.

// ignore_for_file: require_trailing_commas, prefer_const_constructors

import 'dart:typed_data';

import 'package:skotiq_bridge/src/device.dart' show FrameType;
import 'package:skotiq_bridge/src/event.dart';

/// One value of every event variant with every field set, and one with every
/// optional field absent.
final List<EventPayload> eventWireSamples = [
''');
    for (final v in model.unions['EventPayload']!) {
      final inner = v.fields.single.type;
      for (final full in [true, false]) {
        if (model.classes.containsKey(inner)) {
          out.writeln(
            'EventPayload.${v.factory}('
            '${construct(inner, model.classes[inner]!, full: full)}),',
          );
          continue;
        }
        for (final variant in model.unions[inner]!) {
          final event = variant.fields.isEmpty
              ? 'const $inner.${variant.factory}()'
              : construct(
                  '$inner.${variant.factory}',
                  variant.fields,
                  full: full,
                );
          if (variant.fields.isEmpty && !full) continue;
          out.writeln('EventPayload.${v.factory}($event),');
        }
      }
    }
    out.writeln('];');
    return out.toString();
  }
}

/// The event types a host sends, per category, for the web pages. A
/// server-sent event's `event:` name is its type, and a page names one as
/// `WIRE_EVENTS.<category>.<type in lowerCamelCase>`.
String webEventTable(Model model) {
  final generator = Generator(model);
  final byCategory = <String, Iterable<String>>{
    for (final entry in _families.entries)
      entry.key: {
        for (final union in entry.value)
          for (final v in model.unions[union]!)
            ...variantSpecs[v.className]?.customTypes ?? [generator.wireType(v)],
      },
    'polarAlignment': _polarClasses.values,
  };
  final out = StringBuffer(
    '// GENERATED by packages/skotiq_bridge/tool/generate_event_wire.dart from\n'
    '// the event codec. Do not edit: change the Rust event, regenerate FRB, then\n'
    '// run the tool.\n'
    '//\n'
    "// The event types a host sends, per event category. A server-sent event's\n"
    '// `event:` name is its type, so a listener names it from this table.\n'
    "'use strict';\n"
    '\n'
    'const WIRE_EVENTS = Object.freeze({\n',
  );
  for (final MapEntry(key: category, value: types) in byCategory.entries) {
    out.writeln('  $category: Object.freeze({');
    for (final type in types) {
      out.writeln("    ${type[0].toLowerCase()}${type.substring(1)}: '$type',");
    }
    out.writeln('  }),');
  }
  out.writeln('});');
  return out.toString();
}

String _format(String path, String source) {
  File(path).writeAsStringSync(source);
  if (!path.endsWith('.dart')) return source;
  final result = Process.runSync('dart', ['format', path]);
  if (result.exitCode != 0) {
    stderr.writeln(result.stdout);
    stderr.writeln(result.stderr);
    throw StateError('dart format failed for $path');
  }
  return File(path).readAsStringSync();
}

void main(List<String> args) {
  final package = Directory.fromUri(Platform.script.resolve('..'));
  final model = readModel(Directory('${package.path}lib/src/event'));
  final outputs = {
    '${package.path}lib/src/event_wire/event_wire.g.dart': Generator(
      model,
    ).generate(),
    '${package.path}test/event_wire_samples.g.dart': SampleGenerator(
      model,
    ).generate(),
    '${package.path}../../apps/desktop/web_run_watch/js/wire-events.js':
        webEventTable(model),
  };
  if (args.contains('--check')) {
    final scratch = Directory.systemTemp.createTempSync('event_wire');
    var stale = false;
    for (final entry in outputs.entries) {
      final name = entry.key.split('/').last;
      final fresh = _format('${scratch.path}/$name', entry.value);
      final file = File(entry.key);
      if (!file.existsSync() || file.readAsStringSync() != fresh) {
        stderr.writeln('${entry.key} is out of date; run the generator.');
        stale = true;
      }
    }
    scratch.deleteSync(recursive: true);
    exit(stale ? 1 : 0);
  }
  for (final entry in outputs.entries) {
    _format(entry.key, entry.value);
    stdout.writeln('Wrote ${entry.key}');
  }
}
