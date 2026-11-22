import '../../../models/autofocus_progress.dart';
import '../../../models/backend/autofocus_result.dart';
import '../../autofocus_progress_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';
import 'autofocus_result_channel.dart';

/// The current sweep and its last outcome, including the curve a viewer needs
/// when it joins after the first progress event. Panel visibility stays on
/// the window that opened it.
class AutofocusRunChannel extends RuntimeMirrorChannel<AutofocusOverlayState> {
  const AutofocusRunChannel();

  @override
  String get key => 'autofocusRun';

  @override
  get source => autofocusOverlayProvider;

  @override
  bool get clientReports => true;

  @override
  Map<String, dynamic>? encode(AutofocusOverlayState value) {
    return {
      'running': value.isRunning,
      'currentPoint': value.currentPoint,
      'totalPoints': value.totalPoints,
      'currentHfr': finiteOrNull(value.currentHfr),
      'bestHfr': finiteOrNull(value.bestHfr),
      'starCount': value.starCount,
      'status': value.status,
      'vcurvePoints': [
        for (final point in value.vcurvePoints)
          if (finiteOrNull(point.hfr) != null)
            {
              'position': point.position,
              'hfr': point.hfr,
              'star_count': point.starCount,
              if (point.rejectedReason != null)
                'rejected': point.rejectedReason,
            },
      ],
      'focusRange': value.focusRange == null
          ? null
          : {'min': value.focusRange!.min, 'max': value.focusRange!.max},
      // Crops ride this snapshot only. A progress event is one measurement
      // and must not carry the pixels.
      'starCrops': [
        for (final crop in value.starCrops)
          if (finiteOrNull(crop.hfr) != null && finiteOrNull(crop.snr) != null)
            {
              'pixels_base64': crop.pixelsBase64,
              'width': crop.width,
              'height': crop.height,
              'hfr': crop.hfr,
              'snr': crop.snr,
            },
      ],
      if (!value.isRunning && value.result != null) ...{
        'outcome': 'completed',
        'result': const AutofocusResultChannel().encode(value.result),
      } else if (value.hasError)
        'outcome': 'failed'
      else if (value.cancelled)
        'outcome': 'cancelled',
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null) return;
    final overlay = context.read(autofocusOverlayProvider.notifier);
    if (context.networkBackend != null && value.containsKey('currentPoint')) {
      // Progress is produced on the host. A client report only settles a run;
      // applying it here would move the host back to an older point.
      overlay.applyHostState(_overlayFromSnapshot(value));
      return;
    }
    if (value['running'] == true) return;
    if (!context.read(autofocusOverlayProvider).isRunning) return;
    switch (value['outcome']) {
      case 'completed':
        final raw = value['result'];
        AutofocusResult? result;
        if (raw is Map) {
          try {
            result = AutofocusResult.fromJson(Map<String, dynamic>.from(raw));
          } on Object {
            result = null;
          }
        }
        if (result != null) {
          overlay.onAutofocusCompleted(result);
        } else {
          overlay.onAutofocusFailed('Autofocus finished without a result');
        }
      case 'failed':
        final status = jsonString(value['status']);
        overlay.onAutofocusFailed(
          status == null
              ? 'Autofocus failed'
              : status.startsWith('Failed: ')
              ? status.substring(8)
              : status,
        );
      case 'cancelled':
        overlay.onAutofocusCancelled();
    }
  }
}

AutofocusOverlayState _overlayFromSnapshot(Map<String, dynamic> value) {
  final range = value['focusRange'];
  final minPosition = range is Map ? jsonInt(range['min']) : null;
  final maxPosition = range is Map ? jsonInt(range['max']) : null;
  final result = value['result'];
  final points = <VCurvePoint>[];
  final rawPoints = value['vcurvePoints'];
  if (rawPoints is List) {
    for (final raw in rawPoints) {
      if (raw is! Map) continue;
      final position = jsonInt(raw['position']);
      final hfr = jsonDouble(raw['hfr']);
      if (position == null || hfr == null || !hfr.isFinite) continue;
      final rejected = raw['rejected'];
      points.add(
        VCurvePoint(
          position: position,
          hfr: hfr,
          starCount: jsonInt(raw['star_count']),
          rejectedReason: rejected is String && rejected.isNotEmpty
              ? rejected
              : null,
        ),
      );
    }
  }
  final crops = <StarCrop>[];
  final rawCrops = value['starCrops'];
  if (rawCrops is List) {
    for (final raw in rawCrops) {
      if (raw is! Map) continue;
      final pixels = jsonString(raw['pixels_base64']);
      final width = jsonInt(raw['width']);
      final height = jsonInt(raw['height']);
      final hfr = jsonDouble(raw['hfr']);
      final snr = jsonDouble(raw['snr']);
      if (pixels == null ||
          width == null ||
          height == null ||
          hfr == null ||
          snr == null ||
          !hfr.isFinite ||
          !snr.isFinite) {
        continue;
      }
      crops.add(
        StarCrop(
          pixelsBase64: pixels,
          width: width,
          height: height,
          hfr: hfr,
          snr: snr,
        ),
      );
    }
  }
  AutofocusResult? parsed;
  if (result is Map) {
    try {
      parsed = AutofocusResult.fromJson(Map<String, dynamic>.from(result));
    } on Object {
      parsed = null;
    }
  }
  return AutofocusOverlayState(
    isRunning: value['running'] == true,
    currentPoint: jsonInt(value['currentPoint']) ?? 0,
    totalPoints: jsonInt(value['totalPoints']) ?? 0,
    currentHfr: jsonDouble(value['currentHfr']) ?? 0,
    bestHfr: jsonDouble(value['bestHfr']) ?? 0,
    starCount: jsonInt(value['starCount']) ?? 0,
    status: jsonString(value['status']) ?? '',
    hasError: value['outcome'] == 'failed',
    cancelled: value['outcome'] == 'cancelled',
    result: parsed,
    focusRange: minPosition != null && maxPosition != null
        ? FocusRange(min: minPosition, max: maxPosition)
        : null,
    vcurvePoints: points,
    starCrops: crops,
  );
}
