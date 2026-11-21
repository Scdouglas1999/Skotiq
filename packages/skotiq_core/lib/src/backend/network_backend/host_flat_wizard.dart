part of '../network_backend.dart';

/// A linked client's flat run. The imaging host exposes; this process only
/// submits the draft, cancels, and reads status and one preview.
mixin HostFlatWizard on NetworkBackendTransport {
  Future<Map<String, dynamic>> startFlatWizardRun(
    Map<String, dynamic> draft,
  ) => _post(FlatWizardApi.run, body: draft);

  Future<Map<String, dynamic>> cancelFlatWizardRun() =>
      _post(FlatWizardApi.cancelRun);

  Future<Map<String, dynamic>> getFlatWizardState() =>
      _get(FlatWizardApi.runState);

  Future<CapturedImageResult> getFlatWizardPreview(String key) async {
    final downloaded = await _downloadBytesWithHeaders(
      FlatWizardApi.preview,
      query: {'key': key},
    );
    final meta = _flatPreviewHeader(downloaded.headers, 'x-image-meta');
    if (meta == null || meta.isEmpty) {
      throw StateError('Flat preview metadata is missing');
    }
    return decodeRemoteJpegWire(jpegBytes: downloaded.bytes, metaHeaderBase64: meta);
  }
}

String? _flatPreviewHeader(Map<String, String> headers, String name) {
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}
