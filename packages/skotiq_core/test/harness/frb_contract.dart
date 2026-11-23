import 'dart:io';

/// The fields of the generated FRB class [className] in
/// `packages/skotiq_bridge/lib/src/[file]`, read from its constructor.
///
/// A contract test constructs the FRB type with named arguments, which stops
/// compiling when Rust adds a required field or removes one; an optional
/// (`Option<T>`) field Rust adds is not required by the constructor, so the
/// test also compares the field list it covers with this one.
Set<String> frbFields(String file, String className) {
  final source = File('../skotiq_bridge/lib/src/$file').readAsStringSync();
  final constructor = RegExp(
    'const $className\\(\\{([^}]*)\\}\\);',
  ).firstMatch(source);
  if (constructor == null) {
    throw StateError('no generated constructor for $className in $file');
  }
  return {
    for (final match in RegExp(r'this\.(\w+)').allMatches(constructor[1]!))
      match[1]!,
  };
}
