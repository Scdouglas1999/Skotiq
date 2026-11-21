part of 'flat_wizard_handlers.dart';

/// Host-side flat run: one draft, one capture, a small status snapshot, and
/// one bounded preview. The run stays on this process after the response.
class FlatWizardRunHandlers {
  FlatWizardRunHandlers(this.container);

  final ProviderContainer container;

  static const int _previewMaxWidth = 1600;
  static const int _maxGain = 65535;

  Future<Response> handleGetRunState(Request request) async =>
      jsonOk(container.read(flatWizardSnapshotProvider));

  Future<Response> handleStartRun(Request request) async {
    final payload = await readJsonObject(request);
    final FlatWizardState draft;
    try {
      draft = FlatWizardState.fromJson(payload);
    } on Object {
      throw BadRequestError(
        field: 'body',
        expected: 'flat wizard draft',
      );
    }
    _validateDraft(draft);

    final camera = container.read(cameraStateProvider);
    if (camera.connectionState != DeviceConnectionState.connected ||
        camera.deviceId == null) {
      return jsonConflict({
        'error': 'camera_not_connected',
        'message': 'Connect a camera before starting flats',
      });
    }

    final requested = draft.globalSettings.savePath!.trim();
    final verdict = await FileSystemHandlers(container).checkHostDirectory(
      requested,
      mustExist: true,
      mustBeWritable: true,
    );
    if (verdict.statusCode == 403) return jsonForbidden(verdict.body);
    if (verdict.body['valid'] != true) {
      final detail = verdict.body['error'];
      throw BadRequestError(
        field: 'savePath',
        expected: 'writable host folder',
        message: detail is String && detail.isNotEmpty
            ? detail
            : 'The flat folder is not usable on this host',
      );
    }
    final normalized = verdict.body['normalizedPath'];
    final savePath = normalized is String && normalized.isNotEmpty
        ? normalized
        : requested;

    // The folder check awaited. The camera can have gone away in that time.
    final live = container.read(cameraStateProvider);
    if (live.connectionState != DeviceConnectionState.connected ||
        live.deviceId == null) {
      return jsonConflict({
        'error': 'camera_not_connected',
        'message': 'Connect a camera before starting flats',
      });
    }

    final notifier = container.read(flatWizardProvider.notifier);
    // One run owns the camera. A second start is a conflict and does not
    // enter runCapture.
    final accepted = notifier.startHostRun(
      draft.copyWith(
        globalSettings: draft.globalSettings.copyWith(savePath: savePath),
      ),
    );
    if (!accepted) {
      return jsonConflict({
        'error': 'flat_run_active',
        'message': 'A flat run is already active',
      });
    }
    return jsonOk({
      ...container.read(flatWizardSnapshotProvider),
      'busy': notifier.isBusy,
    });
  }

  Future<Response> handleCancelRun(Request request) async {
    container.read(flatWizardProvider.notifier).requestCancel();
    return jsonOk(container.read(flatWizardSnapshotProvider));
  }

  Future<Response> handleGetPreview(Request request) async {
    final image = container.read(flatWizardProvider).lastImageData;
    final key = request.url.queryParameters['key'];
    if (image is! CapturedImageResult || key == null || image.timestamp != key) {
      return jsonNotFound({
        'error': 'Flat preview has changed or is unavailable',
      });
    }
    // Bounded JPEG. Width and height in the meta header stay the sensor's;
    // the client spreads the smaller bitmap back onto that grid.
    final encoded = await encodeCapturedImageDisplayBufferToJpeg(
      image,
      maxWidth: _previewMaxWidth,
      quality: 85,
    );
    if (encoded == null) {
      return jsonInternalServerError({'error': 'Invalid flat preview buffer'});
    }
    return contentResponse(
      encoded.bytes,
      contentType: 'image/jpeg',
      headers: {
        'cache-control': 'no-store',
        'x-image-meta': encoded.metaHeaderValue,
      },
    );
  }

  void _validateDraft(FlatWizardState state) {
    final global = state.globalSettings;
    final savePath = global.savePath?.trim() ?? '';
    if (savePath.isEmpty) {
      throw BadRequestError(
        field: 'savePath',
        expected: 'host output directory',
      );
    }
    _exposureRange('minExposure', global.minExposure, 0, _maxExposure);
    if (global.minExposure <= 0) {
      throw BadRequestError(
        field: 'minExposure',
        expected: 'number',
        message: 'minExposure must be greater than 0',
      );
    }
    _exposureRange(
      'maxExposure',
      global.maxExposure,
      global.minExposure,
      _maxExposure,
    );
    _gainRange('gain', global.gain);

    if (state.filterSettings.isEmpty) {
      throw BadRequestError(
        field: 'filterSettings',
        expected: 'at least one filter',
      );
    }
    final positions = <int>{};
    for (final filter in state.filterSettings) {
      if (filter.filterPosition < 0 || !positions.add(filter.filterPosition)) {
        throw BadRequestError(
          field: 'filterSettings',
          expected: 'unique filter positions',
        );
      }
      if (filter.gainOverride != null) {
        _gainRange('gainOverride', filter.gainOverride!);
      }
      if (filter.offsetOverride != null) {
        _gainRange('offsetOverride', filter.offsetOverride!);
      }
      final min = filter.minExposureOverride ?? global.minExposure;
      final max = filter.maxExposureOverride ?? global.maxExposure;
      if (filter.minExposureOverride != null) {
        _exposureRange('minExposureOverride', min, 0, _maxExposure);
        if (min <= 0) {
          throw BadRequestError(
            field: 'minExposureOverride',
            expected: 'number',
            message: 'minExposureOverride must be greater than 0',
          );
        }
      }
      _exposureRange('maxExposureOverride', max, min, _maxExposure);
    }
  }

  static const double _maxExposure = FlatWizardHandlers._maxExposureSeconds;

  void _exposureRange(String field, double value, num min, num max) {
    if (!value.isFinite || value < min || value > max) {
      throw BadRequestError(field: field, expected: 'finite $min–$max');
    }
  }

  void _gainRange(String field, int value) {
    if (value < 0 || value > _maxGain) {
      throw BadRequestError(field: field, expected: '0–$_maxGain');
    }
  }
}
