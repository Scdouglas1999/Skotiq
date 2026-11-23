import '../../../services/centering_service.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';
import '../../centering_run.dart';
import '../../centering_service_providers.dart';

/// Progress of a centering run (state, attempt, offset). Centering is a loop
/// in the process whose operator started it, so a run started on a client is
/// reported to the host and one started on the host reaches every client.
class CenteringStatusChannel extends RuntimeMirrorChannel<CenteringStatus> {
  const CenteringStatusChannel();

  @override
  String get key => 'centeringStatus';

  @override
  get source => centeringStatusProvider;

  @override
  Duration get minInterval => const Duration(milliseconds: 250);

  @override
  bool get clientReports => true;

  @override
  Map<String, dynamic>? encode(CenteringStatus value) =>
      finiteJson(value.toJson());

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    context
        .read(centeringRunProvider)
        .adoptStatus(
          value == null
              ? CenteringStatus.idle()
              : CenteringStatus.fromJson(value),
        );
  }
}

/// The outcome of the last centering run, which the Solve tab's recent-solves
/// list and the centering dialog show.
class CenteringResultChannel extends RuntimeMirrorChannel<CenteringResult?> {
  const CenteringResultChannel();

  @override
  String get key => 'centeringResult';

  @override
  get source => lastCenteringResultProvider;

  @override
  bool get clientReports => true;

  @override
  Map<String, dynamic>? encode(CenteringResult? value) =>
      value == null ? null : finiteJson(value.toJson());

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    context
        .read(centeringRunProvider)
        .adoptResult(value == null ? null : CenteringResult.fromJson(value));
  }
}
