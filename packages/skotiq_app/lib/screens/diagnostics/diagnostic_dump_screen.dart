import 'dart:io' show Directory;

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../../utils/exported_file_reveal.dart';
import '../../utils/snackbar_helper.dart';

/// Directory the desktop save dialog should open in.
///
/// [chooseExportTarget] forwards a null `initialDirectory` straight to
/// `file_selector.getSaveLocation`, which then opens the picker at the
/// PROCESS working directory — for an installed build that is the application
/// bundle itself (`…/build/linux/x64/release/bundle`, `C:\Program Files\…`),
/// which is typically read-only. The first folder a user in the middle of
/// filing a bug report saw was one they could not save into.
///
/// Downloads first (where browsers and issue trackers expect attachments to
/// live), then Documents. Both are user-writable by definition. Null means
/// "let the platform decide" — only reached if both lookups fail, and the
/// touch branch of [chooseExportTarget] ignores it entirely.
@visibleForTesting
Future<String?> resolveDumpSaveDirectory({
  Future<Directory?> Function() downloadsDirectory = getDownloadsDirectory,
  Future<Directory> Function() documentsDirectory =
      resolveSkotiqDocumentsDirectory,
}) async {
  for (final lookup in <Future<Directory?> Function()>[
    downloadsDirectory,
    documentsDirectory,
  ]) {
    try {
      final directory = await lookup();
      // getDownloadsDirectory throws UnsupportedError on mobile and returns
      // null when the platform has no such folder; neither is an error here.
      // existsSync (one stat, at dialog-open time) rather than the async form:
      // path_provider reports the conventional location without guaranteeing
      // it was ever created.
      if (directory != null && directory.existsSync()) return directory.path;
    } on UnsupportedError {
      continue;
    } on MissingPlatformDirectoryException {
      continue;
    } catch (error, stackTrace) {
      debugPrint(
        'Could not resolve a diagnostic-dump save directory: $error\n'
        '$stackTrace',
      );
      continue;
    }
  }
  return null;
}

/// Bug-report attachment screen.
///
/// One button: produces a zip containing recent logs, the active equipment
/// profile, the currently loaded sequence, system info, and a snapshot of
/// device connection state. The dump is written via a native save dialog so
/// users can drop it directly into a GitHub issue without hunting through
/// the app-data directory.
///
/// The optical-train
/// `DiagnosticsScreen` lives next to this file but covers a different scope;
/// keep them visually distinct (different titles, different icons).
class DiagnosticDumpScreen extends ConsumerStatefulWidget {
  const DiagnosticDumpScreen({super.key});

  @override
  ConsumerState<DiagnosticDumpScreen> createState() =>
      _DiagnosticDumpScreenState();
}

class _DiagnosticDumpScreenState extends ConsumerState<DiagnosticDumpScreen> {
  bool _busy = false;
  String? _lastOutputPath;
  int? _lastOutputBytes;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isMobile = Responsive.isMobile(context);

    // Scrollable: the "Will include" card plus a last-dump result card is
    // taller than a short window, and this screen carries the only control
    // that produces a bug report — it must never be the thing that is clipped.
    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 12 : 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Back to help',
                icon: const Icon(LucideIcons.arrowLeft),
                color: colors.textSecondary,
                onPressed: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    // Tooltip says "Back to help" — land on Help & Tutorials.
                    context.go('/settings?section=help');
                  }
                },
              ),
              const SizedBox(width: 4),
              Icon(LucideIcons.fileArchive, size: 22, color: colors.primary),
              const SizedBox(width: 10),
              Text(
                'Diagnostic Dump',
                style: TextStyle(
                  fontSize: isMobile
                      ? SkotiqTypography.fontSize18
                      : SkotiqTypography.fontSize22,
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Bundle logs, the active equipment profile, the currently '
            'loaded sequence, and system info into a single .zip suitable '
            'for attaching to bug reports. No telemetry is sent — the file '
            'stays on your machine until you share it.',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize13,
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          _ContentsCard(colors: colors),
          const SizedBox(height: 16),
          if (_lastOutputPath != null) ...[
            _LastResultCard(
              path: _lastOutputPath!,
              bytes: _lastOutputBytes,
              colors: colors,
            ),
            const SizedBox(height: 16),
          ],
          Row(
            children: [
              SkotiqButton(
                label: _busy ? 'Building dump…' : 'Create dump',
                icon: LucideIcons.fileArchive,
                onPressed: _busy ? null : _createDump,
                isLoading: _busy,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _createDump() async {
    setState(() {
      _busy = true;
    });
    try {
      // Why suggest a timestamped filename: the user is encouraged to keep
      // multiple dumps (one per repro attempt) without overwriting earlier
      // attachments. Colons get rejected on Windows, hence the replace.
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final suggested = 'skotiq_diagnostic_$stamp.zip';

      // Not a raw save dialog: `file_selector` has no `getSavePath` on
      // Android/iOS, so asking for one there threw UnimplementedError and this
      // whole screen was dead on a phone. On touch platforms the dump lands in
      // the app sandbox and reaches the user through the share sheet below.
      final target = await chooseExportTarget(
        suggestedName: suggested,
        initialDirectory: await resolveDumpSaveDirectory(),
        acceptedTypeGroups: const [
          file_selector.XTypeGroup(
            label: 'Zip archive',
            extensions: ['zip'],
          ),
        ],
      );

      // Only the desktop dialog can be dismissed. Producing a dump the user
      // backed out of would mean silently inventing a path, so we cancel.
      if (target == null) {
        if (mounted) {
          context.showInfoSnackBar('Diagnostic dump cancelled.');
        }
        return;
      }

      final service = ref.read(diagnosticDumpServiceProvider);
      final file = await service.createDump(outputPath: target.path);
      final size = await file.length();

      if (!mounted) return;
      setState(() {
        _lastOutputPath = file.path;
        _lastOutputBytes = size;
      });
      await revealExportedFile(
        context,
        file.path,
        subject: 'Skotiq diagnostic dump',
        desktopMessage:
            'Diagnostic dump written: ${file.path} (${_formatBytes(size)})',
        desktopDuration: const Duration(seconds: 6),
      );
    } catch (e) {
      if (!mounted) return;
      // Surface the failure rather than swallowing it. The service has
      // already logged the structured stack trace via LoggingService.
      context.showErrorSnackBar('Diagnostic dump failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }
}

class _ContentsCard extends StatelessWidget {
  final SkotiqColors colors;

  const _ContentsCard({required this.colors});

  @override
  Widget build(BuildContext context) {
    // State the span the zip actually has. This card said "Recent log files"
    // over an unbounded export (38k lines spanning a week), then said "every
    // daily native log kept on this machine" after the export was bounded to
    // DiagnosticDumpService.logRetentionWindow — wrong in both directions. It
    // is now read from that constant so the two cannot drift again.
    final logHours = DiagnosticDumpService.logRetentionWindow.inHours;
    final items = [
      (
        'Log files',
        'logs/exported_logs.txt — native logs from the last $logHours hours '
            '+ in-app entries. Worth a look before you attach it to a '
            'public issue.'
      ),
      ('Active equipment profile', 'profile.json — devices, optics, defaults'),
      ('Current sequence', 'sequence.json — name, tree shape, node metadata'),
      ('System info', 'system_info.json — OS, Dart version, app version'),
      (
        'Device connection list',
        'devices.json — role + connection state per device'
      ),
      ('Manifest', 'manifest.json — bundle version and per-entry status'),
    ];

    return SkotiqCard(
      variant: CardVariant.subtle,
      borderRadius: SkotiqTokens.radiusInline8,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Will include',
            style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 12),
          for (final entry in items) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(LucideIcons.checkCircle2,
                      size: 16, color: colors.success),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.$1,
                          style: SkotiqTypography.labelStrong
                              .copyWith(color: colors.textPrimary),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          entry.$2,
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize12,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LastResultCard extends StatelessWidget {
  final String path;
  final int? bytes;
  final SkotiqColors colors;

  const _LastResultCard({
    required this.path,
    required this.bytes,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.success),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.checkCircle2, size: 18, color: colors.success),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Last dump',
                  style: SkotiqTypography.labelStrong
                      .copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  path,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textSecondary,
                    fontFamily: 'monospace',
                  ),
                ),
                if (bytes != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Size: ${_formatBytes(bytes!)}',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';
}
