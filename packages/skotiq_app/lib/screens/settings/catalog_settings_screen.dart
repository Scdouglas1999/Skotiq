import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:file_selector/file_selector.dart';

import '../../utils/confirm_dialog.dart';
import '../../utils/snackbar_helper.dart';
import 'widgets/deep_star_catalog_card.dart';
import 'widgets/element_refresh_card.dart';
import 'widgets/settings_widgets.dart' show settingsPagePadding;

part 'catalog_settings_screen/card_builders.dart';

part 'catalog_settings_screen/view_builders.dart';

/// Log `source` for every catalog outcome, so Settings > Logs can be filtered
/// to the catalog subsystem and an exported log can be grepped for it.
const String _logSource = 'CatalogSettings';

typedef CatalogCsvPicker = Future<XFile?> Function(String confirmButtonText);
typedef CatalogCsvImporter = Future<bool> Function(
  String sourcePath,
  String type,
);
typedef AnnotationCatalogCsvImporter = Future<bool> Function(
  String sourcePath,
);

Future<XFile?> _pickCatalogCsv(String confirmButtonText) {
  const csvGroup = XTypeGroup(
    label: 'CSV files',
    extensions: ['csv'],
  );
  return openFile(
    acceptedTypeGroups: [csvGroup],
    confirmButtonText: confirmButtonText,
  );
}

final catalogCsvPickerProvider =
    Provider<CatalogCsvPicker>((ref) => _pickCatalogCsv);

final catalogCsvImporterProvider = Provider<CatalogCsvImporter>((ref) {
  return (sourcePath, type) => CatalogManager.instance.importCatalog(
        sourcePath: sourcePath,
        type: type,
      );
});

final annotationCatalogCsvImporterProvider =
    Provider<AnnotationCatalogCsvImporter>((ref) {
  return (sourcePath) => CatalogManager.instance.importAnnotationCatalog(
        sourcePath: sourcePath,
        package: AnnotationPackage.standard,
      );
});

final catalogDeleteActionProvider = Provider<Future<void> Function()>(
  (ref) => CatalogManager.instance.deleteCatalogs,
);

final annotationCatalogDeleteActionProvider = Provider<Future<void> Function()>(
  (ref) => CatalogManager.instance.deleteAnnotationCatalog,
);

/// Screen for managing astronomical catalog downloads and settings
class CatalogSettingsScreen extends ConsumerStatefulWidget {
  final bool isMobile;

  const CatalogSettingsScreen({super.key, this.isMobile = false});

  @override
  ConsumerState<CatalogSettingsScreen> createState() =>
      _CatalogSettingsScreenState();
}

class _CatalogSettingsScreenState extends ConsumerState<CatalogSettingsScreen>
    with _CatalogCardBuilders {
  CatalogStatus? _starStatus;
  CatalogStatus? _dsoStatus;
  CatalogStatus? _annotationStatus;
  bool _isLoading = true;

  /// Catalogs installed on the connected appliance, when this app is driving a
  /// remote backend. The cards above read the LOCAL filesystem, which on a
  /// paired phone says nothing about the machine that actually runs plate
  /// solving, target search, framing and annotation.
  RemoteCatalogStatusResponse? _rigCatalogs;
  String? _rigCatalogError;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  /// UI flag the card builders read to disable controls. Derived from both a
  /// locally-running download/import method and the manager's in-flight
  /// registry (see [_recomputeDownloading]), so it stays correct even when a
  /// download was started by a previous instance of this screen.
  @override
  bool _isDownloading = false;

  /// True while one of this screen's own download/import methods is awaiting.
  bool _methodRunning = false;
  int _importGeneration = 0;
  int _statusGeneration = 0;
  bool _deleteConfirmationOpen = false;
  _CatalogDeleteTarget? _deleteTarget;

  bool get _isDeleting => _deleteTarget != null;

  /// Set when the user taps Cancel; polled by the in-flight download.
  bool _cancelRequested = false;
  String _downloadStatus = '';
  double _downloadProgress = 0;
  String _currentDownload = '';

  /// The single dataset every install delivers. There is no tier to pick —
  /// see [CatalogPackage]; the selector that used to set this downloaded the
  /// same bytes whichever option was clicked.
  static const CatalogPackage _installedPackage = CatalogPackage.complete;
  AnnotationPackage _selectedAnnotationPackage = AnnotationPackage.standard;

  StreamSubscription<DownloadProgress>? _progressSub;

  /// Captured once so a failure that lands after this screen is disposed still
  /// reaches the log. Every catalog outcome the user sees has to leave a
  /// record: a session that failed five downloads reported "1 error all night"
  /// in Settings > Logs and in the exported log file, because this screen
  /// snackbarred its exceptions and logged nothing.
  late final LoggingService _logger;

  @override
  void initState() {
    super.initState();
    _logger = ref.read(loggingServiceProvider);
    // Restore the live progress bar if a download is already running (e.g. the
    // user navigated away and came back) and follow it for the rest of its run.
    final active = CatalogManager.instance.activeDownloads;
    if (active.isNotEmpty) {
      final p = active.values.first;
      _currentDownload = p.catalogName;
      _downloadProgress = p.progress;
      _downloadStatus = p.status;
    }
    _recomputeDownloading();
    _progressSub =
        CatalogManager.instance.downloadProgress.listen(_onDownloadProgress);
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next) || !mounted) return;
        setState(() {
          _rigCatalogs = null;
          _rigCatalogError = null;
        });
        unawaited(_loadCatalogStatus());
      },
    );
    _loadCatalogStatus();
  }

  @override
  void dispose() {
    _statusGeneration++;
    _progressSub?.cancel();
    _backendSubscription?.close();
    super.dispose();
  }

  /// Recompute [_isDownloading] from the two things that can keep a download
  /// alive: a method running on this screen, or any download in the manager's
  /// registry (which outlives this widget).
  void _recomputeDownloading() {
    _isDownloading =
        _methodRunning || CatalogManager.instance.activeDownloads.isNotEmpty;
  }

  void _onDownloadProgress(DownloadProgress p) {
    if (!mounted) return;
    setState(() {
      if (!p.isTerminal) {
        _currentDownload = p.catalogName;
        _downloadProgress = p.progress;
        _downloadStatus = p.status;
      } else if (p.cancelled) {
        _downloadStatus = 'Cancelled';
      } else if (p.error != null) {
        _downloadStatus = p.error!;
      } else {
        _downloadProgress = 1.0;
        _downloadStatus = 'Complete';
      }
      _recomputeDownloading();
    });
    // A completed download changes on-disk state; refresh the badges/chips.
    if (p.isComplete) {
      unawaited(_loadCatalogStatus());
    }
  }

  Future<void> _loadCatalogStatus() async {
    if (!mounted) return;
    final generation = ++_statusGeneration;
    setState(() => _isLoading = true);

    try {
      final backend = ref.read(backendProvider);
      final rig = backend is NetworkBackend ? backend : null;
      final statuses = await Future.wait<CatalogStatus>([
        CatalogManager.instance.getStarCatalogStatus(),
        CatalogManager.instance.getDsoCatalogStatus(),
        CatalogManager.instance.getAnnotationCatalogStatus(),
      ]);

      RemoteCatalogStatusResponse? rigCatalogs;
      String? rigError;
      if (rig != null) {
        try {
          rigCatalogs = await rig.getCatalogStatus();
        } catch (e) {
          rigError = '$e';
        }
      }

      if (mounted && generation == _statusGeneration) {
        setState(() {
          _starStatus = statuses[0];
          _dsoStatus = statuses[1];
          _annotationStatus = statuses[2];
          _rigCatalogs = rigCatalogs;
          _rigCatalogError = rigError;
          _isLoading = false;
        });
        // Keep the shared catalog-state provider (planner empty-state, "needs
        // download" gating) consistent with what this screen just observed —
        // covers deletes/imports that don't flow through the download stream.
        unawaited(ref.read(catalogStateProvider.notifier).refreshStatus());
      }
    } catch (e) {
      if (mounted && generation == _statusGeneration) {
        setState(() {
          _isLoading = false;
        });
        _showError('Failed to check catalog status: $e');
      }
    }
  }

  Future<void> _downloadCatalogs() async {
    if (_isDownloading) return;
    // The live progress bar is driven by the manager's progress stream
    // (see [_onDownloadProgress]); here we only orchestrate the sequence and
    // surface the final outcome.
    setState(() {
      _methodRunning = true;
      _cancelRequested = false;
      _downloadProgress = 0;
      _downloadStatus = 'Preparing download...';
      _recomputeDownloading();
    });

    _logOutcome(
      'Catalog download started',
      fields: {'package': _installedPackage.name, 'catalogs': 'stars+dso'},
    );
    try {
      final starSuccess = await CatalogManager.instance.downloadStarCatalog(
        package: _installedPackage,
        isCancelled: () async => _cancelRequested,
      );
      if (_cancelRequested) return _onDownloadCancelled();
      if (!starSuccess) {
        throw Exception('Star catalog download failed');
      }

      final dsoSuccess = await CatalogManager.instance.downloadDsoCatalog(
        package: _installedPackage,
        isCancelled: () async => _cancelRequested,
      );
      if (_cancelRequested) return _onDownloadCancelled();
      if (!dsoSuccess) {
        throw Exception('DSO catalog download failed');
      }

      _logOutcome(
        'Catalog download completed',
        fields: {'package': _installedPackage.name, 'catalogs': 'stars+dso'},
      );
      await _loadCatalogStatus();

      if (mounted) {
        context.showSuccessSnackBar('Catalogs downloaded successfully!');
      }
    } catch (e) {
      _showError('Download failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _methodRunning = false;
          _recomputeDownloading();
        });
      }
    }
  }

  /// Tear down after the user cancels an in-flight download: refresh any
  /// surviving install and say that nothing changed.
  Future<void> _onDownloadCancelled() async {
    _logOutcome('Catalog download cancelled by the operator');
    await _loadCatalogStatus();
    if (mounted) {
      context.showInfoSnackBar('Download cancelled');
    }
  }

  void _requestCancelDownload() {
    setState(() {
      _cancelRequested = true;
      _downloadStatus = 'Cancelling…';
    });
  }

  @override
  Future<void> _importCatalog(String type) async {
    if (_isDownloading) return;
    final generation = ++_importGeneration;
    setState(() {
      _methodRunning = true;
      _currentDownload = type == 'stars' ? 'Star catalog' : 'DSO catalog';
      _downloadStatus = 'Selecting a CSV file...';
      _downloadProgress = 0;
      _recomputeDownloading();
    });

    try {
      final result = await ref.read(catalogCsvPickerProvider)('Select');
      if (result == null || !_isCurrentImport(generation)) return;

      setState(() {
        _downloadStatus = 'Importing catalog...';
      });

      final success =
          await ref.read(catalogCsvImporterProvider)(result.path, type);
      if (!_isCurrentImport(generation)) return;

      if (success) {
        // Logged before the status refresh: the outcome is already known, and
        // a slow/failed refresh must not cost the record of it.
        _logOutcome('Catalog imported', fields: {'type': type});
        await _loadCatalogStatus();
        if (mounted && _isCurrentImport(generation)) {
          context.showSuccessSnackBar('Catalog imported successfully!');
        }
      } else {
        _showError('Failed to import catalog');
      }
    } catch (e) {
      if (_isCurrentImport(generation)) {
        _showError('Import failed: $e');
      }
    } finally {
      if (_isCurrentImport(generation)) {
        setState(() {
          _methodRunning = false;
          _recomputeDownloading();
        });
      }
    }
  }

  bool _isCurrentImport(int generation) {
    return mounted && generation == _importGeneration;
  }

  Future<void> _deleteCatalogs() async {
    if (_isDownloading || _deleteConfirmationOpen) return;
    final confirm = await _confirmDeletion(
      title: 'Delete catalogs',
      message: 'Are you sure you want to delete the downloaded star and '
          'deep-sky catalogs? You will need to download them again to use '
          'the affected planetarium features.',
    );
    if (!confirm || !mounted) return;
    await _runDeletion(
      target: _CatalogDeleteTarget.starAndDso,
      delete: ref.read(catalogDeleteActionProvider),
      successMessage: 'Star and deep-sky catalogs deleted',
    );
  }

  Future<bool> _confirmDeletion({
    required String title,
    required String message,
  }) async {
    if (_deleteConfirmationOpen) return false;
    setState(() => _deleteConfirmationOpen = true);
    try {
      return await ConfirmDialog.show(
        context: context,
        title: title,
        message: message,
        confirmLabel: 'Delete',
        isDestructive: true,
      );
    } catch (e) {
      _showError('Could not open deletion confirmation: $e');
      return false;
    } finally {
      if (mounted) setState(() => _deleteConfirmationOpen = false);
    }
  }

  Future<void> _runDeletion({
    required _CatalogDeleteTarget target,
    required Future<void> Function() delete,
    required String successMessage,
  }) async {
    if (_isDownloading || _isDeleting) return;
    setState(() {
      _deleteTarget = target;
      _methodRunning = true;
      _recomputeDownloading();
    });
    try {
      await delete();
      _logOutcome('Catalogs deleted', fields: {'target': target.name});
      if (!mounted) return;
      await _loadCatalogStatus();
      if (mounted) context.showInfoSnackBar(successMessage);
    } catch (e) {
      _showError('Catalog deletion failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _deleteTarget = null;
          _methodRunning = false;
          _recomputeDownloading();
        });
      }
    }
  }

  /// Single funnel for every user-visible catalog failure: log it (with the
  /// cause the message already carries) BEFORE the snackbar, and log it even
  /// when the screen is gone, so support can see what the operator saw.
  void _showError(String message) {
    _logger.error(message, source: _logSource);
    if (mounted) {
      context.showErrorSnackBar(message);
    }
  }

  /// Record a catalog outcome the user saw succeed. Success needs a line too —
  /// a 15 MB GLADE+ download that worked left no trace at all, so the log could
  /// not even establish that the catalog on disk arrived tonight.
  void _logOutcome(String message, {Map<String, Object?>? fields}) {
    _logger.info(message, source: _logSource, fields: fields);
  }

  /// The appliance's status for [type] (`stars`, `dso`, `annotation`), or null
  /// when this is a local session or the appliance could not be asked. A rig
  /// that answered but does not list the catalog is reporting it missing.
  String? _rigStatusFor(String type) {
    final catalogs = _rigCatalogs?.catalogs;
    if (catalogs == null) return null;
    for (final catalog in catalogs) {
      if (catalog.name.toLowerCase() == type) {
        return catalog.status.toLowerCase();
      }
    }
    return 'missing';
  }

  bool get _rigMissingImagingCatalogs {
    for (final type in const ['stars', 'dso']) {
      final status = _rigStatusFor(type);
      if (status != null && !_CatalogCardBuilders._rigHasCatalog(status)) {
        return true;
      }
    }
    return false;
  }

  /// Warn when the appliance lacks catalogs the rig-side features need. The
  /// cards below describe this device only; a green install record here says
  /// nothing about the machine that plate-solves.
  Widget _buildRigScopeNotice(BuildContext context) {
    final colors = context.skotiqColors;
    final missing = _rigMissingImagingCatalogs;
    final router = GoRouter.maybeOf(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(
          color:
              missing ? colors.warning.withValues(alpha: 0.4) : colors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                missing ? SkotiqIcons.warning : SkotiqIcons.info,
                size: 18,
                color: missing ? colors.warning : colors.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _rigCatalogError != null
                      ? 'Could not read the rig\'s catalogs: $_rigCatalogError. '
                          'The cards below describe this device only.'
                      : missing
                          ? 'The rig is missing catalogs it needs — plate '
                              'solving, target search, framing and annotation '
                              'run on the rig, not on this device, so '
                              'downloading here will not fix them.'
                          : 'The cards below describe catalogs stored on this '
                              'device. The rig keeps its own copies.',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SkotiqButton(
            label: 'Manage rig catalogs',
            icon: SkotiqIcons.download,
            variant: missing ? ButtonVariant.primary : ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: router == null
                ? null
                : () {
                    // This screen is also shown as a dialog from Imaging;
                    // routing under an open dialog would look like a dead
                    // button.
                    if (ModalRoute.of(context) is PopupRoute) {
                      Navigator.of(context).pop();
                    }
                    router.go('/settings?section=rig-catalogs');
                  },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final padding = widget.isMobile ? 16.0 : 24.0;

    // On mobile, skip Scaffold since parent provides structure
    if (widget.isMobile) {
      return _isLoading
          ? const Center(
              child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36))
          : SingleChildScrollView(
              padding: EdgeInsets.all(padding),
              child: _buildContent(context),
            );
    }

    return Scaffold(
      backgroundColor: colors.background,
      body: _isLoading
          ? const Center(
              child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36))
          : SingleChildScrollView(
              padding: settingsPagePadding,
              child: _buildContent(context),
            ),
    );
  }

  Future<void> _downloadAnnotationCatalog() async {
    if (_isDownloading) return;
    setState(() {
      _methodRunning = true;
      _cancelRequested = false;
      _currentDownload = 'GLADE+ galaxy catalog';
      _downloadStatus = 'Preparing download...';
      _downloadProgress = 0;
      _recomputeDownloading();
    });

    _logOutcome(
      'Annotation catalog download started',
      fields: {'package': _selectedAnnotationPackage.name},
    );
    try {
      final success = await CatalogManager.instance.downloadAnnotationCatalog(
        package: _selectedAnnotationPackage,
        isCancelled: () async => _cancelRequested,
      );

      if (_cancelRequested) return _onDownloadCancelled();
      if (!success) {
        throw Exception('Annotation catalog download failed');
      }

      _logOutcome(
        'Annotation catalog download completed',
        fields: {'package': _selectedAnnotationPackage.name},
      );
      await _loadCatalogStatus();

      if (mounted) {
        context.showSuccessSnackBar('GLADE+ catalog downloaded successfully!');
      }
    } catch (e) {
      _showError('Download failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _methodRunning = false;
          _recomputeDownloading();
        });
      }
    }
  }

  Future<void> _importAnnotationCatalog() async {
    if (_isDownloading) return;
    final generation = ++_importGeneration;
    setState(() {
      _methodRunning = true;
      _currentDownload = 'GLADE+ galaxy catalog';
      _downloadStatus = 'Selecting a CSV file...';
      _downloadProgress = 0;
      _recomputeDownloading();
    });

    try {
      final result = await ref.read(catalogCsvPickerProvider)('Import');
      if (result == null || !_isCurrentImport(generation)) return;

      setState(() {
        _downloadStatus = 'Importing annotation catalog...';
      });

      final success =
          await ref.read(annotationCatalogCsvImporterProvider)(result.path);
      if (!_isCurrentImport(generation)) return;

      if (success) {
        _logOutcome('Catalog imported', fields: {'type': 'annotation'});
        await _loadCatalogStatus();
        if (mounted && _isCurrentImport(generation)) {
          context.showSuccessSnackBar(
            'GLADE+ catalog imported successfully!',
          );
        }
      } else {
        _showError('Failed to import annotation catalog');
      }
    } catch (e) {
      if (_isCurrentImport(generation)) {
        _showError('Import failed: $e');
      }
    } finally {
      if (_isCurrentImport(generation)) {
        setState(() {
          _methodRunning = false;
          _recomputeDownloading();
        });
      }
    }
  }

  Future<void> _deleteAnnotationCatalog() async {
    if (_isDownloading || _deleteConfirmationOpen) return;
    final confirm = await _confirmDeletion(
      title: 'Delete annotation catalog',
      message: 'Are you sure you want to delete the annotation catalog? '
          'You will need to download it again to use image annotation features.',
    );
    if (!confirm || !mounted) return;
    await _runDeletion(
      target: _CatalogDeleteTarget.annotation,
      delete: ref.read(annotationCatalogDeleteActionProvider),
      successMessage: 'Annotation catalog deleted',
    );
  }

  @override
  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

enum _CatalogDeleteTarget { starAndDso, annotation }
