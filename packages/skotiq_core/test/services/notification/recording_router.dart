import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

/// A transport that keeps what it was handed instead of sending it.
class RecordingTransport extends NotificationTransport {
  RecordingTransport(this.kind);

  @override
  final NotificationTransportKind kind;

  final sent = <NotificationMessage>[];

  @override
  String get name => kind.label;

  @override
  bool get isConfigured => true;

  @override
  Future<NotificationResult> send(NotificationMessage message) async {
    sent.add(message);
    return NotificationResult.ok();
  }
}

/// A router over one [RecordingTransport] per kind in [kinds], with every
/// row of the matrix routed to all of them.
({
  NotificationRouter router,
  Map<NotificationTransportKind, RecordingTransport> transports,
})
recordingRouter({
  List<NotificationTransportKind> kinds = const [
    NotificationTransportKind.inApp,
  ],
}) {
  final transports = {for (final kind in kinds) kind: RecordingTransport(kind)};
  final router = NotificationRouter(
    transports: transports.values.toList(),
    matrix: NotificationRoutingMatrix(
      rules: {
        for (final category in NotificationCategory.values)
          category: NotificationRoutingRule(transports: kinds),
      },
    ),
  );
  return (router: router, transports: transports);
}
