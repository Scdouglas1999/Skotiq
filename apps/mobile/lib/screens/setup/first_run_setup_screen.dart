// Mobile first-run setup wizard.
//
// When the operator pairs their phone to a freshly-installed Skotiq
// server, three things are usually missing and must be addressed before
// the dashboard becomes useful:
//
//   1. `imageOutputPath` is empty — every capture would fail to save.
//   2. No catalogs are installed — plate-solving and target search are
//      broken until the user pulls down at least one starlist.
//   3. No equipment profile exists — connecting devices is impossible.
//
// The full equipment-onboarding wizard in skotiq_app handles (3) in
// depth (auto-discovery, optical train, etc.); this companion wizard
// is intentionally minimal — three steps tied to the three missing
// bootstrap conditions — so a phone operator can get the server running
// in under a minute without the deep flow. Step 3 surfaces a button
// that *opens* the full equipment-onboarding flow rather than reimplementing
// device pickers inside the wizard.
//
// The wizard is reached from `mobile_dashboard_screen.dart` and any
// `SkotiqApp(isMobile: true)` shell when `shouldRunFirstRunSetup`
// resolves true. It writes the `firstRunCompleted` flag through
// `MobilePreferences` so it never auto-appears again, even if a future
// connection lands on a server with the same empty state.

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/widgets/remote_directory_picker_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../services/mobile_preferences.dart';
import '../../utils/error_snackbar.dart';

/// Detection record returned by [shouldRunFirstRunSetupProvider].
///
/// A getter-only struct so widgets can drill into the missing pieces and
/// show step-specific intro copy ("You also have no catalogs yet — let's
/// fix that next") without re-running the detection.
class FirstRunSetupNeeds {
  final bool missingImageOutputPath;
  final bool missingProfiles;
  final bool missingCatalogs;

  const FirstRunSetupNeeds({
    required this.missingImageOutputPath,
    required this.missingProfiles,
    required this.missingCatalogs,
  });

  /// True if at least one bootstrap condition is unmet AND the user has
  /// not previously dismissed the wizard.
  bool get hasAnyMissing =>
      missingImageOutputPath || missingProfiles || missingCatalogs;

  /// Nothing to do — every bootstrap condition is satisfied.
  static const FirstRunSetupNeeds none = FirstRunSetupNeeds(
    missingImageOutputPath: false,
    missingProfiles: false,
    missingCatalogs: false,
  );
}

/// Async detection provider. Returns [FirstRunSetupNeeds] describing what
/// the server is missing; if the user has already completed (or skipped)
/// the wizard once, returns [FirstRunSetupNeeds.none] regardless of
/// server state.
final shouldRunFirstRunSetupProvider = FutureProvider<FirstRunSetupNeeds>((
  ref,
) async {
  // Honor the persistent latch first. If the user has completed setup on
  // this device, we never auto-route to the wizard again even if a
  // future server reset would otherwise trigger the conditions.
  // Await the latch instead of treating its loading state as "setup done".
  // The dashboard holds an explicit loading gate while this resolves; a
  // transient fail-open result would briefly expose controls and then replace
  // them with the wizard once SharedPreferences finished loading.
  final prefs = await ref.watch(mobilePreferencesProvider.future);
  if (prefs.firstRunCompleted) return FirstRunSetupNeeds.none;

  final backend = ref.watch(backendProvider);
  if (backend is! NetworkBackend) {
    // The wizard is companion-mode-only: a local FfiBackend always has
    // its profiles/catalogs/path managed through the desktop UI.
    return FirstRunSetupNeeds.none;
  }

  // Resolve each condition independently so a single failed call doesn't
  // suppress the wizard. We do not bail-early on the first match — the
  // wizard wants to know all three so its intro/Stepper can render the
  // right summary.
  var missingPath = false;
  var missingProfiles = false;
  var missingCatalogs = false;

  try {
    final settings = await backend.getSettings();
    missingPath = settings.imageOutputPath.trim().isEmpty;
  } catch (e, st) {
    // Fail closed: if the server cannot prove an output path exists, route
    // through the wizard where the retry/error is visible. Treating this as
    // configured would suppress the wizard for the rest of the connection and
    // let the first capture fail much later with a less actionable error.
    missingPath = true;
    developer.log(
      'first-run: getSettings failed: $e',
      name: 'FirstRunSetup',
      level: 1000,
      error: e,
      stackTrace: st,
    );
  }

  try {
    final profiles = await backend.getProfiles();
    missingProfiles = profiles.isEmpty;
  } catch (e, st) {
    missingProfiles = true;
    developer.log(
      'first-run: getProfiles failed: $e',
      name: 'FirstRunSetup',
      level: 1000,
      error: e,
      stackTrace: st,
    );
  }

  try {
    final status = await backend.getCatalogStatus();
    missingCatalogs = !status.catalogs.any((c) => c.isInstalled);
  } catch (e, st) {
    missingCatalogs = true;
    developer.log(
      'first-run: getCatalogStatus failed: $e',
      name: 'FirstRunSetup',
      level: 1000,
      error: e,
      stackTrace: st,
    );
  }

  return FirstRunSetupNeeds(
    missingImageOutputPath: missingPath,
    missingProfiles: missingProfiles,
    missingCatalogs: missingCatalogs,
  );
});

/// Three-step setup wizard. Step list:
///
///   * Step 0 — Image output path. Operator browses the host filesystem or
///     types an absolute host path. The host validates containment, existence,
///     and writability before `NetworkBackend.updateSettings` persists it.
///   * Step 1 — Catalogs. Lists available catalogs from
///     `/api/catalog/available` with a `requiredForPlateSolve` badge.
///     Operator selects what to install; the wizard fires
///     `downloadCatalog(name)` per pick and surfaces job handles in a
///     "downloading" list so the operator can move on while the server
///     fetches in the background.
///   * Step 2 — Profile. Surfaces the existing profile list (if the
///     operator already created one out of band) or routes them to the
///     full equipment onboarding flow.
class FirstRunSetupScreen extends ConsumerStatefulWidget {
  final FirstRunSetupNeeds needs;
  final VoidCallback onCompleted;

  const FirstRunSetupScreen({
    super.key,
    required this.needs,
    required this.onCompleted,
  });

  @override
  ConsumerState<FirstRunSetupScreen> createState() =>
      _FirstRunSetupScreenState();
}

class _FirstRunSetupScreenState extends ConsumerState<FirstRunSetupScreen> {
  int _activeStep = 0;
  bool _busy = false;

  // Step 0 state.
  final TextEditingController _customPathController = TextEditingController();
  String? _lastBrowsedHostPath;

  /// True once the host has accepted and persisted an output path in this
  /// session. The Stepper tick is drawn from this, never from navigation: a
  /// green check against "Image output path" that only means the operator
  /// tapped ahead sends the first capture of the night somewhere that does not
  /// exist.
  bool _outputPathCommitted = false;

  // Step 1 state.
  List<RemoteAvailableCatalog>? _availableCatalogs;
  final Set<String> _catalogsToInstall = {};
  final Set<String> _catalogsInFlight = {};
  String? _catalogLoadError;

  // Step 2 state.
  List<EquipmentProfile>? _profiles;
  String? _profileLoadError;
  bool _loadingBootstrapData = false;

  @override
  void initState() {
    super.initState();
    // Skip past steps that aren't needed. If the server already has a
    // valid imageOutputPath, start on the catalogs step (etc.). We still
    // *show* the previous steps in the Stepper sidebar so the operator
    // can revisit, but the wizard opens on the first unfinished step.
    if (!widget.needs.missingImageOutputPath) {
      _activeStep = 1;
    }
    if (!widget.needs.missingImageOutputPath && !widget.needs.missingCatalogs) {
      _activeStep = 2;
    }
    unawaited(_loadCatalogsAndProfiles());
  }

  @override
  void dispose() {
    _customPathController.dispose();
    super.dispose();
  }

  Future<void> _loadCatalogsAndProfiles() async {
    if (_loadingBootstrapData) return;
    _loadingBootstrapData = true;
    final backend = ref.read(backendProvider);
    if (backend is! NetworkBackend) {
      if (mounted) {
        setState(() {
          _loadingBootstrapData = false;
          _catalogLoadError = 'The phone is not connected to a server.';
          _profileLoadError = 'The phone is not connected to a server.';
        });
      }
      return;
    }

    List<RemoteAvailableCatalog>? catalogs;
    List<EquipmentProfile>? profiles;
    String? catalogError;
    String? profileError;

    await Future.wait<void>([
      () async {
        try {
          catalogs = await backend.listAvailableCatalogs();
        } catch (e, st) {
          catalogError = e is ServerError ? e.message : e.toString();
          developer.log(
            'first-run: failed to load catalogs: $e',
            name: 'FirstRunSetup',
            level: 1000,
            error: e,
            stackTrace: st,
          );
        }
      }(),
      () async {
        try {
          profiles = await backend.getProfiles();
        } catch (e, st) {
          profileError = e is ServerError ? e.message : e.toString();
          developer.log(
            'first-run: failed to load profiles: $e',
            name: 'FirstRunSetup',
            level: 1000,
            error: e,
            stackTrace: st,
          );
        }
      }(),
    ]);

    if (!mounted) return;
    setState(() {
      _loadingBootstrapData = false;
      _catalogLoadError = catalogError;
      _profileLoadError = profileError;
      if (catalogs != null) {
        _availableCatalogs = catalogs;
        // Pre-select catalogs that the server flagged as required for
        // plate-solving. Operators almost always want these and the
        // checkbox stays editable so power users can opt out.
        for (final c in catalogs!) {
          if (c.requiredForPlateSolve) {
            _catalogsToInstall.add(c.name);
          }
        }
      } else {
        _availableCatalogs = null;
      }
      _profiles = profiles;
    });
  }

  String? _resolveSelectedPath() {
    final trimmed = _customPathController.text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _browseImageOutputPath() async {
    if (_busy) return;
    final selected = await RemoteDirectoryPickerDialog.show(
      context,
      title: 'Choose capture folder on host',
      initialPath: _lastBrowsedHostPath,
    );
    if (selected == null || !mounted) return;
    setState(() {
      _lastBrowsedHostPath = selected;
      _customPathController.text = selected;
    });
  }

  Future<void> _commitImageOutputPath() async {
    if (_busy) return;
    final backend = ref.read(backendProvider);
    if (backend is! NetworkBackend) return;
    final path = _resolveSelectedPath();
    if (path == null) {
      if (mounted) {
        showApiError(
          context,
          ServerError(
            code: 'invalid_input',
            message: 'Please select or enter an image output path',
          ),
        );
      }
      return;
    }
    setState(() => _busy = true);
    try {
      final validation = await backend.validateRemoteDirectory(
        path,
        mustExist: true,
        mustBeWritable: true,
      );
      if (validation['valid'] != true) {
        final reason = validation['error'];
        throw ServerError(
          code: 'invalid_output_path',
          message: reason is String && reason.trim().isNotEmpty
              ? reason.trim()
              : 'Choose an existing, writable capture folder on the host',
        );
      }
      final normalized = validation['normalizedPath'];
      final validatedPath = normalized is String && normalized.trim().isNotEmpty
          ? normalized.trim()
          : path;
      final current = await backend.getSettings();
      await backend.updateSettings(
        current.copyWith(imageOutputPath: validatedPath),
      );
      if (!mounted) return;
      setState(() {
        _customPathController.text = validatedPath;
        _lastBrowsedHostPath = validatedPath;
        _outputPathCommitted = true;
        _busy = false;
        _activeStep = 1;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showApiErrorWithPrefix(context, 'Failed to set output path', e);
    }
  }

  Future<void> _commitCatalogs() async {
    if (_busy) return;
    final backend = ref.read(backendProvider);
    if (backend is! NetworkBackend) return;
    if (_catalogsToInstall.isEmpty) {
      // Operator deliberately picked none — that's allowed (they may
      // have a custom catalog they upload via the desktop). Advance to
      // step 2 without firing any downloads.
      setState(() => _activeStep = 2);
      return;
    }
    setState(() => _busy = true);
    final pending = _catalogsToInstall.toList(growable: false);
    var firedAny = false;
    for (final name in pending) {
      try {
        await backend.downloadCatalog(name);
        firedAny = true;
        if (!mounted) return;
        setState(() {
          _catalogsInFlight.add(name);
        });
      } catch (e) {
        if (!mounted) return;
        showApiErrorWithPrefix(context, 'Catalog download failed ($name)', e);
        // Continue with remaining catalogs — one failure shouldn't
        // block the rest. The operator can revisit failures in the
        // Settings → Catalogs screen.
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (firedAny || _catalogsToInstall.isEmpty) _activeStep = 2;
    });
  }

  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final prefs = await ref.read(mobilePreferencesProvider.future);
      await prefs.setFirstRunCompleted(true);
      // Refresh the gate so the next build skips this screen.
      ref.invalidate(shouldRunFirstRunSetupProvider);
      if (!mounted) return;
      widget.onCompleted();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showApiErrorWithPrefix(context, 'Could not finish setup', e);
    }
  }

  Future<void> _skip() async {
    // Skipping still records the flag — the wizard is a one-time interrupt;
    // the operator can always reach the same settings from the Settings
    // tab without the wizard re-asserting itself.
    await _finish();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        title: const Text('First-run setup'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _skip,
            child: Text('Skip', style: TextStyle(color: colors.textSecondary)),
          ),
        ],
      ),
      body: Stepper(
        currentStep: _activeStep,
        controlsBuilder: (context, details) => const SizedBox.shrink(),
        onStepTapped: _busy
            ? null
            : (step) {
                setState(() => _activeStep = step);
              },
        steps: [
          Step(
            title: const Text('Image output path'),
            isActive: _activeStep == 0,
            state: _outputPathState,
            content: _buildImagePathStep(colors),
          ),
          Step(
            title: const Text('Catalogs'),
            isActive: _activeStep == 1,
            state: _catalogsState,
            content: _buildCatalogsStep(colors),
          ),
          Step(
            title: const Text('Equipment profile'),
            isActive: _activeStep == 2,
            state: _profileState,
            content: _buildProfileStep(colors),
          ),
        ],
      ),
    );
  }

  /// Step ticks describe what the *host* has, not where the operator has
  /// browsed to. A `StepState.complete` here is a claim that the bootstrap
  /// condition is satisfied, so each getter is answered from a fact — the
  /// condition was already met when the wizard opened, or this session did
  /// something about it — and stays [StepState.indexed] otherwise.
  StepState get _outputPathState =>
      !widget.needs.missingImageOutputPath || _outputPathCommitted
      ? StepState.complete
      : StepState.indexed;

  /// Catalogs count as handled once at least one download has actually been
  /// accepted by the host. Skipping the step leaves it unticked: plate solving
  /// really is unavailable, and pretending otherwise is how an operator gets to
  /// their first failed solve believing setup was finished.
  StepState get _catalogsState =>
      !widget.needs.missingCatalogs || _catalogsInFlight.isNotEmpty
      ? StepState.complete
      : StepState.indexed;

  /// Prefer the profile list actually read back from the host over the
  /// launch-time snapshot — the operator may have created one on the desktop
  /// while this wizard was open.
  StepState get _profileState {
    final profiles = _profiles;
    if (profiles != null) {
      return profiles.isEmpty ? StepState.indexed : StepState.complete;
    }
    return widget.needs.missingProfiles
        ? StepState.indexed
        : StepState.complete;
  }

  Widget _buildImagePathStep(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Choose where Skotiq should save captured images on the imaging '
          'host. The folder must already exist and be writable.',
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: SkotiqTypography.fontSize13,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _customPathController,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Host capture directory',
            hintText: r'e.g. D:\Astro\Captures or /mnt/captures',
            helperText:
                'This path belongs to the imaging host, not this phone.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: SkotiqButton(
            onPressed: _busy ? null : _browseImageOutputPath,
            label: 'Browse host folders',
            icon: LucideIcons.folderOpen,
            variant: ButtonVariant.outline,
          ),
        ),
        const SizedBox(height: 16),
        SkotiqButton(
          onPressed: _busy ? null : _commitImageOutputPath,
          label: _busy ? 'Saving...' : 'Save and continue',
        ),
      ],
    );
  }

  Widget _buildCatalogsStep(SkotiqColors colors) {
    if (_catalogLoadError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Could not list catalogs: $_catalogLoadError',
            style: TextStyle(color: colors.error),
          ),
          const SizedBox(height: 12),
          SkotiqButton(
            onPressed: _busy
                ? null
                : () {
                    setState(() {
                      _catalogLoadError = null;
                      _availableCatalogs = null;
                    });
                    unawaited(_loadCatalogsAndProfiles());
                  },
            label: 'Retry',
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : () => setState(() => _activeStep = 2),
            child: const Text('Skip catalogs'),
          ),
        ],
      );
    }
    final catalogs = _availableCatalogs;
    if (catalogs == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Pick catalogs to install. Plate-solving will not work until at '
          'least one star catalog is installed. Downloads run in the '
          'background; you can finish setup before they complete.',
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: SkotiqTypography.fontSize13,
          ),
        ),
        const SizedBox(height: 12),
        for (final c in catalogs)
          CheckboxListTile(
            value: _catalogsToInstall.contains(c.name),
            onChanged: _busy
                ? null
                : (v) {
                    setState(() {
                      if (v == true) {
                        _catalogsToInstall.add(c.name);
                      } else {
                        _catalogsToInstall.remove(c.name);
                      }
                    });
                  },
            contentPadding: EdgeInsets.zero,
            title: Row(
              children: [
                Expanded(child: Text(c.displayName)),
                if (c.requiredForPlateSolve)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(
                        SkotiqTokens.radiusXs,
                      ),
                    ),
                    child: Text(
                      'plate-solve',
                      style: TextStyle(
                        color: colors.primary,
                        fontSize: SkotiqTypography.fontSize10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            subtitle: Text(
              '${c.description} (${_formatSize(c.sizeBytes)})',
              style: TextStyle(
                color: colors.textMuted,
                fontSize: SkotiqTypography.fontSize11,
              ),
            ),
          ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: SkotiqButton(
                onPressed: _busy ? null : _commitCatalogs,
                label: _busy
                    ? 'Starting downloads...'
                    : _catalogsToInstall.isEmpty
                    ? 'Skip and continue'
                    : 'Install and continue',
              ),
            ),
          ],
        ),
        if (_catalogsInFlight.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Downloading: ${_catalogsInFlight.join(", ")}',
            style: TextStyle(
              color: colors.textMuted,
              fontSize: SkotiqTypography.fontSize11,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildProfileStep(SkotiqColors colors) {
    final loadError = _profileLoadError;
    if (loadError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Could not list equipment profiles: $loadError',
            style: TextStyle(color: colors.error),
          ),
          const SizedBox(height: 12),
          SkotiqButton(
            onPressed: _busy || _loadingBootstrapData
                ? null
                : () {
                    setState(() {
                      _profileLoadError = null;
                      _profiles = null;
                    });
                    unawaited(_loadCatalogsAndProfiles());
                  },
            label: _loadingBootstrapData ? 'Retrying…' : 'Retry',
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : _finish,
            child: const Text('Finish without a profile'),
          ),
        ],
      );
    }
    final profiles = _profiles;
    if (profiles == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
        ),
      );
    }
    if (profiles.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'You already have ${profiles.length} equipment profile'
            '${profiles.length == 1 ? "" : "s"}. The wizard is done.',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: SkotiqTypography.fontSize13,
            ),
          ),
          const SizedBox(height: 12),
          for (final p in profiles)
            ListTile(
              leading: const Icon(LucideIcons.workflow),
              title: Text(p.name),
              subtitle: Text(
                p.description ?? 'No description',
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: SkotiqTypography.fontSize11,
                ),
              ),
              contentPadding: EdgeInsets.zero,
            ),
          const SizedBox(height: 16),
          SkotiqButton(
            onPressed: _busy ? null : _finish,
            label: 'Finish setup',
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'No equipment profile yet. Equipment profiles are created on the '
          'paired desktop or host — once you set one up there it appears '
          'here automatically. You can finish setup now and pick a profile '
          'later.',
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: SkotiqTypography.fontSize13,
          ),
        ),
        const SizedBox(height: 16),
        SkotiqButton(
          onPressed: _busy ? null : _finish,
          label: 'Finish without a profile',
        ),
      ],
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
