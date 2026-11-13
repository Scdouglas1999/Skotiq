import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/plugin_management_service.dart';
import 'logging_service_provider.dart';

/// Riverpod provider for [PluginManagementService]. The directory
/// override is null in production; tests inject a temp directory via
/// `overrideWithProvider`/`overrideWith`.
final pluginManagementServiceProvider = Provider<PluginManagementService>((
  ref,
) {
  return PluginManagementService(logger: ref.watch(loggingServiceProvider));
});
