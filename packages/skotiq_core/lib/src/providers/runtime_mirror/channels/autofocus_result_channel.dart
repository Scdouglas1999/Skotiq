import '../../../models/backend/autofocus_result.dart';
import '../../equipment/focuser_state_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// The last completed autofocus run. It is recorded by the process whose
/// operator started the run (the host's REST autofocus endpoint drives the
/// focuser natively and never sees it), so a client reports its result to the
/// host and a host result reaches every client.
class AutofocusResultChannel extends RuntimeMirrorChannel<AutofocusResult?> {
  const AutofocusResultChannel();

  @override
  String get key => 'autofocusResult';

  @override
  get source => autofocusResultProvider;

  @override
  bool get clientReports => true;

  /// A point with no measured HFR is not on the curve and is left out.
  @override
  Map<String, dynamic>? encode(AutofocusResult? value) {
    if (value == null) return null;
    return finiteJson({
      ...value.toJson(),
      'focusData': [
        for (final p in value.focusData)
          if (p.hfr.isFinite) p.toJson(),
      ],
    });
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    AutofocusResult? decoded;
    if (value != null) {
      try {
        decoded = AutofocusResult.fromJson(value);
      } on Object catch (e) {
        throw FormatException('Autofocus result could not be read: $e');
      }
    }
    context.read(autofocusResultProvider.notifier).state = decoded;
  }
}
