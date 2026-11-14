// Plugin management endpoints.
//
// Dart AOT builds cannot load an uploaded source/archive at runtime. The
// executable plugin set is therefore the set compiled into this Skotiq
// build and registered in PluginHost. These endpoints deliberately expose
// that live host state: enable/disable runs the real lifecycle hooks and saves
// the preference. Upload returns 501 instead of persisting an inert archive
// while claiming it was installed. Archives written by older builds remain
// visible as non-runnable rows and can be deleted for cleanup.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';

class PluginHandlers implements RouteSource {
  @override
  Map<ApiEndpoint, Function> get routes => {
    PluginApi.listPlugins: handleListPlugins,
    PluginApi.uploadPlugin: handleUploadPlugin,
    PluginApi.enablePlugin: handleEnablePlugin,
    PluginApi.disablePlugin: handleDisablePlugin,
    PluginApi.uninstallPlugin: handleUninstallPlugin,
  };

  final ProviderContainer container;

  PluginHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);
  PluginManagementService get _service =>
      container.read(pluginManagementServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'PluginHandlers');

  PluginHost get _host => container.read(pluginHostProvider);

  RemotePluginManifest _runtimeManifest(PluginInfo plugin) =>
      RemotePluginManifest(
        id: plugin.id,
        name: plugin.name,
        version: plugin.version,
        author: plugin.author,
        description: plugin.description,
        enabled: plugin.enabled,
        signed: false,
        signatureValid: false,
        installedAt: plugin.loadedAt.toUtc(),
        loadError: plugin.error,
        source: 'bundled',
        runtimeLoaded: true,
        canEnable: plugin.canEnable,
      );

  RemotePluginManifest _archivedManifest(InstalledPluginManifest plugin) =>
      RemotePluginManifest(
        id: plugin.id,
        name: plugin.name,
        version: plugin.version,
        author: plugin.author,
        description: plugin.description,
        // Older builds could persist uploads but never had an executable
        // loader. Never echo their persisted "enabled" preference as a
        // runtime claim.
        enabled: false,
        signed: plugin.signed,
        signatureValid: plugin.signatureValid,
        sha256: plugin.sha256,
        sizeBytes: plugin.sizeBytes,
        installedAt: plugin.installedAt,
        installedFilename: plugin.installedFilename,
        loadError:
            plugin.loadError ??
            'This archive is stored for cleanup only. This Skotiq build '
                'cannot load Dart plugins at runtime.',
        source: 'uploadedArchive',
        runtimeLoaded: false,
        canEnable: false,
      );

  /// GET /api/plugins
  Future<Response> handleListPlugins(Request request) async {
    final runtimePlugins = _host.pluginInfo;
    final runtimeIds = runtimePlugins.map((plugin) => plugin.id).toSet();
    final archivedPlugins = await _service.listPlugins();
    final items = <RemotePluginManifest>[
      for (final plugin in runtimePlugins) _runtimeManifest(plugin),
      // If an obsolete archive collides with a bundled id, the live host row
      // is authoritative. DELETE still removes that archive by id.
      for (final plugin in archivedPlugins)
        if (!runtimeIds.contains(plugin.id)) _archivedManifest(plugin),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return jsonOk({
      'items': [for (final item in items) item.toJson()],
      'total': items.length,
      'capabilities': {
        'runtimeUpload': false,
        'enableBundled': true,
        'removeArchivedUploads': true,
      },
    });
  }

  /// POST /api/plugins/upload?filename=&sha256=
  ///
  /// Runtime installation is unavailable in Dart AOT builds. Keep the route
  /// for protocol compatibility, but fail before consuming or persisting the
  /// body so clients cannot mistake archive storage for executable install.
  Future<Response> handleUploadPlugin(Request request) async {
    _logInfo('[API] POST /api/plugins/upload');
    return jsonNotImplemented({
      'error': 'runtime_plugin_install_unavailable',
      'message':
          'This Skotiq build cannot load uploaded Dart plugins. Plugins '
          'must be compiled into the application; no file was stored.',
    });
  }

  /// POST `/api/plugins/<id>/enable`
  Future<Response> handleEnablePlugin(Request request, String pluginId) async {
    _logInfo('[API] POST /api/plugins/$pluginId/enable');
    return _setEnabled(pluginId, true);
  }

  /// POST `/api/plugins/<id>/disable`
  Future<Response> handleDisablePlugin(Request request, String pluginId) async {
    _logInfo('[API] POST /api/plugins/$pluginId/disable');
    return _setEnabled(pluginId, false);
  }

  Future<Response> _setEnabled(String pluginId, bool enabled) async {
    if (pluginId.trim().isEmpty) {
      throw BadRequestError(field: 'pluginId', expected: 'non-empty string');
    }

    final host = _host;
    if (!host.isLoaded(pluginId)) {
      final archived = await _service.getManifest(pluginId);
      if (archived != null) {
        return jsonConflict({
          'error': 'archived_plugin_not_runnable',
          'pluginId': pluginId,
          'message':
              'This is an archive left by an older build, not a loaded '
              'plugin. It cannot be enabled.',
        });
      }
      return jsonNotFound({'error': 'plugin_not_found', 'pluginId': pluginId});
    }

    try {
      // Await initial persisted state before mutating it. The notifier drives
      // PluginHost first, persists second, and rolls the host back if saving
      // fails, so the response cannot report a state the runtime did not enter.
      await container.read(pluginEnablementProvider.future);
      await container
          .read(pluginEnablementProvider.notifier)
          .setEnabled(pluginId, enabled);
      final plugin = host.pluginInfo.firstWhere((item) => item.id == pluginId);
      return jsonOk({
        'status': enabled ? 'enabled' : 'disabled',
        'manifest': _runtimeManifest(plugin).toJson(),
      });
    } catch (error) {
      return jsonConflict({
        'error': 'plugin_state_change_failed',
        'pluginId': pluginId,
        'message': error.toString(),
      });
    }
  }

  /// DELETE `/api/plugins/<id>`. Bundled executable plugins cannot be
  /// uninstalled from a running AOT build; this route only removes obsolete
  /// uploaded archives left by the earlier inert management implementation.
  Future<Response> handleUninstallPlugin(
    Request request,
    String pluginId,
  ) async {
    _logInfo('[API] DELETE /api/plugins/$pluginId');
    if (pluginId.trim().isEmpty) {
      throw BadRequestError(field: 'pluginId', expected: 'non-empty string');
    }
    try {
      await _service.uninstall(pluginId);
      return jsonOk({'status': 'archive_removed', 'pluginId': pluginId});
    } on PluginNotFoundException {
      if (_host.isLoaded(pluginId)) {
        return jsonConflict({
          'error': 'bundled_plugin_cannot_be_uninstalled',
          'pluginId': pluginId,
          'message':
              'Bundled plugins are part of this application build. Disable '
              'the plugin instead, or install a build that omits it.',
        });
      }
      return jsonNotFound({'error': 'plugin_not_found', 'pluginId': pluginId});
    }
  }
}
