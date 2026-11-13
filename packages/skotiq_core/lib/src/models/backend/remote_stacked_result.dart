import '../imaging/stack_and_share_models.dart';

/// Sanitized durable Stack-and-Share record returned by an imaging host.
///
/// [result.exportedImagePath] is always null: host filesystem paths never cross
/// the remote boundary. [previewAvailable] tells the client whether the
/// authenticated binary preview endpoint can supply pixels.
class RemoteStackedResult {
  final StackAndShareResult result;
  final bool previewAvailable;

  const RemoteStackedResult({
    required this.result,
    required this.previewAvailable,
  });
}
