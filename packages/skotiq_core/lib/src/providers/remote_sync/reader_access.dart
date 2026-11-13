part of '../remote_sync_handler.dart';

bool _isCurrentRemoteBackend(ProviderContainer container, SkotiqBackend backend) {
  try {
    return identical(container.read(backendProvider), backend);
  } catch (_) {
    return false;
  }
}
