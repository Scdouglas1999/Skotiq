import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../services/transient_alert_service.dart';
import 'logging_service_provider.dart';

final transientAlertServiceProvider = Provider<TransientAlertService>((ref) {
  final logger = ref.watch(loggingServiceProvider);
  final service = TransientAlertService(
    httpClient: http.Client(),
    logger: logger,
  );

  ref.onDispose(() {
    service.dispose();
  });

  return service;
});
