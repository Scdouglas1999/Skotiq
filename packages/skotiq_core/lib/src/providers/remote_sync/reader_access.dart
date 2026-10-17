part of '../remote_sync_handler.dart';

T _read<T>(Object reader, ProviderListenable<T> provider) =>
    readProvider(reader, provider);

bool _isCurrentRemoteBackend(Object reader, NetworkBackend backend) {
  try {
    return identical(_read(reader, backendProvider), backend);
  } catch (_) {
    return false;
  }
}

void _invalidate(Object reader, ProviderOrFamily provider) =>
    invalidateProvider(reader, provider);
