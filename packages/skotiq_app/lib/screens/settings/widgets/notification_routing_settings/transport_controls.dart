part of '../notification_routing_settings.dart';

class _TransportsSection extends ConsumerWidget {
  final bool isMobile;

  const _TransportsSection({required this.isMobile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _EmailTransportSection(isMobile: isMobile),
        _WebhookTransportSection(isMobile: isMobile),
        _PushoverRoutingSection(isMobile: isMobile),
        _TelegramTransportSection(isMobile: isMobile),
        _DiscordRoutingSection(isMobile: isMobile),
        _MqttTransportSection(isMobile: isMobile),
        _HomeAssistantSection(isMobile: isMobile),
      ],
    );
  }
}

// Common helper: secure-field row

/// Masked input for secrets stored in flutter_secure_storage.
///
/// When a secret value is already in the store (controller has non-empty
/// text), the row renders a masked placeholder ("•••••••• (stored
/// securely)") and a "Replace" button. Tapping Replace switches the row
/// into edit mode with an empty text field; the user types a new value
/// and the next Save click writes it through the typed config's `save`
/// notifier, which in turn writes the secret via [SecretsStore].
class _SecretFieldRow extends StatefulWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final TextEditingController controller;

  /// `true` when the underlying store already has a non-empty value for
  /// this secret. Controls the masked-vs-edit initial state.
  final bool hasStoredValue;

  /// Optional hint shown while editing (e.g. "your bot token").
  final String? hint;

  final bool isMobile;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  const _SecretFieldRow({
    required this.icon,
    required this.title,
    required this.controller,
    required this.hasStoredValue,
    required this.isMobile,
    this.subtitle,
    this.hint,
    this.onChanged,
    this.onClear,
  });

  @override
  State<_SecretFieldRow> createState() => _SecretFieldRowState();
}

class _SecretFieldRowState extends State<_SecretFieldRow> {
  /// `true` once the user clicks Replace OR if no value was stored yet
  /// (in which case there's nothing to mask).
  late bool _editing;

  @override
  void initState() {
    super.initState();
    _editing = !widget.hasStoredValue;
  }

  @override
  void didUpdateWidget(covariant _SecretFieldRow old) {
    super.didUpdateWidget(old);
    // If the store gains a value (e.g. after Save), drop back to masked
    // mode so the new value isn't shown.
    if (!old.hasStoredValue && widget.hasStoredValue) {
      setState(() => _editing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    if (_editing) {
      return SettingRow(
        icon: widget.icon,
        title: widget.title,
        subtitle: widget.subtitle,
        trailing: settingsTrailingTextInput(
          context: context,
          controller: widget.controller,
          hint: widget.hint ?? '',
          isMobile: widget.isMobile,
          obscure: true,
          onChanged: widget.onChanged,
        ),
      );
    }

    // Masked + Replace
    return SettingRow(
      icon: widget.icon,
      title: widget.title,
      subtitle: widget.subtitle ?? 'Stored securely in the OS keyring.',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Flexible: the Observatory small button is wider than the one this
          // row was laid out against (13px label, not 11), and the masked
          // secret is the part of the pair that can give ground.
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: colors.well,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                border: Border.all(color: colors.border),
              ),
              child: Text(
                '•••••••• (stored securely)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SkotiqTypography.readoutXs.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SkotiqButton(
            label: 'Replace',
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () {
              widget.controller.text = '';
              widget.onChanged?.call('');
              setState(() => _editing = true);
            },
          ),
          if (widget.onClear != null) ...[
            const SizedBox(width: 6),
            SkotiqButton(
              label: 'Clear',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () {
                widget.controller.clear();
                widget.onClear!();
                setState(() => _editing = true);
              },
            ),
          ],
        ],
      ),
    );
  }
}

// Common helper: form-preparation contract

/// Outcome of validating (and, on success, persisting) a transport's
/// on-screen form before a Save or a Test-send.
///
/// [ok] gates whether the caller proceeds — Save only announces success and
/// Test only actually probes when it is `true`. [message] is a human-facing
/// reason shown when it is `false`. The raw field values are never echoed
/// into [message]; some fields (webhook URLs, tokens) are secrets.
class _PrepResult {
  final bool ok;
  final String? message;

  const _PrepResult.ok()
      : ok = true,
        message = null;
  const _PrepResult.fail(this.message) : ok = false;
}

// Common helper: retryable transport-config error card

/// Shared error state for a transport section whose config provider failed to
/// load: a corrupt or unavailable stored blob surfaces as an error rather than
/// silently reverting to defaults. Renders the failure detail and a Retry that
/// re-runs the provider's build. The persisted blob holds only non-secret
/// fields — credentials live in the OS keyring — so surfacing [error] cannot
/// leak a secret. Each section resets its controller-initialisation flag before
/// showing this, so a retry that loads a changed config re-seeds the fields.
Widget _transportErrorSection({
  required String title,
  required Object error,
  required VoidCallback onRetry,
}) {
  return SettingsSection(
    title: title,
    children: [
      SettingRow(
        icon: LucideIcons.alertTriangle,
        title: 'Could not load configuration',
        subtitle: error.toString(),
        trailing: SkotiqButton(
          label: 'Retry',
          icon: LucideIcons.refreshCw,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: onRetry,
        ),
        isLast: true,
      ),
    ],
  );
}

// Common helpers: pure field validators
//
// Shared by every transport section so validation semantics ("empty = the
// conventional default", "non-blank must be well-formed") are identical
// across the panel and can only drift in one place.

/// Parse a user-entered TCP port field. An empty field means "use the
/// transport's conventional default" ([defaultPort]); a non-empty field must
/// be a whole number in the valid range 1..65535. Returns a record with
/// exactly one of [port] / [error] populated — a malformed or out-of-range
/// value yields an [error] so the caller can refuse to persist or test stale
/// config rather than silently coercing to the default.
({int? port, String? error}) _parsePortField(
  String raw, {
  required int defaultPort,
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return (port: defaultPort, error: null);
  final parsed = int.tryParse(trimmed);
  if (parsed == null || parsed < 1 || parsed > 65535) {
    return (port: null, error: 'Enter a valid port (1-65535).');
  }
  return (port: parsed, error: null);
}

({int? value, String? error}) _parseNonNegativeIntField(
  String raw, {
  required String label,
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return (value: 0, error: null);
  final parsed = int.tryParse(trimmed);
  if (parsed == null || parsed < 0) {
    return (
      value: null,
      error: '$label must be a non-negative whole number.',
    );
  }
  return (value: parsed, error: null);
}

/// Validate a user-entered URL field for the URL-based transports.
///
/// A blank field is allowed when [required] is false — clearing the URL is
/// the supported way to disable the transport (mirrors each config's
/// `isConfigured`). A non-blank value must be an absolute `http`/`https` URL
/// with a host. Returns an error message to show, or `null` when acceptable.
/// The raw value is never echoed back (it may be a secret webhook URL).
String? _validateUrlField(String raw, {bool required = false}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return required ? 'Enter a URL.' : null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !uri.isAbsolute ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return 'Enter a valid http(s) URL.';
  }
  return null;
}

String? _validateEmailAddress(String raw) {
  final value = raw.trim();
  final at = value.lastIndexOf('@');
  if (at <= 0 || at == value.length - 1 || value.contains(RegExp(r'\s'))) {
    return 'Enter a valid email address.';
  }
  return null;
}

/// Parse the generic-webhook "Headers" text area (one `Name: value` per
/// line). Blank lines are ignored. A non-blank line without a colon, or with
/// a blank name, is a user error surfaced (with the 1-based line number)
/// rather than silently dropped. Values may contain additional colons (the
/// split is on the first colon only). Returns a record with exactly one of
/// [headers] / [error] populated.
({Map<String, String>? headers, String? error}) _parseHeaderLines(String raw) {
  final headers = <String, String>{};
  final lowerNames = <String>{};
  final lines = raw.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) continue;
    final idx = line.indexOf(':');
    if (idx < 0) {
      return (
        headers: null,
        error: 'Header line ${i + 1} must be in "Name: value" form.',
      );
    }
    final name = line.substring(0, idx).trim();
    if (name.isEmpty) {
      return (
        headers: null,
        error: 'Header line ${i + 1} is missing a name before ":".',
      );
    }
    if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(name)) {
      return (
        headers: null,
        error: 'Header line ${i + 1} has an invalid HTTP header name.',
      );
    }
    if (!lowerNames.add(name.toLowerCase())) {
      return (
        headers: null,
        error: 'Header line ${i + 1} duplicates an earlier header.',
      );
    }
    headers[name] = line.substring(idx + 1).trim();
  }
  return (headers: headers, error: null);
}

String? _validateWebhookBodyTemplate(String raw) {
  if (raw.trim().isEmpty) return null;
  final rendered = raw
      .replaceAll(r'${title}', 'Skotiq test')
      .replaceAll(r'${body}', 'Test notification')
      .replaceAll(r'${category}', 'custom')
      .replaceAll(r'${timestamp}', '2026-01-01T00:00:00.000Z');
  try {
    jsonDecode(rendered);
  } catch (_) {
    return 'Body template must render valid JSON.';
  }
  return null;
}

// Common helper: save button with truthful saving state

/// Shared Save control for the transport sections. Owns the "saving…" state,
/// a synchronous duplicate-submit guard, and error handling so each section's
/// Save row stays a single line.
///
/// [onSave] validates + persists the on-screen form and returns whether it
/// succeeded; [successMessage] is only announced after persistence actually
/// completes, a validation failure surfaces its own message, and a thrown
/// persistence error is caught and shown (leaving the entered text intact and
/// the button retryable).
class _SaveButton extends StatefulWidget {
  final String successMessage;
  final Future<_PrepResult> Function() onSave;

  const _SaveButton({
    required this.successMessage,
    required this.onSave,
  });

  @override
  State<_SaveButton> createState() => _SaveButtonState();
}

class _SaveButtonState extends State<_SaveButton> {
  bool _busy = false;

  /// Synchronous re-entrancy guard. A second tap that lands before the first
  /// `setState` has rebuilt the (now disabled) button is rejected here, so a
  /// double tap can never issue duplicate keyring/DAO writes.
  bool _inFlight = false;

  Future<void> _run() async {
    if (_inFlight) return;
    _inFlight = true;
    setState(() => _busy = true);
    _PrepResult result;
    try {
      result = await widget.onSave();
    } catch (_) {
      result = const _PrepResult.fail('Could not save. Please try again.');
    } finally {
      _inFlight = false;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          result.ok ? widget.successMessage : (result.message ?? 'Failed.')),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SkotiqButton(
      label: 'Save',
      variant: ButtonVariant.secondary,
      size: ButtonSize.small,
      isLoading: _busy,
      onPressed: _busy ? null : _run,
    );
  }
}

// Common helper: test-send button with inline result

class _TestSendButton extends ConsumerStatefulWidget {
  final NotificationTransportKind kind;

  /// Validates + persists the current form edits before the test send so the
  /// probe uses the on-screen configuration rather than the last-saved
  /// transport. When it returns a failing [_PrepResult] (or throws), the send
  /// is aborted and the failure is shown — the button never claims a test used
  /// the on-screen draft when preparation did not succeed.
  final Future<_PrepResult> Function()? onBeforeSend;

  const _TestSendButton({required this.kind, this.onBeforeSend});

  @override
  ConsumerState<_TestSendButton> createState() => _TestSendButtonState();
}

class _TestSendButtonState extends ConsumerState<_TestSendButton> {
  bool _busy = false;

  /// Synchronous re-entrancy guard (see [_SaveButtonState._inFlight]).
  bool _inFlight = false;
  NotificationResult? _result;

  Future<void> _run() async {
    if (_inFlight) return;
    _inFlight = true;
    setState(() => _busy = true);
    NotificationResult res;
    try {
      final prep = widget.onBeforeSend == null
          ? const _PrepResult.ok()
          : await widget.onBeforeSend!();
      if (!prep.ok) {
        // Preparation (validation or persistence) failed — do NOT send, so we
        // never report a successful test against invalid or stale config.
        res = NotificationResult.fail(
            prep.message ?? 'Fix the form before testing.');
      } else {
        final router = ref.read(notificationRouterProvider);
        res = await router.sendTest(widget.kind);
      }
    } catch (_) {
      res = NotificationResult.fail('Test could not be completed.');
    } finally {
      _inFlight = false;
    }
    if (!mounted) return;
    setState(() {
      _result = res;
      _busy = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        res.success
            ? 'Test sent via ${widget.kind.label}'
            : 'Failed: ${res.error}',
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_result != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Icon(
              _result!.success ? SkotiqIcons.success : SkotiqIcons.error,
              size: 18,
              color: _result!.success
                  ? SkotiqColors.of(context).success
                  : SkotiqColors.of(context).error,
            ),
          ),
        SkotiqButton(
          label: 'Send test',
          variant: ButtonVariant.primary,
          size: ButtonSize.small,
          isLoading: _busy,
          onPressed: _busy ? null : _run,
        ),
      ],
    );
  }
}

// Email
