part of '../equipment_profiles_screen.dart';

typedef EquipmentProfileImportPicker = Future<XFile?> Function();
typedef EquipmentProfileImportReader = Future<String> Function(XFile file);
typedef EquipmentProfileImporter = Future<List<int>> Function(String json);
typedef EquipmentProfileExportPicker = Future<ExportTarget?> Function(
  String suggestedName,
);
typedef EquipmentProfileExporter = Future<String> Function(int profileId);
typedef EquipmentProfileExportWriter = Future<void> Function(
  String path,
  String fileName,
  String json,
);

/// The importer's collision rule applied to any proposed profile name: keep
/// [base] when it is free, otherwise `base (1)`, `base (2)`, … until one is.
///
/// Comparison is trimmed and case-insensitive, matching profile validation.
String uniqueProfileName(String base, Iterable<String> taken) {
  final names = taken.map(normalizeProfileName).toSet();
  if (!names.contains(normalizeProfileName(base))) return base;
  var suffix = 1;
  while (names.contains(normalizeProfileName('$base ($suffix)'))) {
    suffix++;
  }
  return '$base ($suffix)';
}

/// The form two profile names are compared in.
String normalizeProfileName(String name) => name.trim().toLowerCase();

/// What the operator is told when an import does not go through.
///
/// A raw `toString()` — "FormatException: Unexpected character (at character
/// 1)" — names neither the file nor what to do about it.
/// [ProfileImportException] already carries operator-facing prose; anything else
/// is genuinely unexpected and is kept verbatim so a real bug stays legible in
/// the log.
String describeProfileImportFailure(Object error, {String? fileName}) {
  final subject = fileName == null ? 'that file' : '"$fileName"';
  if (error is ProfileImportException) {
    return error.message.replaceFirst('That file', subject);
  }
  return 'Could not import $subject: $error';
}

Future<XFile?> _pickEquipmentProfileImport() {
  const jsonGroup = XTypeGroup(
    label: 'JSON files',
    extensions: ['json'],
  );
  return openFile(acceptedTypeGroups: [jsonGroup]);
}

final equipmentProfileImportPickerProvider =
    Provider<EquipmentProfileImportPicker>(
  (ref) => _pickEquipmentProfileImport,
);

final equipmentProfileImportReaderProvider =
    Provider<EquipmentProfileImportReader>(
  (ref) => (file) => file.readAsString(),
);

final equipmentProfileImporterProvider = Provider<EquipmentProfileImporter>(
  (ref) => (json) =>
      ref.read(equipmentProfilesProvider.notifier).importProfiles(json),
);

/// Resolves the export destination. Not `getSaveLocation`: Android/iOS have no
/// save dialog (`getSavePath` throws UnimplementedError), so exporting a
/// profile was dead on a phone. There the target is a sandbox path and
/// [_exportProfile] finishes with the share sheet.
final equipmentProfileExportPickerProvider =
    Provider<EquipmentProfileExportPicker>((ref) {
  return (suggestedName) => chooseExportTarget(
        suggestedName: suggestedName,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON files', extensions: ['json']),
        ],
      );
});

final equipmentProfileExporterProvider = Provider<EquipmentProfileExporter>(
  (ref) => (profileId) =>
      ref.read(equipmentProfilesProvider.notifier).exportProfile(profileId),
);

final equipmentProfileExportWriterProvider =
    Provider<EquipmentProfileExportWriter>((ref) {
  return (path, fileName, json) => XFile.fromData(
        utf8.encode(json),
        mimeType: 'application/json',
        name: fileName,
      ).saveTo(path);
});

/// Screen for managing equipment profiles
class EquipmentProfilesScreen extends ConsumerStatefulWidget {
  final bool isMobile;

  const EquipmentProfilesScreen({super.key, this.isMobile = false});

  @override
  ConsumerState<EquipmentProfilesScreen> createState() =>
      _EquipmentProfilesScreenState();
}

/// How long to wait for a mutated row to reach the authoritative profile list
/// before giving up on selecting it. Generous because the path crosses a Drift
/// table stream; expiring is never reported as a failed write.
const Duration _mutatedProfileWindow = Duration(seconds: 5);

class _EquipmentProfilesScreenState
    extends ConsumerState<EquipmentProfilesScreen> {
  EquipmentProfileModel? _selectedProfile;
  bool _isEditing = false;
  // For mobile: track whether we're viewing the detail
  bool _showingDetail = false;
  bool _isImportingProfiles = false;
  int _importGeneration = 0;
  bool _isExportingProfile = false;
  int _exportGeneration = 0;
  int _profileMutationGeneration = 0;

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous == null || identical(previous, next)) return;
      _importGeneration++;
      _exportGeneration++;
      _profileMutationGeneration++;
      setState(() {
        _selectedProfile = null;
        _isEditing = false;
        _showingDetail = false;
        _isImportingProfiles = false;
        _isExportingProfile = false;
      });
    });
    final colors = SkotiqColors.of(context);
    final profilesAsync = ref.watch(equipmentProfilesProvider);

    return profilesAsync.when(
      loading: () => const Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
      error: (error, stack) => Center(
        child: EmptyState.compact(
          icon: LucideIcons.alertTriangle,
          title: 'Could not load profiles',
          body: 'Something went wrong reading your equipment profiles. '
              'Pull to refresh or try again.',
          action: SkotiqButton(
            label: 'Retry',
            icon: LucideIcons.refreshCw,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => ref.invalidate(equipmentProfilesProvider),
          ),
        ),
      ),
      data: (state) {
        // The selection is an IDENTITY, not a snapshot: resolved against the
        // authoritative list every build, so no control can survive the row it
        // acts on. A held snapshot leaves the detail pane rendering a deleted
        // profile — with a live "Set Active" — beside a list that says there
        // are none.
        final selected = _selectionIn(state);
        if (_selectedProfile != null && selected == null) {
          _scheduleSelectionDrop(_selectedProfile!.id);
        }

        // Auto-select active profile if none selected (desktop only)
        if (!widget.isMobile &&
            selected == null &&
            state.activeProfile != null) {
          final authority = ref.read(backendProvider);
          final activeProfile = state.activeProfile!;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted ||
                _selectedProfile != null ||
                !identical(ref.read(backendProvider), authority)) {
              return;
            }
            setState(() => _selectedProfile = activeProfile);
          });
        }

        if (widget.isMobile) {
          return _buildMobileLayout(state, selected, colors);
        }

        return _buildDesktopLayout(state, selected, colors);
      },
    );
  }

  /// The selected profile as it exists in [state], or null when the row it
  /// referred to is gone.
  ///
  /// Returns the locally held model (not the one from [state]) so an
  /// optimistic post-save copy is not reverted to the pre-save row while the
  /// authoritative refresh is still in flight; only its continued EXISTENCE is
  /// taken from [state].
  EquipmentProfileModel? _selectionIn(EquipmentProfilesState state) {
    final selectedId = _selectedProfile?.id;
    if (selectedId == null) return null;
    for (final profile in state.profiles) {
      if (profile.id == selectedId) return _selectedProfile;
    }
    return null;
  }

  /// Drop a selection whose row no longer exists, after the frame that
  /// discovered it. Re-checked against the live provider value because this
  /// runs a frame later and a mutation may have completed in between.
  void _scheduleSelectionDrop(int? profileId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedProfile?.id != profileId) return;
      final current = ref.read(equipmentProfilesProvider).valueOrNull;
      if (current == null) return;
      for (final profile in current.profiles) {
        if (profile.id == profileId) return;
      }
      setState(() {
        _selectedProfile = null;
        _isEditing = false;
        _showingDetail = false;
      });
    });
  }

  Widget _buildMobileLayout(
    EquipmentProfilesState state,
    EquipmentProfileModel? selected,
    SkotiqColors colors,
  ) {
    // Show detail view if a profile is selected and we're viewing detail
    if (_showingDetail && selected != null) {
      return _ProfileDetails(
        profile: selected,
        isActive: selected.id == state.activeProfile?.id,
        isEditing: _isEditing,
        isMobile: true,
        onBack: () => setState(() => _showingDetail = false),
        onEdit: () => setState(() => _isEditing = true),
        onSave: _saveSelectedProfile,
        onCancel: () => setState(() => _isEditing = false),
        onSetActive: () => _setActiveProfile(context, selected),
        onSetDefault: () => _setDefaultProfile(context, selected),
        onDuplicate: () => _duplicateProfile(context, colors, selected),
        onDelete: () => _deleteProfile(context, colors, selected),
        onExport: () => _exportProfile(context, selected),
        onRefresh: _refreshSelectedProfile,
      );
    }

    // Show profile list
    return _ProfileList(
      profiles: state.profiles,
      selectedProfile: selected,
      activeProfile: state.activeProfile,
      isMobile: true,
      onProfileSelected: (profile) {
        setState(() {
          _selectedProfile = profile;
          _isEditing = false;
          _showingDetail = true;
        });
      },
      onCreateProfile: () => _showCreateProfileDialog(context, colors),
      onImportProfiles:
          _isImportingProfiles ? null : () => _importProfiles(context),
      isImportingProfiles: _isImportingProfiles,
    );
  }

  Widget _buildDesktopLayout(
    EquipmentProfilesState state,
    EquipmentProfileModel? selected,
    SkotiqColors colors,
  ) {
    return Row(
      children: [
        // Profile list sidebar
        _ProfileList(
          profiles: state.profiles,
          selectedProfile: selected,
          activeProfile: state.activeProfile,
          onProfileSelected: (profile) {
            setState(() {
              _selectedProfile = profile;
              _isEditing = false;
            });
          },
          onCreateProfile: () => _showCreateProfileDialog(context, colors),
          onImportProfiles:
              _isImportingProfiles ? null : () => _importProfiles(context),
          isImportingProfiles: _isImportingProfiles,
        ),

        // Profile details
        Expanded(
          child: selected != null
              ? _ProfileDetails(
                  profile: selected,
                  isActive: selected.id == state.activeProfile?.id,
                  isEditing: _isEditing,
                  onEdit: () => setState(() => _isEditing = true),
                  onSave: _saveSelectedProfile,
                  onCancel: () => setState(() => _isEditing = false),
                  onSetActive: () => _setActiveProfile(context, selected),
                  onSetDefault: () => _setDefaultProfile(context, selected),
                  onDuplicate: () =>
                      _duplicateProfile(context, colors, selected),
                  onDelete: () => _deleteProfile(context, colors, selected),
                  onExport: () => _exportProfile(context, selected),
                  onRefresh: _refreshSelectedProfile,
                )
              : const EmptyState.compact(
                  icon: LucideIcons.aperture,
                  title: 'Select a profile',
                  body: 'Choose a profile from the list or create a new one',
                ),
        ),
      ],
    );
  }

  Future<void> _saveSelectedProfile(
      EquipmentProfileModel updatedProfile) async {
    final authority = ref.read(backendProvider);
    final profileId = updatedProfile.id;
    await ref
        .read(equipmentProfilesProvider.notifier)
        .updateProfile(updatedProfile);
    if (!mounted ||
        !identical(ref.read(backendProvider), authority) ||
        _selectedProfile?.id != profileId) {
      return;
    }
    setState(() {
      _selectedProfile = updatedProfile;
      _isEditing = false;
    });
  }

  Future<bool> _refreshSelectedProfile(
    int profileId,
    SkotiqBackend authority,
  ) async {
    // ProfileService invalidates the authoritative list after its write.
    // Await that refresh instead of immediately reading the previous cache or
    // invalidating a second time and restarting the in-flight reload.
    final refreshed = await ref.read(equipmentProfilesProvider.future);
    if (!mounted ||
        !identical(ref.read(backendProvider), authority) ||
        _selectedProfile?.id != profileId) {
      return false;
    }

    EquipmentProfileModel? updated;
    for (final profile in refreshed.profiles) {
      if (profile.id == profileId) {
        updated = profile;
        break;
      }
    }
    if (updated == null) {
      throw StateError(
        'Filters were saved, but profile $profileId could not be reloaded.',
      );
    }
    setState(() => _selectedProfile = updated);
    return true;
  }

  /// Log a user-visible profile failure and then show it.
  ///
  /// Snackbar-only failures left Settings > Logs (and the exported log file)
  /// with no record of rejected saves, imports or duplicates — a support
  /// engineer reading the export saw a clean session.
  void _reportProfileFailure(BuildContext context, String message) {
    ref
        .read(loggingServiceProvider)
        .error(message, source: 'EquipmentProfiles');
    if (context.mounted) context.showErrorSnackBar(message);
  }

  bool _isCurrentProfileMutation(
    int generation,
    SkotiqBackend authority,
  ) {
    return mounted &&
        generation == _profileMutationGeneration &&
        identical(ref.read(backendProvider), authority);
  }

  static EquipmentProfileModel? _findProfile(
    EquipmentProfilesState state,
    int profileId,
  ) {
    for (final profile in state.profiles) {
      if (profile.id == profileId) return profile;
    }
    return null;
  }

  /// Resolve the row a mutation just wrote, once the authoritative list
  /// actually carries it.
  ///
  /// The profiles provider rebuilds off Drift table streams, so the refresh a
  /// mutation schedules can complete from a stream emission that PREDATES the
  /// row just written. Asserting on that first snapshot reported completed
  /// duplicates as failures — and printed the internal invariant text at the
  /// operator, who then duplicated again. Wait for the row to appear instead,
  /// and treat the window expiring as "not selectable yet", never as a failed
  /// write: the mutation already returned this id, so it succeeded.
  Future<EquipmentProfileModel?> _awaitMutatedProfile({
    required int profileId,
    required int generation,
    required SkotiqBackend authority,
  }) async {
    final refreshed = await ref.read(equipmentProfilesProvider.future);
    if (!_isCurrentProfileMutation(generation, authority)) return null;
    final immediate = _findProfile(refreshed, profileId);
    if (immediate != null) return immediate;

    final completer = Completer<EquipmentProfileModel?>();
    final subscription = ref.listenManual<AsyncValue<EquipmentProfilesState>>(
      equipmentProfilesProvider,
      (previous, next) {
        if (completer.isCompleted) return;
        final value = next.valueOrNull;
        if (value == null) return;
        final match = _findProfile(value, profileId);
        if (match != null) completer.complete(match);
      },
    );
    try {
      final resolved = await completer.future.timeout(
        _mutatedProfileWindow,
        onTimeout: () => null,
      );
      if (!_isCurrentProfileMutation(generation, authority)) return null;
      return resolved;
    } finally {
      subscription.close();
    }
  }

  /// Activate [profile], reporting a rejected activation to the operator.
  ///
  /// The notifier's activation is strict — it throws when the target row is
  /// gone — and an uncaught throw here was an unhandled zone exception with no
  /// on-screen trace of a button that visibly did nothing.
  Future<void> _setActiveProfile(
    BuildContext context,
    EquipmentProfileModel profile,
  ) async {
    final profileId = profile.id;
    if (profileId == null) return;
    final authority = ref.read(backendProvider);
    final generation = ++_profileMutationGeneration;
    try {
      await ref
          .read(equipmentProfilesProvider.notifier)
          .setActiveProfile(profileId);
    } catch (error) {
      if (_isCurrentProfileMutation(generation, authority) && context.mounted) {
        _reportProfileFailure(
          context,
          'Could not activate "${profile.name}": $error',
        );
      }
    }
  }

  /// Pin [profile] as the startup default without changing which profile is
  /// active — Settings > General promises auto-connect uses this row, and
  /// before this action there was no way to see or move it.
  Future<void> _setDefaultProfile(
    BuildContext context,
    EquipmentProfileModel profile,
  ) async {
    final profileId = profile.id;
    if (profileId == null) return;
    final authority = ref.read(backendProvider);
    final generation = ++_profileMutationGeneration;
    try {
      await ref
          .read(equipmentProfilesProvider.notifier)
          .setDefaultProfile(profileId, makeActive: false);
      if (_isCurrentProfileMutation(generation, authority) && context.mounted) {
        context.showSuccessSnackBar(
          '"${profile.name}" is now the startup profile',
        );
      }
    } catch (error) {
      if (_isCurrentProfileMutation(generation, authority) && context.mounted) {
        _reportProfileFailure(
          context,
          'Could not set startup profile: $error',
        );
      }
    }
  }

  Future<void> _showCreateProfileDialog(
      BuildContext context, SkotiqColors colors) async {
    final result = await showDialog<({String name, String? description})>(
      context: context,
      builder: (dialogContext) => _CreateProfileDialog(colors: colors),
    );

    if (result == null || !mounted) return;
    final authority = ref.read(backendProvider);
    final generation = ++_profileMutationGeneration;
    try {
      final id = await ref
          .read(equipmentProfilesProvider.notifier)
          .createProfile(name: result.name, description: result.description);
      if (!_isCurrentProfileMutation(generation, authority)) return;
      final newProfile = await _awaitMutatedProfile(
        profileId: id,
        generation: generation,
        authority: authority,
      );
      if (newProfile == null) return;
      setState(() {
        _selectedProfile = newProfile;
        _isEditing = true;
        _showingDetail = widget.isMobile;
      });
    } catch (error) {
      if (_isCurrentProfileMutation(generation, authority) && context.mounted) {
        _reportProfileFailure(context, 'Create profile failed: $error');
      }
    }
  }

  Future<void> _duplicateProfile(BuildContext context, SkotiqColors colors,
      EquipmentProfileModel profile) async {
    final takenNames = ref
        .read(equipmentProfileListProvider)
        .map((existing) => existing.name)
        .toList(growable: false);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _DuplicateProfileDialog(
        colors: colors,
        initialName: uniqueProfileName('${profile.name} (Copy)', takenNames),
        takenNames: takenNames,
      ),
    );

    if (result == null || profile.id == null || !mounted) return;
    final authority = ref.read(backendProvider);
    final generation = ++_profileMutationGeneration;
    try {
      final id = await ref
          .read(equipmentProfilesProvider.notifier)
          .duplicateProfile(profile.id!, result);
      if (!_isCurrentProfileMutation(generation, authority)) return;
      final newProfile = await _awaitMutatedProfile(
        profileId: id,
        generation: generation,
        authority: authority,
      );
      if (newProfile == null) return;
      setState(() {
        _selectedProfile = newProfile;
        _isEditing = false;
        _showingDetail = widget.isMobile;
      });
    } catch (error) {
      if (_isCurrentProfileMutation(generation, authority) && context.mounted) {
        _reportProfileFailure(context, 'Duplicate profile failed: $error');
      }
    }
  }

  Future<void> _deleteProfile(BuildContext context, SkotiqColors colors,
      EquipmentProfileModel profile) async {
    final confirm = await ConfirmDialog.delete(
      context: context,
      itemName: 'profile "${profile.name}"',
    );

    if (!confirm || profile.id == null || !mounted) return;
    final authority = ref.read(backendProvider);
    final generation = ++_profileMutationGeneration;
    try {
      await ref
          .read(equipmentProfilesProvider.notifier)
          .deleteProfile(profile.id!);
      if (!_isCurrentProfileMutation(generation, authority)) return;
      setState(() {
        if (_selectedProfile?.id == profile.id) {
          _selectedProfile = null;
          _isEditing = false;
          _showingDetail = false;
        }
      });
    } catch (error) {
      if (_isCurrentProfileMutation(generation, authority) && context.mounted) {
        _reportProfileFailure(context, 'Delete profile failed: $error');
      }
    }
  }

  Future<void> _exportProfile(
      BuildContext context, EquipmentProfileModel profile) async {
    if (_isExportingProfile || profile.id == null) return;
    final generation = ++_exportGeneration;
    final authority = ref.read(backendProvider);
    setState(() => _isExportingProfile = true);

    bool isCurrent() =>
        mounted &&
        generation == _exportGeneration &&
        identical(ref.read(backendProvider), authority);

    try {
      final fileName =
          '${profile.name.replaceAll(RegExp(r'[^\w\s-]'), '_')}_profile.json';
      final target = await ref.read(equipmentProfileExportPickerProvider)(
        fileName,
      );
      if (target == null || !isCurrent()) return;

      final json =
          await ref.read(equipmentProfileExporterProvider)(profile.id!);
      if (!isCurrent()) return;

      await ref.read(equipmentProfileExportWriterProvider)(
        target.path,
        fileName,
        json,
      );

      if (isCurrent() && context.mounted) {
        await revealExportedFile(
          context,
          target.path,
          subject: 'Skotiq equipment profile',
          desktopMessage: 'Profile exported to ${target.path}',
        );
      }
    } catch (e) {
      if (!isCurrent() || !context.mounted) return;
      _reportProfileFailure(context, 'Export failed: $e');
    } finally {
      if (mounted && generation == _exportGeneration) {
        setState(() => _isExportingProfile = false);
      }
    }
  }

  Future<void> _importProfiles(BuildContext context) async {
    if (_isImportingProfiles) return;
    final generation = ++_importGeneration;
    final authority = ref.read(backendProvider);
    setState(() => _isImportingProfiles = true);

    String? pickedFileName;
    try {
      final file = await ref.read(equipmentProfileImportPickerProvider)();
      if (file == null || !_isCurrentImport(generation, authority)) return;
      pickedFileName = file.name.isNotEmpty ? file.name : file.path;

      final json = await ref.read(equipmentProfileImportReaderProvider)(file);
      if (!_isCurrentImport(generation, authority)) return;

      final ids = await ref.read(equipmentProfileImporterProvider)(json);
      if (!_isCurrentImport(generation, authority)) return;

      // The notifier invalidates after import. Await the refreshed authority
      // instead of sleeping for an arbitrary 100 ms and assuming it is ready.
      final refreshed = await ref.read(equipmentProfilesProvider.future);
      if (!_isCurrentImport(generation, authority)) return;

      if (ids.isNotEmpty) {
        EquipmentProfileModel? imported;
        for (final profile in refreshed.profiles) {
          if (profile.id == ids.first) {
            imported = profile;
            break;
          }
        }
        if (imported != null) {
          setState(() {
            _selectedProfile = imported;
            _isEditing = false;
            _showingDetail = widget.isMobile;
          });
        }
      }

      if (context.mounted) {
        context.showSuccessSnackBar(
          'Imported ${ids.length} profile${ids.length == 1 ? '' : 's'}',
        );
      }
    } catch (e) {
      if (!context.mounted || !_isCurrentImport(generation, authority)) return;
      _reportProfileFailure(
        context,
        describeProfileImportFailure(e, fileName: pickedFileName),
      );
    } finally {
      if (_isCurrentImport(generation, authority)) {
        setState(() => _isImportingProfiles = false);
      }
    }
  }

  bool _isCurrentImport(int generation, SkotiqBackend authority) {
    return mounted &&
        generation == _importGeneration &&
        identical(ref.read(backendProvider), authority);
  }
}

class _CreateProfileDialog extends StatefulWidget {
  final SkotiqColors colors;

  const _CreateProfileDialog({required this.colors});

  @override
  State<_CreateProfileDialog> createState() => _CreateProfileDialogState();
}

class _CreateProfileDialogState extends State<_CreateProfileDialog> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  String? _nameError;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return AlertDialog(
      backgroundColor: colors.surface,
      title: Text(
        'Create New Profile',
        style: SkotiqTypography.body.copyWith(
          color: colors.textPrimary,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              // Return submits from the name field — description is optional,
              // and Tab still reaches it. The description below is deliberately
              // left alone: it is multi-line, so there Return is a newline.
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_nameError != null) {
                  setState(() => _nameError = null);
                }
              },
              style: SkotiqTypography.body.copyWith(
                color: colors.textPrimary,
              ),
              decoration: InputDecoration(
                labelText: 'Profile Name',
                errorText: _nameError,
                labelStyle: SkotiqTypography.body.copyWith(
                  color: colors.textSecondary,
                ),
                hintText: 'e.g., Deep Sky Rig, Planetary Setup',
                hintStyle: SkotiqTypography.body.copyWith(
                  color: colors.textMuted,
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.primary),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              style: SkotiqTypography.body.copyWith(
                color: colors.textPrimary,
              ),
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Description (optional)',
                labelStyle: SkotiqTypography.body.copyWith(
                  color: colors.textSecondary,
                ),
                hintText: 'Brief description of this setup',
                hintStyle: SkotiqTypography.body.copyWith(
                  color: colors.textMuted,
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.primary),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => Navigator.pop(context),
        ),
        SkotiqButton(
          label: 'Create',
          variant: ButtonVariant.primary,
          size: ButtonSize.small,
          onPressed: _submit,
        ),
      ],
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Enter a profile name.');
      return;
    }
    final description = _descriptionController.text.trim();
    Navigator.pop(
      context,
      (
        name: name,
        description: description.isEmpty ? null : description,
      ),
    );
  }
}

class _DuplicateProfileDialog extends StatefulWidget {
  final SkotiqColors colors;
  final String initialName;

  /// Names already in use. A copy that reuses one is indistinguishable from the
  /// profile it collides with everywhere the app shows a profile, so the dialog
  /// refuses it rather than writing a row the operator cannot identify.
  final List<String> takenNames;

  const _DuplicateProfileDialog({
    required this.colors,
    required this.initialName,
    this.takenNames = const [],
  });

  @override
  State<_DuplicateProfileDialog> createState() =>
      _DuplicateProfileDialogState();
}

class _DuplicateProfileDialogState extends State<_DuplicateProfileDialog> {
  late final TextEditingController _nameController;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return AlertDialog(
      backgroundColor: colors.surface,
      title: Text(
        'Duplicate Profile',
        style: SkotiqTypography.body.copyWith(
          color: colors.textPrimary,
        ),
      ),
      content: TextField(
        controller: _nameController,
        autofocus: true,
        // The dialog is one pre-filled field: Return has to be the way out of
        // it. Without this the focused field swallowed the key and the only
        // path to "Duplicate" was the mouse.
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        onChanged: (_) {
          if (_nameError != null) {
            setState(() => _nameError = null);
          }
        },
        style: SkotiqTypography.body.copyWith(
          color: colors.textPrimary,
        ),
        decoration: InputDecoration(
          labelText: 'New Profile Name',
          errorText: _nameError,
          labelStyle: SkotiqTypography.body.copyWith(
            color: colors.textSecondary,
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: colors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: colors.primary),
          ),
        ),
      ),
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => Navigator.pop(context),
        ),
        SkotiqButton(
          label: 'Duplicate',
          variant: ButtonVariant.primary,
          size: ButtonSize.small,
          onPressed: _submit,
        ),
      ],
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Enter a profile name.');
      return;
    }
    final target = normalizeProfileName(name);
    if (widget.takenNames.any((n) => normalizeProfileName(n) == target)) {
      // Same wording as the equipment editor's duplicate-name gate, so the two
      // surfaces that create profiles refuse a collision the same way.
      setState(
        () => _nameError = 'Another profile is already called "$name"',
      );
      return;
    }
    Navigator.pop(context, name);
  }
}

// Profile list sidebar
