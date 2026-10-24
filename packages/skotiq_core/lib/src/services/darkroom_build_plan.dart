import 'dart:convert';

/// Validated, frozen native build inputs. Kept with a run so recovery cannot
/// silently substitute another target, reference, calibration set or filter.
class DarkroomBuildPlan {
  DarkroomBuildPlan._(this._json);
  final String _json;

  factory DarkroomBuildPlan.fromJson(Map<String, dynamic> value) {
    if (value['version'] != 1) {
      throw const FormatException('Unsupported master-build plan version.');
    }
    final groups = value['groups'];
    if (value['target'] is! String ||
        value['referencePath'] is! String ||
        groups is! List ||
        groups.isEmpty) {
      throw const FormatException(
        'A build needs a target, reference and frame groups.',
      );
    }
    final overlap = value['minOverlap'];
    final eccentricity = value['maxEccentricity'];
    if (overlap is! num ||
        !overlap.isFinite ||
        overlap < .5 ||
        overlap > 1 ||
        eccentricity is! num ||
        !eccentricity.isFinite ||
        eccentricity <= 0 ||
        eccentricity > 1) {
      throw const FormatException('Invalid framing or star-shape limits.');
    }
    final paths = <String>{};
    for (final group in groups) {
      if (group is! Map ||
          group['filter'] is! String ||
          (group['filter'] as String).isEmpty ||
          group['label'] is! String ||
          group['lights'] is! List ||
          (group['lights'] as List).isEmpty ||
          group['calibration'] is! Map) {
        throw const FormatException(
          'Invalid calibration group in saved build.',
        );
      }
      final calibration = group['calibration'] as Map;
      if (calibration['dark'] != null && calibration['bias'] != null) {
        throw const FormatException(
          'Choose dark or bias for lights; master darks already include bias.',
        );
      }
      for (final key in ['dark', 'bias', 'flat']) {
        if (calibration[key] != null &&
            (calibration[key] is! String ||
                (calibration[key] as String).isEmpty)) {
          throw const FormatException('Invalid calibration path.');
        }
      }
      for (final light in group['lights'] as List) {
        if (light is! Map ||
            light['path'] is! String ||
            (light['path'] as String).isEmpty ||
            light['id'] is! int ||
            light['exposureSec'] is! num ||
            !(light['exposureSec'] as num).isFinite ||
            (light['exposureSec'] as num) <= 0 ||
            !paths.add(light['path'] as String)) {
          throw const FormatException(
            'A light is invalid or appears more than once in this build.',
          );
        }
      }
    }
    if (!paths.contains(value['referencePath'])) {
      throw const FormatException('Reference must be an included light.');
    }
    return DarkroomBuildPlan._(jsonEncode(value));
  }

  Map<String, dynamic> toJson() =>
      Map<String, dynamic>.from(jsonDecode(_json) as Map);
}
