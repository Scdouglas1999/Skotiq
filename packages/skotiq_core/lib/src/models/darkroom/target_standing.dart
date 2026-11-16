import 'dart:convert';

/// Letters and digits only, upper case: `NGC 891`, `ngc891` and `NGC_891`
/// are one name; `ngc0891` stays distinct where its characters differ.
String normalizeDarkroomTargetName(String name) =>
    name.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// What the captured frames of one target add up to: the facts the project
/// rule reads.
class TargetCaptures {
  const TargetCaptures({
    this.frames = 0,
    this.lights = 0,
    this.keptLights = 0,
    this.keptSeconds = 0,
    this.runLights = 0,
  });

  /// Every captured frame of the target, lights and calibration alike.
  final int frames;
  final int lights;

  /// Lights accepted at capture and not rejected since.
  final int keptLights;
  final double keptSeconds;

  /// Lights a sequence run took; the rest were taken by hand.
  final int runLights;

  bool get onlySnapshots => lights > 0 && runLights == 0;
}

/// The user's settings for which imaged targets are projects: enough kept
/// light, in time and in frames, that it is worth building masters from.
class ProjectRule {
  const ProjectRule({
    this.minKeptMinutes = defaultMinKeptMinutes,
    this.minKeptFrames = defaultMinKeptFrames,
  });

  static const defaultMinKeptMinutes = 30;
  static const defaultMinKeptFrames = 10;

  static const minKeptMinutesKey = 'darkroom.projects.min_kept_minutes';
  static const minKeptFramesKey = 'darkroom.projects.min_kept_frames';

  final int minKeptMinutes;
  final int minKeptFrames;

  /// The rule the stored settings hold; a missing or unreadable value is
  /// its default.
  factory ProjectRule.fromSettings({String? minutes, String? frames}) {
    int read(String? raw, int fallback) {
      final value = int.tryParse(raw ?? '');
      return value == null || value < 0 ? fallback : value;
    }

    return ProjectRule(
      minKeptMinutes: read(minutes, defaultMinKeptMinutes),
      minKeptFrames: read(frames, defaultMinKeptFrames),
    );
  }

  Map<String, String> toSettings() => {
    minKeptMinutesKey: '$minKeptMinutes',
    minKeptFramesKey: '$minKeptFrames',
  };

  @override
  bool operator ==(Object other) =>
      other is ProjectRule &&
      other.minKeptMinutes == minKeptMinutes &&
      other.minKeptFrames == minKeptFrames;

  @override
  int get hashCode => Object.hash(minKeptMinutes, minKeptFrames);
}

/// A correction the user made to where a target is listed.
enum TargetPlacement {
  /// Listed by the project rule.
  auto,

  /// Listed as a project whatever the rule says.
  project,

  /// Kept out of the projects whatever the rule says.
  hidden,
}

/// Where the Darkroom lists a target, and why.
enum TargetStanding {
  /// A saved target nothing was captured for.
  unused,

  /// Captured, but not a project: listed under Other captures.
  capture,

  project,
}

/// The one rule for what a target is: unused, a capture, or a project.
///
/// A target with frames is a project when its kept lights reach both of
/// [rule]'s minimums, or when the user placed it there; [placement] hidden
/// keeps it out. Calibration frames and rejected lights never count.
TargetStanding targetStanding(
  TargetCaptures captures,
  ProjectRule rule, {
  TargetPlacement placement = TargetPlacement.auto,
}) {
  if (captures.frames == 0) return TargetStanding.unused;
  return switch (placement) {
    TargetPlacement.project => TargetStanding.project,
    TargetPlacement.hidden => TargetStanding.capture,
    TargetPlacement.auto =>
      captures.keptSeconds >= rule.minKeptMinutes * 60 &&
              captures.keptLights >= rule.minKeptFrames &&
              captures.keptLights > 0
          ? TargetStanding.project
          : TargetStanding.capture,
  };
}

/// Why a captured target is not a project, in a few words for its row.
String captureReason(
  TargetCaptures captures,
  ProjectRule rule, {
  TargetPlacement placement = TargetPlacement.auto,
}) {
  if (placement == TargetPlacement.hidden) return 'Hidden by you';
  if (captures.lights == 0) return 'Calibration frames only';
  if (captures.keptLights == 0) return 'No kept subs';
  if (captures.onlySnapshots && captures.keptLights < rule.minKeptFrames) {
    return 'Snapshots taken by hand';
  }
  if (captures.keptLights < rule.minKeptFrames) {
    return 'Fewer than ${rule.minKeptFrames} kept subs';
  }
  return 'Under ${_minutes(rule.minKeptMinutes)} of kept subs';
}

String _minutes(int minutes) =>
    minutes % 60 == 0 && minutes >= 60 ? '${minutes ~/ 60} h' : '$minutes min';

/// The user's placements, by target name. Names are compared without case,
/// spaces or punctuation, so "NGC 891" and "ngc891" are one entry.
class TargetPlacements {
  const TargetPlacements([this._byName = const {}]);

  static const settingsKey = 'darkroom.target_placements';

  final Map<String, TargetPlacement> _byName;

  TargetPlacement of(String name) =>
      _byName[normalizeDarkroomTargetName(name)] ?? TargetPlacement.auto;

  TargetPlacements withPlacement(String name, TargetPlacement placement) {
    final next = Map.of(_byName);
    if (placement == TargetPlacement.auto) {
      next.remove(normalizeDarkroomTargetName(name));
    } else {
      next[normalizeDarkroomTargetName(name)] = placement;
    }
    return TargetPlacements(next);
  }

  /// [from]'s placement moved to [to], as a rename does.
  TargetPlacements renamed(String from, String to) =>
      withPlacement(to, of(from)).withPlacement(from, TargetPlacement.auto);

  /// The placements stored as [raw]; none when nothing is stored.
  static TargetPlacements decode(String? raw) {
    if (raw == null || raw.isEmpty) return const TargetPlacements();
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('$settingsKey is not a JSON object');
    }
    return TargetPlacements({
      for (final MapEntry(:key, :value) in decoded.entries)
        if (TargetPlacement.values.where((p) => p.name == value).firstOrNull
            case final TargetPlacement placement)
          '$key': placement,
    });
  }

  String encode() => jsonEncode({
    for (final MapEntry(:key, :value) in _byName.entries) key: value.name,
  });
}
