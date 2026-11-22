import '../../../models/flat_wizard/flat_run_snapshot.dart';
import '../../backend_provider.dart';
import '../../flat_wizard_provider.dart';
import '../runtime_mirror_channel.dart';

/// The imaging host's flat run, without the client's tabs.
///
/// Progress and the saved-frame list travel here. Preview pixels use the
/// bounded JPEG route. The client does not report its own wizard back, so
/// browsing tabs on the phone does not change the host's run.
class FlatWizardChannel extends RuntimeMirrorChannel<FlatRunSnapshot> {
  const FlatWizardChannel();

  @override
  String get key => 'flatWizard';

  @override
  get source => flatWizardSnapshotProvider;

  @override
  Map<String, dynamic> encode(FlatRunSnapshot value) => value.toJson();

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null ||
        !identical(context.networkBackend, context.read(backendProvider))) {
      return;
    }
    context
        .read(flatWizardProvider.notifier)
        .applyHostSnapshot(FlatRunSnapshot.fromJson(value));
  }
}
