// Observing-list dialog, rows, score badges and candidate chips.
part of '../planner_screen.dart';

/// Host-bound add/create flow for a Planner candidate.
///
/// Keeping the mutation inside the dialog means a failed host write does not
/// dismiss the only place that can explain and retry it. It also prevents a
/// numeric list ID selected on one remote host from being applied to another
/// host after the connection changes.
class _CandidateObservingListDialog extends ConsumerStatefulWidget {
  final TargetSuggestion suggestion;
  final SkotiqColors colors;

  const _CandidateObservingListDialog({
    required this.suggestion,
    required this.colors,
  });

  @override
  ConsumerState<_CandidateObservingListDialog> createState() =>
      _CandidateObservingListDialogState();
}

class _CandidateObservingListDialogState
    extends ConsumerState<_CandidateObservingListDialog> {
  late final TextEditingController _nameController;
  late final SkotiqBackend _authority;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  bool _creating = false;
  bool _saving = false;
  String? _error;

  /// Lists that already contain this target. Empty also means "not known yet /
  /// could not be determined", which is why membership only ever *annotates* a
  /// row — the add path still handles a duplicate gracefully on its own.
  Set<int> _listsContaining = const <int>{};

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _authority = ref.read(backendProvider);
    _loadExistingMembership();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next) || !mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The connected host changed. Adding the target was cancelled.',
            ),
          ),
        );
        closeAuthorityBoundDialog(context);
      },
    );
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    _nameController.dispose();
    super.dispose();
  }

  bool get _isCurrentAuthority =>
      identical(ref.read(backendProvider), _authority);

  /// Mark the lists this target is already in, so the user is not invited to
  /// perform an add that can only be a no-op. Best-effort: a failure leaves
  /// the annotations off rather than blocking the dialog.
  Future<void> _loadExistingMembership() async {
    final catalogId = widget.suggestion.catalogId;
    if (catalogId == null) return;
    try {
      final lists = await ref
          .read(observingListNotifierProvider.notifier)
          .getListsContaining(catalogId);
      if (!mounted || !_isCurrentAuthority) return;
      setState(() {
        _listsContaining = lists.map((list) => list.id).toSet();
      });
    } catch (_) {
      // Membership is an affordance, not a gate — stay silent.
    }
  }

  Future<void> _addToList(int listId) async {
    if (_saving || !_isCurrentAuthority) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    final id = await ref.read(observingListNotifierProvider.notifier).addItem(
          listId: listId,
          objectName: widget.suggestion.targetName,
          catalogId: widget.suggestion.catalogId,
          objectType: widget.suggestion.objectType,
          ra: widget.suggestion.raHours,
          dec: widget.suggestion.decDegrees,
          magnitude: widget.suggestion.magnitude,
          sizeArcmin: widget.suggestion.sizeArcmin,
        );
    if (!mounted || !_isCurrentAuthority) return;

    final uiState = ref.read(observingListNotifierProvider);
    if (id == null) {
      // No row was written. Two very different reasons, and they must not read
      // the same: a genuine write failure sets errorMessage, while "the target
      // is already in this list" sets only a neutral statusMessage — a harmless
      // no-op must not surface as a red Dart exception.
      final alreadyThere =
          uiState.errorMessage == null ? uiState.statusMessage : null;
      if (alreadyThere != null) {
        _showOutcomeAndClose(alreadyThere, success: false);
        return;
      }
      setState(() {
        _saving = false;
        _error =
            uiState.errorMessage ?? 'Could not add the target to this list';
      });
      return;
    }

    _showOutcomeAndClose(
      'Added ${widget.suggestion.targetName} to the list',
      success: true,
    );
  }

  Future<void> _createAndAdd() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a list name');
      return;
    }
    if (_saving || !_isCurrentAuthority) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    final id = await ref
        .read(observingListNotifierProvider.notifier)
        .createListWithItem(
          name: name,
          objectName: widget.suggestion.targetName,
          catalogId: widget.suggestion.catalogId,
          objectType: widget.suggestion.objectType,
          ra: widget.suggestion.raHours,
          dec: widget.suggestion.decDegrees,
          magnitude: widget.suggestion.magnitude,
          sizeArcmin: widget.suggestion.sizeArcmin,
        );
    if (!mounted || !_isCurrentAuthority) return;

    if (id == null) {
      setState(() {
        _saving = false;
        _error = ref.read(observingListNotifierProvider).errorMessage ??
            'Could not create the list and add this target';
      });
      return;
    }

    _showOutcomeAndClose(
      'Created "$name" and added ${widget.suggestion.targetName}',
      success: true,
    );
  }

  /// Close the dialog and report what actually happened. [success] only tints
  /// the toast green for a real write; a benign no-op (already in the list)
  /// gets the default neutral toast rather than a green "success" or a red
  /// "failure".
  void _showOutcomeAndClose(String message, {required bool success}) {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? widget.colors.success : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final listsAsync = ref.watch(observingListsProvider);
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        backgroundColor: widget.colors.surface,
        title: Text(
          'Add to observing list',
          style: SkotiqTypography.body
              .copyWith(color: widget.colors.textPrimary),
        ),
        content: SizedBox(
          width: dialogMaxWidth(context, 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              listsAsync.when(
                loading: () => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(SkotiqTokens.spaceMd),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                error: (error, _) => Text(
                  'Could not load observing lists: $error',
                  style: SkotiqTypography.body
                      .copyWith(color: widget.colors.error),
                ),
                data: (lists) => lists.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'No observing lists yet. Create one to add this target.',
                          style: SkotiqTypography.caption
                              .copyWith(color: widget.colors.textSecondary),
                        ),
                      )
                    : ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: panelWidthFromFraction(
                            MediaQuery.sizeOf(context).height,
                            fraction: 0.35,
                            min: 120,
                            max: 280,
                          ),
                        ),
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final list in lists)
                              _ObservingListRow(
                                name: list.name,
                                colors: widget.colors,
                                alreadyContainsTarget:
                                    _listsContaining.contains(list.id),
                                onTap:
                                    _saving ? null : () => _addToList(list.id),
                              ),
                          ],
                        ),
                      ),
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              if (_creating) ...[
                TextField(
                  controller: _nameController,
                  autofocus: true,
                  enabled: !_saving,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'New list name',
                    errorText: _error == 'Enter a list name' ? _error : null,
                  ),
                  onChanged: (_) {
                    if (_error == 'Enter a list name') {
                      setState(() => _error = null);
                    }
                  },
                  onSubmitted: (_) {
                    if (!_saving) _createAndAdd();
                  },
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                SkotiqButton(
                  label: _saving ? 'Creating…' : 'Create and add',
                  icon: LucideIcons.plus,
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                  onPressed: _saving ? null : _createAndAdd,
                ),
              ] else
                SkotiqButton(
                  label: 'Create new list…',
                  icon: LucideIcons.plus,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                            _creating = true;
                            _error = null;
                          }),
                ),
              if (_error != null && _error != 'Enter a list name') ...[
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                  _error!,
                  style: SkotiqTypography.caption
                      .copyWith(color: widget.colors.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// One selectable observing list inside the add-to-list dialog.
///
/// The rows carry real chrome (icon, border, chevron) so they read as tappable
/// beside the bordered "Create new list…" button below them, and they state
/// plainly when the target is already in a list instead of inviting an add that
/// can only be a no-op.
class _ObservingListRow extends StatelessWidget {
  final String name;
  final SkotiqColors colors;
  final bool alreadyContainsTarget;
  final VoidCallback? onTap;

  const _ObservingListRow({
    required this.name,
    required this.colors,
    required this.alreadyContainsTarget,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !alreadyContainsTarget;
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceMd,
              vertical: SkotiqTokens.spaceSm,
            ),
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              children: [
                Icon(
                  LucideIcons.list,
                  size: 14,
                  color: enabled ? colors.textSecondary : colors.textMuted,
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.body.copyWith(
                        color: enabled
                            ? colors.textPrimary
                            : colors.textSecondary),
                  ),
                ),
                if (alreadyContainsTarget)
                  Row(
                    children: [
                      Icon(LucideIcons.check, size: 12, color: colors.success),
                      const SizedBox(width: 4),
                      Text(
                        'Already added',
                        style: SkotiqTypography.labelQuiet.copyWith(
                          color: colors.success,
                        ),
                      ),
                    ],
                  )
                else
                  Icon(
                    LucideIcons.chevronRight,
                    size: 14,
                    color: colors.textMuted,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The loading placeholder for one candidate. Traces the shape a [Candidate]
/// takes — badge, name, two readouts, window bar, one button — so the list
/// does not reflow when the real rows arrive.
class _CandidateSkeleton extends StatelessWidget {
  final SkotiqColors colors;
  const _CandidateSkeleton({required this.colors});

  /// Placeholder heights, in logical pixels.
  static const double _nameHeight = 14;
  static const double _detailHeight = 12;
  static const double _readoutHeight = 30;
  static const double _buttonHeight = 28;

  /// Width of one readout placeholder.
  static const double _readoutWidth = 90;

  /// Width of the action placeholder.
  static const double _actionWidth = 96;

  /// Width of the window-bar placeholder.
  static const double _windowWidth = 120;

  /// Below this the trailing placeholders are dropped rather than overflowed:
  /// a `Candidate` at a phone width gives its measurements up to the name, and
  /// a skeleton that claimed more would be a wider row than the one it stands
  /// in for.
  static const double _trailingFloor = 560;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _trailingFloor;
        return SkotiqPanel(
          padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
          child: Row(
            children: [
              const SkeletonBox(
                width: Candidate.badgeSize,
                height: Candidate.badgeSize,
                borderRadius: SkotiqTokens.radiusLg,
              ),
              const SizedBox(width: Candidate.columnGap),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SkeletonText(width: 120, height: _nameHeight),
                    SizedBox(height: SkotiqTokens.spaceXs),
                    SkeletonText(width: 220, height: _detailHeight),
                  ],
                ),
              ),
              if (wide) ...const [
                SizedBox(width: Candidate.columnGap),
                SkeletonBox(width: _readoutWidth, height: _readoutHeight),
                SizedBox(width: Candidate.columnGap),
                SkeletonBox(width: _readoutWidth, height: _readoutHeight),
                SizedBox(width: Candidate.columnGap),
                SkeletonBox(
                  width: _windowWidth,
                  height: CandidateWindowBar.trackHeight,
                ),
              ],
              const SizedBox(width: Candidate.columnGap),
              const SkeletonBox(width: _actionWidth, height: _buttonHeight),
            ],
          ),
        );
      },
    );
  }
}
