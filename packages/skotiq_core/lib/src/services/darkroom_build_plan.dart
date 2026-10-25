import 'dart:convert';

/// Smallest crop, as a fraction of the field, a build accepts by default.
const double defaultMinRetainedArea = .8;

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
    final retained = value['minRetainedArea'] ?? defaultMinRetainedArea;
    if (overlap is! num ||
        !overlap.isFinite ||
        overlap < .5 ||
        overlap > 1 ||
        eccentricity is! num ||
        !eccentricity.isFinite ||
        eccentricity <= 0 ||
        eccentricity > 1 ||
        retained is! num ||
        !retained.isFinite ||
        retained < .1 ||
        retained > 1) {
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
      if (calibration['dark'] != null &&
          calibration['bias'] != null &&
          calibration['scaleDark'] != true) {
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
    return DarkroomBuildPlan._(
      jsonEncode({...value, 'minRetainedArea': retained}),
    );
  }

  Map<String, dynamic> toJson() =>
      Map<String, dynamic>.from(jsonDecode(_json) as Map);

  String get target => toJson()['target'] as String;
  String get referencePath => toJson()['referencePath'] as String;
  double get minRetainedArea => (toJson()['minRetainedArea'] as num).toDouble();

  /// Every light in the plan, in build order.
  List<Map<String, dynamic>> get lights => [
    for (final g in toJson()['groups'] as List)
      for (final l in (g as Map)['lights'] as List)
        Map<String, dynamic>.from(l as Map),
  ];

  /// Filters in the order they are built.
  List<String> get filters => {
    for (final g in toJson()['groups'] as List) (g as Map)['filter'] as String,
  }.toList()..sort();

  /// This plan without the lights at [reasons]' keys, each recorded as
  /// excluded with its reason. Groups left empty are dropped. The reference
  /// cannot be excluded; choose another reference first.
  DarkroomBuildPlan withoutLights(Map<String, String> reasons) {
    final value = toJson();
    if (reasons.containsKey(value['referencePath'])) {
      throw ArgumentError(
        'The alignment reference cannot be excluded. Choose another reference first.',
      );
    }
    final excluded = [...(value['excluded'] as List? ?? const [])];
    final groups = <Map<String, dynamic>>[];
    for (final g in value['groups'] as List) {
      final group = Map<String, dynamic>.from(g as Map);
      final kept = <dynamic>[];
      for (final l in group['lights'] as List) {
        final path = (l as Map)['path'] as String;
        final reason = reasons[path];
        if (reason == null) {
          kept.add(l);
        } else {
          excluded.add({
            'filter': group['filter'],
            'path': path,
            'reason': reason,
          });
        }
      }
      if (kept.isNotEmpty) groups.add({...group, 'lights': kept});
    }
    return DarkroomBuildPlan.fromJson({
      ...value,
      'groups': groups,
      'excluded': excluded,
    });
  }

  /// The plan with a different smallest acceptable crop.
  DarkroomBuildPlan withMinRetainedArea(double value) =>
      DarkroomBuildPlan.fromJson({...toJson(), 'minRetainedArea': value});
}
