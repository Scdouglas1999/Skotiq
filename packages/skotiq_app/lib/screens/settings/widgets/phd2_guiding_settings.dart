import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:file_selector/file_selector.dart';

import '../../../utils/user_facing_error.dart';
import '../../../widgets/remote_host_path_dialog.dart';
import 'settings_widgets.dart';

class Phd2GuidingSettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const Phd2GuidingSettings({super.key, this.isMobile = false});

  @override
  ConsumerState<Phd2GuidingSettings> createState() =>
      _Phd2GuidingSettingsState();
}

class _Phd2GuidingSettingsState extends ConsumerState<Phd2GuidingSettings> {
  final _portController = TextEditingController();
  final _hostController = TextEditingController();

  bool _testing = false;

  /// Outcome of the last probe: `null` until one has run.
  Phd2ProbeOutcome? _testOutcome;
  String? _testMessage;

  /// The `host:port` the last probe actually used. A result is only shown while
  /// it still matches the configured endpoint, so an edited host/port can never
  /// display an old "PHD2 answered" against a different address.
  String? _testedEndpoint;

  @override
  void dispose() {
    _portController.dispose();
    _hostController.dispose();
    super.dispose();
  }

  static String _endpointOf(AppSettingsState settings) {
    final host = settings.phd2Host.trim().isEmpty
        ? 'localhost'
        : settings.phd2Host.trim();
    return '$host:${settings.phd2Port}';
  }

  /// Complete PHD2's opening handshake on the configured event socket.
  ///
  /// PHD2 is the most failure-prone dependency in the stack and this page was
  /// the only integration page with no way to find out whether it answers. A
  /// bare port probe is not enough to say "PHD2 answered" — any process
  /// holding 4400 passes that — so the result is only reported as PHD2 when
  /// PHD2's own `Version` event comes back, and it names the version and the
  /// equipment profile that replied.
  Future<void> _testConnection(AppSettingsState settings) async {
    if (_testing) return;
    final authority = ref.read(backendProvider);
    final host = settings.phd2Host.trim().isEmpty
        ? 'localhost'
        : settings.phd2Host.trim();
    final port = settings.phd2Port;
    setState(() {
      _testing = true;
      _testOutcome = null;
      _testMessage = null;
      _testedEndpoint = '$host:$port';
    });

    Phd2ProbeOutcome outcome;
    String message;
    try {
      final probe = await ref
          .read(guidingBackendProvider)
          .phd2Probe(host: host, port: port);
      outcome = probe.outcome;
      message = _probeMessage(probe, '$host:$port');
    } catch (e) {
      outcome = Phd2ProbeOutcome.unreachable;
      message = 'Could not reach $host:$port: ${userFacingError(e)}';
    }

    if (!mounted) return;
    // A host switch mid-probe means the answer describes the previous rig.
    if (!identical(ref.read(backendProvider), authority)) {
      setState(() {
        _testing = false;
        _testOutcome = null;
        _testMessage = null;
        _testedEndpoint = null;
      });
      return;
    }
    setState(() {
      _testing = false;
      _testOutcome = outcome;
      _testMessage = message;
    });
  }

  /// Turn a probe outcome into a sentence that claims no more than the probe
  /// established.
  static String _probeMessage(Phd2ProbeResult probe, String endpoint) {
    switch (probe.outcome) {
      case Phd2ProbeOutcome.identified:
        final version = probe.fullVersion;
        final profile = probe.profile;
        final buffer = StringBuffer(
          version == null
              ? 'PHD2 answered on $endpoint.'
              : 'PHD2 $version answered on $endpoint.',
        );
        if (profile != null && profile.isNotEmpty) {
          buffer.write(' Active profile: $profile.');
        }
        return buffer.toString();
      case Phd2ProbeOutcome.unidentified:
        return 'Something is listening on $endpoint but it did not identify '
            'itself as PHD2. Check that the port belongs to PHD2 and that '
            '"Enable Server" is on.';
      case Phd2ProbeOutcome.reachableUnverified:
        return '$endpoint is accepting connections, but this imaging host is '
            'too old to report the PHD2 version.';
      case Phd2ProbeOutcome.unreachable:
        final cause = probe.error;
        final why = (cause == null || cause.isEmpty) ? '' : ' ($cause)';
        return 'No response on $endpoint$why. Is PHD2 running with "Enable '
            'Server" turned on?';
    }
  }

  static IconData _outcomeIcon(Phd2ProbeOutcome outcome) {
    switch (outcome) {
      case Phd2ProbeOutcome.identified:
        return SkotiqIcons.success;
      case Phd2ProbeOutcome.unidentified:
      case Phd2ProbeOutcome.reachableUnverified:
        return SkotiqIcons.warning;
      case Phd2ProbeOutcome.unreachable:
        return SkotiqIcons.error;
    }
  }

  static Color _outcomeColor(BuildContext context, Phd2ProbeOutcome outcome) {
    final colors = SkotiqColors.of(context);
    switch (outcome) {
      case Phd2ProbeOutcome.identified:
        return colors.success;
      case Phd2ProbeOutcome.unidentified:
      case Phd2ProbeOutcome.reachableUnverified:
        return colors.warning;
      case Phd2ProbeOutcome.unreachable:
        return colors.error;
    }
  }

  String _testSubtitle(AppSettingsState settings) {
    if (_testing) {
      return 'Contacting ${_testedEndpoint ?? _endpointOf(settings)}…';
    }
    if (_testMessage != null && _testedEndpoint == _endpointOf(settings)) {
      return _testMessage!;
    }
    return 'Check whether PHD2 is listening on ${_endpointOf(settings)}';
  }

  /// Persist a PHD2 connection field and surface any failure. Mirrors the
  /// path-selector's await+report behaviour so a host/port edit that fails to
  /// persist (e.g. a remote write error) is reported instead of silently lost.
  Future<void> _save(Future<void> Function() write, String what) async {
    try {
      await write();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not save the PHD2 $what: ${userFacingError(e)}',
            ),
          ),
        );
      }
      rethrow;
    }
  }

  Future<void> _selectPhd2Path() async {
    final authority = ref.read(backendProvider);
    final isRemote = ref.read(isRemoteModeProvider);
    String? initialDir;
    if (!isRemote && Platform.isWindows) {
      initialDir = 'C:\\Program Files';
    } else if (!isRemote && Platform.isMacOS) {
      initialDir = '/Applications';
    }

    final settings = ref.read(appSettingsProvider).valueOrNull;
    final String? result;
    if (isRemote) {
      result = await RemoteHostPathDialog.show(
        context,
        title: 'PHD2 executable on imaging host',
        initialPath: settings?.phd2Path,
        hintText: r'C:\Program Files\PHD2\PHD2.exe or /usr/bin/phd2',
        submitLabel: 'Use host path',
        clearLabel: 'Use auto-detect',
      );
    } else {
      final typeGroup = XTypeGroup(
        label: 'PHD2 executable',
        extensions: Platform.isWindows ? const ['exe'] : null,
      );
      result = (await openFile(
        acceptedTypeGroups: [typeGroup],
        initialDirectory: initialDir,
        confirmButtonText: 'Use this PHD2 executable',
      ))
          ?.path;
    }

    if (!mounted) {
      return;
    }
    if (!identical(ref.read(backendProvider), authority)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The imaging host changed while choosing the PHD2 path. '
            'Choose it again for the current host.',
          ),
        ),
      );
      return;
    }

    if (result != null) {
      try {
        await ref.read(appSettingsProvider.notifier).setPhd2Path(result);
      } catch (e) {
        if (mounted && identical(ref.read(backendProvider), authority)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Could not save the PHD2 path: ${userFacingError(e)}',
              ),
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      loading: () => SettingsLoadingState(
        isMobile: widget.isMobile,
      ),
      error: (error, stack) => SettingsErrorState(
        isMobile: widget.isMobile,
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        final authority = ref.watch(backendProvider);

        return SettingsPage(
          title: 'PHD2 guiding',
          description: 'Configure PHD2 guiding software connection',
          children: [
            SettingsSection(
              title: 'PHD2 connection',
              children: [
                SettingRow(
                  icon: LucideIcons.server,
                  title: 'Host',
                  subtitle: 'PHD2 server hostname or IP address',
                  trailing: SettingsTextInput(
                    controller: _hostController,
                    authoritativeValue: settings.phd2Host,
                    authorityKey: authority,
                    hint: 'localhost',
                    onChanged: (value) => _save(
                      () => ref
                          .read(appSettingsProvider.notifier)
                          .setPhd2Host(value),
                      'host',
                    ),
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.network,
                  title: 'Port',
                  subtitle: 'PHD2 server port (default: 4400)',
                  trailing: SettingsNumberInput(
                    controller: _portController,
                    authoritativeValue: settings.phd2Port.toDouble(),
                    authorityKey: authority,
                    suffix: '',
                    min: 1,
                    max: 65535,
                    decimals: 0,
                    onChanged: (value) => _save(
                      () => ref
                          .read(appSettingsProvider.notifier)
                          .setPhd2Port(value.toInt()),
                      'port',
                    ),
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.folder,
                  title: 'PHD2 executable path',
                  subtitle: settings.phd2Path.isEmpty
                      ? 'Auto-detect (optional)'
                      : settings.phd2Path,
                  trailing: SettingsPathInput(
                    key: const ValueKey('phd2_executable_path'),
                    path: settings.phd2Path,
                    authorityKey: authority,
                    onBrowse: _selectPhd2Path,
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.plugZap,
                  title: 'Test connection',
                  subtitle: _testSubtitle(settings),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_testOutcome != null &&
                          _testedEndpoint == _endpointOf(settings))
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Icon(
                            _outcomeIcon(_testOutcome!),
                            size: 18,
                            // "Something answered but it was not PHD2" is
                            // neither a pass nor a dead socket, so it gets the
                            // warning glyph rather than being rounded to one.
                            color: _outcomeColor(context, _testOutcome!),
                          ),
                        ),
                      SkotiqButton(
                        label: 'Test connection',
                        variant: ButtonVariant.secondary,
                        size: ButtonSize.small,
                        isLoading: _testing,
                        onPressed:
                            _testing ? null : () => _testConnection(settings),
                      ),
                    ],
                  ),
                  isLast: true,
                ),
              ],
            ),
            SettingsSection(
              title: 'Information',
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'PHD2 will be automatically detected on common installation paths if not specified. '
                    'The connection settings are used when connecting to PHD2 for guiding operations.',
                    style: SkotiqTypography.bodySm.copyWith(
                      color: SkotiqColors.of(context).textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
