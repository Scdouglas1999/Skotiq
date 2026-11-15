import 'package:skotiq_core/models.dart';

/// Which altitude floor is in force, in a few words: the property horizon
/// when one is set, otherwise the minimum altitude.
String altitudeFloorRuleLabel(AltitudeFloor floor) => floor.followsHorizon
    ? 'Your horizon'
    : '${floor.minimumDeg.toStringAsFixed(0)}\u00B0 minimum';

/// Where the floor in force is set.
String altitudeFloorRuleDetail(AltitudeFloor floor) => floor.followsHorizon
    ? 'Targets are held to your horizon, direction by direction. Edit it '
        'in Settings > Location.'
    : 'No horizon is set, so targets are held to the minimum altitude. '
        'Edit it in Plan > Targets, Autopilot settings, or set a '
        'horizon in Settings > Location.';
