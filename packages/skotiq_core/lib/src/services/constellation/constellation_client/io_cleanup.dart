part of '../constellation_client.dart';

/// Close [sink] while already unwinding a download failure: the stream
/// consumer has usually torn the file handle down itself, and a secondary
/// close error must not mask the real cause.
Future<void> _closeQuietly(IOSink sink) async {
  try {
    await sink.close();
  } on Object {
    // Already failing; the original error is the one worth reporting.
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // Best-effort cleanup; the caller's error still propagates.
  }
}
