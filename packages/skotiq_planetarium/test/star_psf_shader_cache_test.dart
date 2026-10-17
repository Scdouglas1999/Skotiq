import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/rendering/star_psf_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('StarPsfShaderCache reuses shader for same key', () {
    final cache = StarPsfShaderCache();
    const color = Colors.orange;
    const radius = 5.5;

    final shaderA = cache.getShader(
      type: StarPsfShaderType.glow,
      radius: radius,
      color: color,
    );
    final shaderB = cache.getShader(
      type: StarPsfShaderType.glow,
      radius: radius,
      color: color,
    );

    expect(identical(shaderA, shaderB), isTrue);
  });

  test('StarPsfShaderCache separates different radii', () {
    final cache = StarPsfShaderCache();
    const color = Colors.orange;

    final shaderA = cache.getShader(
      type: StarPsfShaderType.glow,
      radius: 5.5,
      color: color,
    );
    final shaderB = cache.getShader(
      type: StarPsfShaderType.glow,
      radius: 6.5,
      color: color,
    );

    expect(identical(shaderA, shaderB), isFalse);
  });

  test('StarPsfShaderCache separates different colors', () {
    final cache = StarPsfShaderCache();
    const radius = 5.5;

    final shaderA = cache.getShader(
      type: StarPsfShaderType.glow,
      radius: radius,
      color: Colors.orange,
    );
    final shaderB = cache.getShader(
      type: StarPsfShaderType.glow,
      radius: radius,
      color: Colors.blue,
    );

    expect(identical(shaderA, shaderB), isFalse);
  });

  test('StarPsfShaderCache separates different types', () {
    final cache = StarPsfShaderCache();
    const color = Colors.orange;
    const radius = 5.5;

    final shaderA = cache.getShader(
      type: StarPsfShaderType.glow,
      radius: radius,
      color: color,
    );
    final shaderB = cache.getShader(
      type: StarPsfShaderType.core,
      radius: radius,
      color: color,
    );

    expect(identical(shaderA, shaderB), isFalse);
  });
}
