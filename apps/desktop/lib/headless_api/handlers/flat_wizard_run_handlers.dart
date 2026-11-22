part of 'flat_wizard_handlers.dart';

/// Host-side flat run: one draft, one capture, a small status snapshot, and
/// one bounded preview. The run stays on this process after the response.
extension FlatWizardRunHandlers on FlatWizardHandlers {
  static const int _previewMaxEdge = 1600;
  static const int _maxGain = 65535;

  Future<Response> handleGetRunState(Request request) async =>
      jsonOk(container.read(flatWizardSnapshotProvider).toJson());

  Future<Response> handleStartRun(Request request) async {
    final payload = await readJsonObject(request);
    final draft = _readRunDraft(payload);
    final notifier = container.read(flatWizardProvider.notifier);
    final blocked = notifier.startBlockReason;
    if (blocked != null) {
      return jsonConflict({'error': 'rig_busy', 'message': blocked});
    }
    final camera = container.read(cameraStateProvider);
    if (camera.connectionState != DeviceConnectionState.connected ||
        camera.deviceId == null) {
      return jsonConflict({
        'error': 'camera_not_connected',
        'message': 'Connect a camera before starting flats',
      });
    }

    final savePath = await _resolveRunFolder(draft.globalSettings.savePath);

    // The folder check awaited. The camera can have gone away in that time.
    final live = container.read(cameraStateProvider);
    if (live.connectionState != DeviceConnectionState.connected ||
        live.deviceId != camera.deviceId) {
      return jsonConflict({
        'error': 'camera_not_connected',
        'message': 'Connect a camera before starting flats',
      });
    }

    if (draft.mode != FlatWizardMode.quick &&
        draft.filterSettings.where((f) => f.enabled).length > 1 &&
        container.read(filterWheelStateProvider).connectionState !=
            DeviceConnectionState.connected) {
      return jsonConflict({
        'error': 'filter_wheel_not_connected',
        'message': 'Connect a filter wheel to capture several filters.',
      });
    }
    // startHostRun checks every ownership latch synchronously before it runs.
    final accepted = notifier.startHostRun(
      draft.copyWith(
        globalSettings: draft.globalSettings.copyWith(savePath: savePath),
      ),
    );
    if (!accepted) {
      return jsonConflict({
        'error': 'rig_busy',
        'message': notifier.startBlockReason ?? 'A flat run is already active',
      });
    }
    return jsonOk({
      ...container.read(flatWizardSnapshotProvider).toJson(),
      'busy': notifier.isBusy,
    });
  }

  Future<Response> handleCancelRun(Request request) async {
    container.read(flatWizardProvider.notifier).requestCancel();
    return jsonOk(container.read(flatWizardSnapshotProvider).toJson());
  }

  Future<Response> handleGetPreview(Request request) async {
    final image = container.read(flatWizardProvider).lastImageData;
    final key = request.url.queryParameters['key'];
    if (image is! CapturedImageResult ||
        key == null ||
        image.timestamp != key) {
      return jsonNotFound({
        'error': 'Flat preview has changed or is unavailable',
      });
    }
    // Bounded JPEG. Width and height in the meta header stay the sensor's;
    // the client spreads the smaller bitmap back onto that grid.
    final encoded = await encodeCapturedImageDisplayBufferToJpeg(
      image,
      maxWidth: _previewMaxEdge,
      maxHeight: _previewMaxEdge,
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

  Future<String> _resolveRunFolder(String? chosen) async {
    final files = FileSystemHandlers(container);
    Future<String> check(String path, {required bool mustExist}) async {
      final verdict = await files.checkHostDirectory(
        path,
        mustExist: mustExist,
        mustBeWritable: mustExist,
      );
      if (verdict.statusCode == 403) {
        throw HandlerFailure(
          code: 'path_not_allowed',
          statusCode: 403,
          message: verdict.body['message'] as String,
        );
      }
      if (verdict.body['valid'] != true) {
        throw BadRequestError(
          field: 'savePath',
          expected: 'writable host directory',
        );
      }
      return verdict.body['normalizedPath'] as String;
    }

    if (chosen != null) return check(chosen.trim(), mustExist: true);
    final settings = await container.read(appSettingsProvider.future);
    final capture = await check(
      settings.imageOutputPath.trim(),
      mustExist: true,
    );
    final flats = await check(
      defaultFlatFolder(capture, onHost: false)!,
      mustExist: false,
    );
    // Capture creates a missing Flats directory on first use. An existing
    // folder must itself be writable even if its parent passed the check.
    if (await FileSystemEntity.type(flats, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return check(flats, mustExist: true);
    }
    return flats;
  }

  FlatWizardState _readRunDraft(Map<String, dynamic> body) {
    final global = requireObject(body, 'globalSettings');
    final filters = requireList<Map<String, dynamic>>(body, 'filterSettings');
    if (filters.isEmpty) {
      throw BadRequestError(
        field: 'filterSettings',
        expected: 'at least one filter',
      );
    }
    final selected =
        optionalInt(
          body,
          'currentFilterIndex',
          min: 0,
          max: filters.length - 1,
        ) ??
        0;
    final settings = _readGlobalSettings(global);
    final positions = <int>{};
    final rows = <FlatFilterSettings>[];
    for (final filter in filters) {
      final position = requireInt(filter, 'filterPosition', min: 0);
      if (!positions.add(position)) {
        throw BadRequestError(
          field: 'filterPosition',
          expected: 'unique filter position',
        );
      }
      final fmin = _readExposure(filter, 'minExposureOverride');
      final fmax = _readExposure(filter, 'maxExposureOverride');
      if ((fmin ?? settings.minExposure) > (fmax ?? settings.maxExposure)) {
        throw BadRequestError(
          field: 'maxExposureOverride',
          expected: 'at least the effective minimum exposure',
        );
      }
      rows.add(
        FlatFilterSettings(
          filterName: requireString(filter, 'filterName', allowEmpty: true),
          filterPosition: position,
          enabled: optionalBool(filter, 'enabled') ?? true,
          gainOverride: optionalInt(
            filter,
            'gainOverride',
            min: 0,
            max: _maxGain,
          ),
          offsetOverride: optionalInt(
            filter,
            'offsetOverride',
            min: 0,
            max: _maxGain,
          ),
          histogramTargetOverride: optionalDouble(
            filter,
            'histogramTargetOverride',
            min: 0,
            max: 100,
          ),
          toleranceOverride: optionalDouble(
            filter,
            'toleranceOverride',
            min: 1,
            max: 25,
          ),
          frameCountOverride: optionalInt(
            filter,
            'frameCountOverride',
            min: 1,
            max: 999,
          ),
          minExposureOverride: fmin,
          maxExposureOverride: fmax,
          suggestedExposure: _readExposure(filter, 'suggestedExposure'),
        ),
      );
    }
    // Only operator selections travel from client to host. Progress, counts
    // and previous results belong to the host.
    final draft = FlatWizardState(
      mode: _readMode(
        body,
        'mode',
        FlatWizardMode.values,
        FlatWizardMode.quick,
      ),
      twilightMode: _readMode(
        body,
        'twilightMode',
        TwilightMode.values,
        TwilightMode.dusk,
      ),
      globalSettings: settings,
      filterSettings: rows,
      currentFilterIndex: selected,
    );
    if (draft.mode != FlatWizardMode.quick && !rows.any((row) => row.enabled)) {
      throw BadRequestError(
        field: 'filterSettings',
        expected: 'at least one enabled filter',
      );
    }
    return draft;
  }

  FlatWizardGlobalSettings _readGlobalSettings(Map<String, dynamic> global) {
    const defaults = FlatWizardGlobalSettings();
    final min = _readExposure(global, 'minExposure') ?? defaults.minExposure;
    final max = _readExposure(global, 'maxExposure') ?? defaults.maxExposure;
    if (min > max) {
      throw BadRequestError(
        field: 'maxExposure',
        expected: 'at least minExposure',
      );
    }
    return FlatWizardGlobalSettings(
      minExposure: min,
      maxExposure: max,
      gain: optionalInt(global, 'gain', min: 0, max: _maxGain) ?? defaults.gain,
      frameCount:
          optionalInt(global, 'frameCount', min: 1, max: 999) ??
          defaults.frameCount,
      binning:
          optionalInt(
            global,
            'binning',
            min: 1,
            max: FlatWizardHandlers._maxBinning,
          ) ??
          defaults.binning,
      histogramTarget:
          optionalDouble(global, 'histogramTarget', min: 0, max: 100) ??
          defaults.histogramTarget,
      tolerancePercent:
          optionalDouble(global, 'tolerancePercent', min: 1, max: 25) ??
          defaults.tolerancePercent,
      savePath: optionalString(global, 'savePath'),
      createDateSubfolder:
          optionalBool(global, 'createDateSubfolder') ??
          defaults.createDateSubfolder,
      createFilterSubfolders:
          optionalBool(global, 'createFilterSubfolders') ??
          defaults.createFilterSubfolders,
      imageDownloadTimeoutSeconds:
          optionalInt(
            global,
            'imageDownloadTimeoutSeconds',
            min: 1,
            // Duration represents microseconds as a signed native integer.
            max: 0x7fffffffffffffff ~/ Duration.microsecondsPerSecond,
          ) ??
          defaults.imageDownloadTimeoutSeconds,
    );
  }

  T _readMode<T extends Enum>(
    Map<String, dynamic> fields,
    String field,
    List<T> values,
    T fallback,
  ) {
    final name = optionalString(fields, field);
    if (name == null) return fallback;
    return values.asNameMap()[name] ??
        (throw BadRequestError(
          field: field,
          expected: values.map((v) => v.name).join(' or '),
        ));
  }

  double? _readExposure(Map<String, dynamic> data, String key) {
    final value = optionalDouble(
      data,
      key,
      max: FlatWizardHandlers._maxExposureSeconds,
    );
    if (value != null && value <= 0) {
      throw BadRequestError(
        field: key,
        expected: 'positive exposure in seconds',
      );
    }
    return value;
  }
}
