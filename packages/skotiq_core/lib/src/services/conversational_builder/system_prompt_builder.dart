// Conversational sequence builder: system-prompt composer.
//
// Owns the (long, opinionated) system prompt that turns a free-text
// user request into a JSON Sequence object compatible with
// SequenceFileService.parseFromMap. The prompt has three sections:
//
//   1. Persona + ground rules.
//   2. The current "rig + tonight" context — equipment profile,
//      filters, focal length / aperture, observer location, dark
//      window bounds, observable target candidates, weather note.
//   3. The JSON schema reference — every nodeType the executor
//      recognises, the fields it accepts, valid enum values, plus
//      two worked few-shot examples.
//
// The schema reference is deliberately abridged: we list the nodeType
// strings, their required fields, and a "what does this do" comment.
// We do NOT list every field of every node — the LLM would burn
// thousands of tokens copying back fields it doesn't need. Instead
// the schema documents the *common* set; the validator catches
// missing-required-field errors and the self-correction loop teaches
// the model which fields it actually needs.

import 'conversational_builder_service.dart';

/// Composes the conversational builder system prompt. Stateless — held
/// by the service as a const-default but overridable in tests.
class SystemPromptBuilder {
  const SystemPromptBuilder();

  String build(ConversationalBuilderContext context) {
    final buf = StringBuffer();
    _writePersona(buf);
    buf.writeln();
    _writeRigContext(buf, context);
    buf.writeln();
    _writeNodeSchema(buf);
    buf.writeln();
    _writeExamples(buf);
    buf.writeln();
    _writeFinalInstructions(buf);
    return buf.toString();
  }

  // Persona

  void _writePersona(StringBuffer buf) {
    buf.writeln('# Role');
    buf.writeln(
      'You are the Skotiq Sequence Planner — an expert astrophotography '
      'session planner that turns a free-text user request into a valid '
      'Skotiq sequence JSON object.',
    );
    buf.writeln();
    buf.writeln('# Ground rules');
    buf.writeln(
      '1. ALWAYS output a single JSON object and NOTHING ELSE. No prose, '
      'no markdown fences, no commentary.',
    );
    buf.writeln(
      '2. The JSON must conform to the schema below — fields not listed are '
      'ignored. Unknown nodeType values are rejected.',
    );
    buf.writeln(
      '3. Every node must have a unique "id" (uuid-style) and a "parentId" '
      'pointing at its parent (null for the root). Every parent must list '
      'its children in "childIds" in execution order.',
    );
    buf.writeln(
      '4. Honor the user\'s equipment profile. If the user asks for filters '
      'the rig does not have, substitute the closest available filter and '
      'note the substitution in the sequence "description".',
    );
    buf.writeln(
      '5. Honor the dark window if provided. If a target cannot fit, drop '
      'it (do NOT silently push exposures past sunrise).',
    );
    buf.writeln(
      '6. Prefer the SmartExposure node over a chain of individual Exposure '
      'nodes when imaging multiple filters on the same target.',
    );
    buf.writeln(
      '7. Wrap multiple targets in a TargetScheduler when there are 3 or '
      'more targets, otherwise chain TargetHeader nodes linearly.',
    );
    buf.writeln(
      '8. Always cool the camera before imaging, unpark the mount, and '
      'park + warm at the end. Always plate-solve center on each target.',
    );
    buf.writeln(
      '9. Add an Autofocus node before each target\'s first exposure. If '
      'the user asks for periodic refocus, add the cadence to the '
      'SmartExposure or set up the autofocus trigger on the appropriate '
      'parent node.',
    );
  }

  // Rig context

  void _writeRigContext(StringBuffer buf, ConversationalBuilderContext ctx) {
    final profile = ctx.profile;
    buf.writeln('# Current rig + tonight');
    buf.writeln('Equipment profile: "${profile.name}".');
    if (profile.cameraName != null) {
      buf.writeln('- Camera: ${profile.cameraName}');
    }
    if (profile.mountName != null) {
      buf.writeln('- Mount: ${profile.mountName}');
    }
    if (profile.telescopeName != null) {
      buf.writeln(
        '- Telescope: ${profile.telescopeName} '
        '(focal length ${profile.focalLength.toStringAsFixed(0)}mm, '
        'aperture ${profile.aperture.toStringAsFixed(0)}mm)',
      );
    } else {
      buf.writeln(
        '- Optics: focal length ${profile.focalLength.toStringAsFixed(0)}mm, '
        'aperture ${profile.aperture.toStringAsFixed(0)}mm',
      );
    }
    if (profile.filterWheelName != null && profile.filterNames.isNotEmpty) {
      buf.writeln(
        '- Filter wheel: ${profile.filterWheelName} — filters: '
        '${compressFilters(profile.filterNames)}',
      );
    } else if (profile.filterNames.isNotEmpty) {
      buf.writeln(
        '- Filters available: ${compressFilters(profile.filterNames)}',
      );
    } else {
      buf.writeln(
        '- No filter wheel — assume OSC / one-shot color (filter "OSC").',
      );
    }
    if (profile.defaultGain != null || profile.defaultOffset != null) {
      buf.writeln(
        '- Default camera gain/offset: '
        '${profile.defaultGain ?? "—"} / ${profile.defaultOffset ?? "—"}',
      );
    }
    if (profile.defaultCoolingTemp != null) {
      buf.writeln(
        '- Default cooling target: '
        '${profile.defaultCoolingTemp!.toStringAsFixed(0)}°C',
      );
    }
    if (ctx.latitudeDeg != null && ctx.longitudeDeg != null) {
      buf.writeln(
        '- Observer location: lat ${ctx.latitudeDeg!.toStringAsFixed(3)}, '
        'lon ${ctx.longitudeDeg!.toStringAsFixed(3)}',
      );
    }
    if (ctx.windowStart != null && ctx.windowEnd != null) {
      buf.writeln(
        '- Tonight\'s dark window: '
        '${ctx.windowStart!.toIso8601String()} → '
        '${ctx.windowEnd!.toIso8601String()} '
        '(${_durationLabel(ctx.windowStart!, ctx.windowEnd!)})',
      );
    }
    if (ctx.weatherNote != null && ctx.weatherNote!.isNotEmpty) {
      buf.writeln('- Weather: ${ctx.weatherNote}');
    }
    if (ctx.candidates.isNotEmpty) {
      buf.writeln();
      buf.writeln(
        '## Candidate targets (from the user\'s observing list / Smart '
        'Night top picks). Prefer drawing from this list — it is what the '
        'user has already saved as worth imaging tonight.',
      );
      for (final candidate in ctx.candidates.take(12)) {
        buf.writeln(
          '- ${candidate.targetName}: '
          'RA ${candidate.raHours.toStringAsFixed(3)}h, '
          'Dec ${candidate.decDegrees.toStringAsFixed(2)}°, '
          'score ${candidate.totalScore.toStringAsFixed(0)}/100',
        );
      }
      if (ctx.candidates.length > 12) {
        buf.writeln('- … (+${ctx.candidates.length - 12} more)');
      }
    }
    buf.writeln();
    buf.writeln('## User options');
    buf.writeln(
      '- Restrict to candidate list: ${ctx.options.restrictToCandidates}',
    );
    if (ctx.options.maxSessionHours != null) {
      buf.writeln(
        '- Maximum session length: '
        '${ctx.options.maxSessionHours!.toStringAsFixed(1)} hours',
      );
    }
    buf.writeln('- Append flats at end: ${ctx.options.includeFlatsAtEnd}');
    buf.writeln(
      '- Use TargetScheduler for multi-target: '
      '${ctx.options.useSchedulerForMultiTarget}',
    );
  }

  // Node schema reference

  void _writeNodeSchema(StringBuffer buf) {
    buf.writeln('# Sequence JSON schema');
    buf.writeln('Top-level fields:');
    buf.writeln(
      '- `name` (string, required), `description` (string), '
      '`rootNodeId` (string, required), `nodes` (map of node id → node).',
    );
    buf.writeln();
    buf.writeln(
      'Each node has: `id`, `nodeType` (string, see list below), `name`, '
      '`parentId` (string|null), `childIds` (string[]), `orderIndex` (int), '
      '`isEnabled` (bool, default true), plus type-specific fields.',
    );
    buf.writeln();
    buf.writeln('## Available nodeType values');

    final entries = <List<String>>[
      [
        'InstructionSet',
        'Container of children executed in order. Use as the root node.',
        '',
      ],
      [
        'TargetHeader',
        'Marks a sky target and its imaging sub-tree (slew + center + '
            'guide + autofocus + SmartExposure).',
        '`targetName` (string), `raHours` (number, hours), '
            '`decDegrees` (number, degrees), `minAltitude` (number), '
            '`startAfter` (ISO timestamp, optional), '
            '`endBefore` (ISO timestamp, optional).',
      ],
      [
        'TargetScheduler',
        'Container of TargetHeader children — the executor picks the best '
            'one at runtime based on altitude / score.',
        '`altitudeWeight` (0..1), `moonDistanceWeight`, '
            '`transitProximityWeight`, `darknessWeight`, `airmassWeight`, '
            '`minScoreToRun` (0..100), `recomputeEveryNExposures` (int), '
            '`finishIterationOnSwitch` (bool).',
      ],
      [
        'SmartExposure',
        'Per-filter exposure rotation. Preferred over individual Exposure '
            'nodes for multi-filter imaging.',
        '`plans` (array of {filterName, count, durationSecs, ditherEvery}), '
            '`rotateFilters` (bool), `ditherOnFilterChange` (bool), '
            '`integrationBudgetSecs` (number), `batchSize` (int).',
      ],
      [
        'Exposure',
        'Take N exposures with one filter. Use for flats / darks / one-off '
            'shots; prefer SmartExposure for science.',
        '`durationSecs` (number), `count` (int), `frameType` '
            '(light|dark|flat|bias), `filter` (string), `gain` (int), '
            '`offset` (int), `binning` (one|two|three|four), '
            '`ditherEvery` (int).',
      ],
      [
        'Slew',
        'Slew to the target. Always pair with a Center node.',
        '`useTargetCoords` (bool, default true).',
      ],
      [
        'Center',
        'Plate-solve center on the target.',
        '`useTargetCoords` (bool), `accuracyArcsec` (number), '
            '`maxAttempts` (int).',
      ],
      [
        'StartGuiding',
        'Start the autoguider.',
        '`settlePixels` (number), `settleTime` (seconds), '
            '`settleTimeout` (seconds), `autoSelectStar` (bool).',
      ],
      [
        'Autofocus',
        'Run autofocus.',
        '`useSettingsDefaults` (bool), `maxDurationSecs` (number), '
            '`method` (vCurve|hyperbolic|quadratic).',
      ],
      [
        'FilterChange',
        'Change the filter wheel position.',
        '`filterName` (string), `filterPosition` (int, optional).',
      ],
      [
        'CoolCamera',
        'Cool the camera to a target temperature before imaging.',
        '`targetTemp` (°C, default -10), `durationMins` (number).',
      ],
      [
        'WarmCamera',
        'Gradually warm the camera at end of session.',
        '`ratePerMin` (°C/min), `targetTemp` (°C).',
      ],
      ['Unpark', 'Unpark the mount.', ''],
      ['Park', 'Park the mount.', ''],
      [
        'HomeMount',
        'Send the mount to its home position without parking it. '
            'Only when the user asks for it.',
        '',
      ],
      [
        'Dither',
        'One-shot dither.',
        '`pixels` (number), `settlePixels` (number), '
            '`settleTime` (seconds), `settleTimeout` (seconds).',
      ],
      [
        'MeridianFlip',
        'Handle the meridian flip.',
        '`autoCenter` (bool), `refocusAfter` (bool), '
            '`resumeGuiding` (bool), `useGlobalDefaults` (bool).',
      ],
      [
        'PolarAlignment',
        'Run polar alignment when stale.',
        '`startFromCurrent` (bool), `isNorth` (bool).',
      ],
      [
        'Recovery',
        'Parallel watchdog that triggers a recovery action.',
        '`triggerType` (hfrSpike|guidingLoss|weatherUnsafe|focusDrift), '
            '`recoveryAction` (retry|autofocusAndRetry|skipTarget|'
            'parkAndAbort), `maxRetries` (int).',
      ],
      [
        'WaitTime',
        'Wait until a wall-clock time or twilight phase.',
        '`waitUntil` (ISO timestamp, optional), `waitForTwilight` '
            '(civil|nautical|astronomical, optional).',
      ],
      ['Delay', 'Sleep for N seconds.', '`seconds` (number).'],
      [
        'Notification',
        'Send a user notification (in-app / push / etc.).',
        '`title` (string), `message` (string), '
            '`level` (info|warning|error|success).',
      ],
      [
        'Loop',
        'Repeat children until a condition is met.',
        '`conditionType` (count|untilTime|untilAltitude|untilIntegrationTime), '
            '`repeatCount` (int, optional), `repeatUntil` (ISO timestamp), '
            '`repeatUntilAltitude` (number), '
            '`integrationTimeTarget` (seconds).',
      ],
    ];

    for (final entry in entries) {
      buf.writeln('### `${entry[0]}`');
      buf.writeln(entry[1]);
      if (entry[2].isNotEmpty) {
        buf.writeln('Fields: ${entry[2]}');
      }
    }
  }

  // Few-shot examples

  void _writeExamples(StringBuffer buf) {
    buf.writeln('# Examples');
    buf.writeln();
    buf.writeln(
      '## Example A — "30 minutes of luminance on M31, no narrowband"',
    );
    buf.writeln('```json');
    buf.writeln(_exampleA);
    buf.writeln('```');
    buf.writeln();
    buf.writeln(
      '## Example B — "3 hours of Ha+OIII on the Heart Nebula, autofocus '
      'every 20 frames"',
    );
    buf.writeln('```json');
    buf.writeln(_exampleB);
    buf.writeln('```');
  }

  // Final instructions

  void _writeFinalInstructions(StringBuffer buf) {
    buf.writeln('# Output');
    buf.writeln(
      'Respond with ONLY the JSON object — no commentary, no markdown '
      'fences, no preamble. The object must be parseable by '
      '`SequenceFileService.parseFromMap`. Use unique UUID-like ids for '
      'every node.',
    );
  }

  // Helpers

  String _durationLabel(DateTime start, DateTime end) {
    final hours = end.difference(start).inMinutes / 60.0;
    return formatHours(hours);
  }
}

const String _exampleA = '''
{
  "schemaVersion": 1,
  "name": "M31 — 30m Luminance",
  "description": "Quick 30-minute luminance test on Andromeda.",
  "rootNodeId": "root",
  "nodes": {
    "root": {
      "id": "root", "nodeType": "InstructionSet",
      "name": "Session", "parentId": null,
      "childIds": ["cool", "unpark", "tgt", "park", "warm"],
      "orderIndex": 0, "isEnabled": true
    },
    "cool": {
      "id": "cool", "nodeType": "CoolCamera", "name": "Cool to -10C",
      "parentId": "root", "childIds": [], "orderIndex": 0,
      "isEnabled": true, "targetTemp": -10.0, "durationMins": 10.0
    },
    "unpark": {
      "id": "unpark", "nodeType": "Unpark", "name": "Unpark mount",
      "parentId": "root", "childIds": [], "orderIndex": 1, "isEnabled": true
    },
    "tgt": {
      "id": "tgt", "nodeType": "TargetHeader", "name": "M31",
      "parentId": "root", "childIds": ["slew","center","guide","af","exp"],
      "orderIndex": 2, "isEnabled": true,
      "targetName": "M31", "raHours": 0.712, "decDegrees": 41.27,
      "minAltitude": 30.0
    },
    "slew": {
      "id": "slew", "nodeType": "Slew", "name": "Slew",
      "parentId": "tgt", "childIds": [], "orderIndex": 0,
      "isEnabled": true, "useTargetCoords": true
    },
    "center": {
      "id": "center", "nodeType": "Center", "name": "Center",
      "parentId": "tgt", "childIds": [], "orderIndex": 1, "isEnabled": true,
      "useTargetCoords": true, "accuracyArcsec": 5.0, "maxAttempts": 5
    },
    "guide": {
      "id": "guide", "nodeType": "StartGuiding", "name": "Start guiding",
      "parentId": "tgt", "childIds": [], "orderIndex": 2, "isEnabled": true,
      "autoSelectStar": true
    },
    "af": {
      "id": "af", "nodeType": "Autofocus", "name": "Initial autofocus",
      "parentId": "tgt", "childIds": [], "orderIndex": 3, "isEnabled": true,
      "useSettingsDefaults": true
    },
    "exp": {
      "id": "exp", "nodeType": "Exposure", "name": "L 60s x30",
      "parentId": "tgt", "childIds": [], "orderIndex": 4, "isEnabled": true,
      "durationSecs": 60.0, "count": 30, "frameType": "light",
      "filter": "L", "binning": "one", "ditherEvery": 3
    },
    "park": {
      "id": "park", "nodeType": "Park", "name": "Park mount",
      "parentId": "root", "childIds": [], "orderIndex": 3, "isEnabled": true
    },
    "warm": {
      "id": "warm", "nodeType": "WarmCamera", "name": "Warm camera",
      "parentId": "root", "childIds": [], "orderIndex": 4, "isEnabled": true,
      "ratePerMin": 2.0, "targetTemp": 20.0
    }
  }
}
''';

const String _exampleB = '''
{
  "schemaVersion": 1,
  "name": "Heart Nebula — HOO 3h",
  "description": "3-hour Ha+OIII session with autofocus every 20 frames.",
  "rootNodeId": "root",
  "nodes": {
    "root": {
      "id": "root", "nodeType": "InstructionSet", "name": "Session",
      "parentId": null,
      "childIds": ["cool","unpark","tgt","park","warm"],
      "orderIndex": 0, "isEnabled": true
    },
    "cool": {
      "id": "cool", "nodeType": "CoolCamera", "name": "Cool",
      "parentId": "root", "childIds": [], "orderIndex": 0,
      "isEnabled": true, "targetTemp": -10.0, "durationMins": 10.0
    },
    "unpark": {
      "id": "unpark", "nodeType": "Unpark", "name": "Unpark",
      "parentId": "root", "childIds": [], "orderIndex": 1, "isEnabled": true
    },
    "tgt": {
      "id": "tgt", "nodeType": "TargetHeader", "name": "Heart Nebula",
      "parentId": "root", "childIds": ["slew","center","guide","af","smart"],
      "orderIndex": 2, "isEnabled": true,
      "targetName": "Heart Nebula (IC 1805)",
      "raHours": 2.55, "decDegrees": 61.45, "minAltitude": 30.0
    },
    "slew": {
      "id": "slew", "nodeType": "Slew", "name": "Slew",
      "parentId": "tgt", "childIds": [], "orderIndex": 0,
      "isEnabled": true, "useTargetCoords": true
    },
    "center": {
      "id": "center", "nodeType": "Center", "name": "Center",
      "parentId": "tgt", "childIds": [], "orderIndex": 1, "isEnabled": true,
      "useTargetCoords": true, "accuracyArcsec": 5.0, "maxAttempts": 5
    },
    "guide": {
      "id": "guide", "nodeType": "StartGuiding", "name": "Start guiding",
      "parentId": "tgt", "childIds": [], "orderIndex": 2, "isEnabled": true,
      "autoSelectStar": true
    },
    "af": {
      "id": "af", "nodeType": "Autofocus", "name": "Initial autofocus",
      "parentId": "tgt", "childIds": [], "orderIndex": 3,
      "isEnabled": true, "useSettingsDefaults": true
    },
    "smart": {
      "id": "smart", "nodeType": "SmartExposure",
      "name": "Smart Exposure Ha+OIII",
      "parentId": "tgt", "childIds": [], "orderIndex": 4, "isEnabled": true,
      "plans": [
        {"filterName": "Ha", "count": 18, "durationSecs": 300, "ditherEvery": 3},
        {"filterName": "OIII", "count": 18, "durationSecs": 300, "ditherEvery": 3}
      ],
      "rotateFilters": true, "ditherOnFilterChange": false,
      "integrationBudgetSecs": 10800, "batchSize": 1
    },
    "park": {
      "id": "park", "nodeType": "Park", "name": "Park",
      "parentId": "root", "childIds": [], "orderIndex": 3, "isEnabled": true
    },
    "warm": {
      "id": "warm", "nodeType": "WarmCamera", "name": "Warm",
      "parentId": "root", "childIds": [], "orderIndex": 4, "isEnabled": true,
      "ratePerMin": 2.0, "targetTemp": 20.0
    }
  }
}
''';
