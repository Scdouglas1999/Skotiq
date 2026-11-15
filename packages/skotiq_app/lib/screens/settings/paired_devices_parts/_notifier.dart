// Pairing state, notifier and its provider.
part of '../pairing_screen.dart';

/// Provider for pairing state management
final pairingProvider =
    StateNotifierProvider<PairingNotifier, PairingState>((ref) {
  return PairingNotifier();
});

/// Pairing state
class PairingState {
  final String? pairingCode;
  final DateTime? expiresAt;
  final List<PairedDevice> pairedDevices;
  final bool isLoading;
  final String? error;

  /// The device that just consumed the outstanding pairing code, if any.
  ///
  /// This is the operator's only way to know that the phone in their hand is
  /// the thing that connected. Without it the desktop kept counting down a
  /// code the server had already destroyed, and the device list stayed a
  /// refresh behind.
  final PairedDevice? lastPairedDevice;

  PairingState({
    this.pairingCode,
    this.expiresAt,
    this.pairedDevices = const [],
    this.isLoading = false,
    this.error,
    this.lastPairedDevice,
  });

  PairingState copyWith({
    Object? pairingCode = _pairingUnset,
    Object? expiresAt = _pairingUnset,
    List<PairedDevice>? pairedDevices,
    bool? isLoading,
    Object? error = _pairingUnset,
    Object? lastPairedDevice = _pairingUnset,
  }) {
    return PairingState(
      pairingCode: identical(pairingCode, _pairingUnset)
          ? this.pairingCode
          : pairingCode as String?,
      expiresAt: identical(expiresAt, _pairingUnset)
          ? this.expiresAt
          : expiresAt as DateTime?,
      pairedDevices: pairedDevices ?? this.pairedDevices,
      isLoading: isLoading ?? this.isLoading,
      error: identical(error, _pairingUnset) ? this.error : error as String?,
      lastPairedDevice: identical(lastPairedDevice, _pairingUnset)
          ? this.lastPairedDevice
          : lastPairedDevice as PairedDevice?,
    );
  }

  Duration? get timeRemaining {
    if (expiresAt == null) return null;
    final remaining = expiresAt!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }
}

/// Pairing state notifier
class PairingNotifier extends StateNotifier<PairingState> {
  Timer? _expirationTimer;
  Timer? _countdownTimer;
  final TokenManager _tokenManager;
  final PairingDatabase _database;
  final bool _ownsDatabase;
  late Future<void> _operationTail;
  int _queuedOperations = 0;

  /// deviceId -> pairedAt for every device known when the outstanding code was
  /// issued. A completed pairing is recognised by joining on deviceId (a
  /// re-pair deletes and re-adds the same id, so the timestamp is part of the
  /// identity) — never by comparing list lengths, which proves nothing about
  /// which row is new.
  Map<String, DateTime> _devicesWhenCodeIssued = const {};
  bool _completionCheckInFlight = false;

  PairingNotifier()
      : this._(
          PairingDatabase(),
          ownsDatabase: true,
        );

  /// Test/integration constructor for callers that already own a database.
  PairingNotifier.withDatabase(PairingDatabase database)
      : this._(database, ownsDatabase: false);

  PairingNotifier._(
    this._database, {
    required bool ownsDatabase,
  })  : _tokenManager = TokenManager(_database),
        _ownsDatabase = ownsDatabase,
        super(PairingState(isLoading: true)) {
    final initialization = _initialize();
    _operationTail = initialization.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
  }

  Future<void> _initialize() async {
    try {
      final devices = await _tokenManager.getActivePairedDevices();
      if (!mounted) return;
      state = state.copyWith(
        pairedDevices: devices,
        isLoading: _queuedOperations > 0,
        error: null,
      );
    } catch (_) {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: _queuedOperations > 0,
        error: 'pairingErrorLoad',
      );
    }
  }

  Future<bool> _enqueue(Future<bool> Function() operation) {
    if (_queuedOperations > 0) return Future<bool>.value(false);
    _queuedOperations += 1;
    if (mounted) state = state.copyWith(isLoading: true, error: null);
    final result = _operationTail.then((_) => operation());
    final tracked = result.whenComplete(() {
      _queuedOperations -= 1;
      if (mounted && _queuedOperations == 0) {
        state = state.copyWith(isLoading: false);
      }
    });
    _operationTail = tracked.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return tracked;
  }

  /// Start a new pairing session
  Future<bool> startPairing() {
    return _enqueue(() async {
      if (!mounted) return false;
      try {
        final code = await _tokenManager.startPairing();
        if (!mounted) return false;
        final expiresAt = DateTime.now().add(const Duration(minutes: 5));

        // Snapshot BEFORE the code can be used, so the device that consumes it
        // can be identified rather than guessed at.
        final known = await _tokenManager.getActivePairedDevices();
        if (!mounted) return false;
        _devicesWhenCodeIssued = {
          for (final device in known) device.deviceId: device.pairedAt,
        };

        state = state.copyWith(
          pairingCode: code,
          expiresAt: expiresAt,
          pairedDevices: known,
          lastPairedDevice: null,
          error: null,
        );

        _startCountdownTimers();
        return true;
      } catch (_) {
        if (mounted) {
          state = state.copyWith(
            error: 'pairingErrorStart',
          );
        }
        return false;
      }
    });
  }

  void _startCountdownTimers() {
    // Set expiration timer
    _expirationTimer?.cancel();
    _expirationTimer = Timer(const Duration(minutes: 5), () {
      if (!mounted) return;
      state = state.copyWith(pairingCode: null, expiresAt: null);
    });

    // Start countdown timer for UI updates
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        _countdownTimer?.cancel();
        return;
      }
      state = state.copyWith(); // Trigger rebuild for countdown
      if (state.timeRemaining?.inSeconds == 0) {
        _countdownTimer?.cancel();
      }
      // The HTTP pairing endpoint runs against the same database file from a
      // separate PairingDatabase instance, so there is no Drift stream to
      // listen to and nothing pushes completion at this notifier. Ask, on the
      // same cadence the countdown already ticks at.
      unawaited(_checkPairingCompleted());
    });
  }

  /// Detect that the outstanding code has been consumed and say so.
  ///
  /// `completePairing` marks the session used and then deletes used sessions,
  /// so a missing (or used) row means the credential on screen is dead. Showing
  /// a live countdown for it is a false statement, and it invites the operator
  /// to read the dead code to a second device.
  Future<void> _checkPairingCompleted() async {
    if (!mounted || _completionCheckInFlight || _queuedOperations > 0) return;
    final code = state.pairingCode;
    if (code == null) return;
    _completionCheckInFlight = true;
    try {
      final session = await _database.getPairingSession(code);
      if (!mounted || state.pairingCode != code) return;
      if (session != null && !session.isUsed) return; // still outstanding

      final devices = await _tokenManager.getActivePairedDevices();
      if (!mounted || state.pairingCode != code) return;

      PairedDevice? paired;
      for (final device in devices) {
        final previous = _devicesWhenCodeIssued[device.deviceId];
        if (previous == null || previous != device.pairedAt) {
          paired = device;
          break;
        }
      }

      _expirationTimer?.cancel();
      _countdownTimer?.cancel();
      state = state.copyWith(
        pairingCode: null,
        expiresAt: null,
        pairedDevices: devices,
        lastPairedDevice: paired,
        error: null,
      );
    } catch (_) {
      // A transient read failure must never destroy a still-live code; the
      // next tick tries again.
    } finally {
      _completionCheckInFlight = false;
    }
  }

  /// Adopt a freshly-read device list, dropping a confirmation banner whose
  /// device is no longer paired.
  ///
  /// "WaveD Test Phone paired" sat at the top of the page while the list below
  /// it read "No paired devices" — the operator had just revoked that very
  /// device, and the page told them both things at once. The banner is a
  /// statement about a row; when the row goes, so does the statement.
  PairingState _adoptDevices(List<PairedDevice> devices) {
    final banner = state.lastPairedDevice;
    final stillPaired =
        banner != null && devices.any((d) => d.deviceId == banner.deviceId);
    return state.copyWith(
      pairedDevices: devices,
      error: null,
      lastPairedDevice: stillPaired ? banner : null,
    );
  }

  /// Dismiss the "device paired" confirmation.
  void clearLastPairedDevice() {
    if (!mounted) return;
    state = state.copyWith(lastPairedDevice: null);
  }

  /// Cancel the current pairing session.
  ///
  /// The code remains visible if durable invalidation fails, so the operator
  /// is never told a still-live credential was cancelled.
  Future<bool> cancelPairing() {
    return _enqueue(() async {
      if (!mounted) return false;
      final code = state.pairingCode;
      if (code == null) {
        return true;
      }

      try {
        await _tokenManager.cancelPairing(code);
        if (!mounted) return false;
        _expirationTimer?.cancel();
        _countdownTimer?.cancel();
        state = state.copyWith(
          pairingCode: null,
          expiresAt: null,
          error: null,
        );
        return true;
      } catch (_) {
        if (mounted) {
          state = state.copyWith(
            error: 'pairingErrorCancel',
          );
        }
        return false;
      }
    });
  }

  /// Load paired devices from database.
  Future<bool> loadPairedDevices() {
    return _enqueue(() async {
      if (!mounted) return false;
      try {
        final devices = await _tokenManager.getActivePairedDevices();
        if (!mounted) return false;
        state = _adoptDevices(devices);
        return true;
      } catch (_) {
        if (mounted) {
          state = state.copyWith(
            error: 'pairingErrorLoad',
          );
        }
        return false;
      }
    });
  }

  /// Revoke a paired device.
  Future<bool> revokeDevice(String deviceId) {
    return _enqueue(() async {
      if (!mounted) return false;
      try {
        await _tokenManager.revokeDevice(deviceId);
        final devices = await _tokenManager.getActivePairedDevices();
        if (!mounted) return false;
        state = _adoptDevices(devices);
        return true;
      } catch (_) {
        if (mounted) {
          state = state.copyWith(
            error: 'pairingErrorRevoke',
          );
        }
        return false;
      }
    });
  }

  /// Revoke every paired device in one action.
  ///
  /// The paired list is the operator's only view of "who may drive my
  /// telescope from the network", and it can be inherited wholesale from an
  /// earlier install. Cutting that off must be one decision: revoking a dozen
  /// rows one row-menu at a time is how the one that mattered gets missed.
  /// Returns false when there was nothing to revoke, so the caller never
  /// reports a revocation that did not happen.
  Future<bool> revokeAll() {
    return _enqueue(() async {
      if (!mounted) return false;
      try {
        final revoked = await _tokenManager.revokeAllDevices();
        final devices = await _tokenManager.getActivePairedDevices();
        if (!mounted) return false;
        state = _adoptDevices(devices);
        return revoked > 0;
      } catch (_) {
        if (mounted) {
          state = state.copyWith(
            error: 'pairingErrorRevokeAll',
          );
        }
        return false;
      }
    });
  }

  /// Give a paired device a name the operator will recognise.
  ///
  /// Every phone pairs under a fixed per-platform name ("Android companion"),
  /// so the list is a stack of identical rows and revoking the handset you sold
  /// is guesswork. The name is the only field the host owns outright, so this
  /// is where that is settled; nothing about the device's token or grant
  /// changes.
  Future<bool> renameDevice(String deviceId, String deviceName) {
    final name = deviceName.trim();
    if (name.isEmpty) return Future<bool>.value(false);
    return _enqueue(() async {
      if (!mounted) return false;
      try {
        if (!await _tokenManager.renameDevice(deviceId, name)) {
          // The row is gone (deleted from another surface); say so rather than
          // reporting a rename that changed nothing.
          if (mounted) {
            final devices = await _tokenManager.getActivePairedDevices();
            if (mounted) state = state.copyWith(pairedDevices: devices);
          }
          return false;
        }
        final devices = await _tokenManager.getActivePairedDevices();
        if (!mounted) return false;
        state = _adoptDevices(devices);
        return true;
      } catch (_) {
        if (mounted) {
          state = state.copyWith(
            error: 'pairingErrorRename',
          );
        }
        return false;
      }
    });
  }

  /// Delete a paired device.
  Future<bool> deleteDevice(String deviceId) {
    return _enqueue(() async {
      if (!mounted) return false;
      try {
        await _tokenManager.deleteDevice(deviceId);
        final devices = await _tokenManager.getActivePairedDevices();
        if (!mounted) return false;
        state = _adoptDevices(devices);
        return true;
      } catch (_) {
        if (mounted) {
          state = state.copyWith(
            error: 'pairingErrorDelete',
          );
        }
        return false;
      }
    });
  }

  void clearError() {
    state = state.copyWith(error: null);
  }

  @override
  void dispose() {
    _expirationTimer?.cancel();
    _countdownTimer?.cancel();
    if (_ownsDatabase) {
      final pending = _operationTail;
      unawaited(pending.whenComplete(_database.close));
    }
    super.dispose();
  }
}
