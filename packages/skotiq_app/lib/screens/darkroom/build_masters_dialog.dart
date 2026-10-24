import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';
import '../accessible_dropdown.dart';
import '../session_review/widgets/sub_cull_rail.dart' show subThumbnailProvider;
import 'package:url_launcher/url_launcher.dart';

const _fitsFiles =
    XTypeGroup(label: 'FITS images', extensions: ['fits', 'fit', 'fts']);

/// A build remains in this dialog until it is finished or stopped. Its disk
/// journal can be reopened after an application restart.
class BuildMastersDialog extends ConsumerStatefulWidget {
  const BuildMastersDialog({super.key});
  @override
  ConsumerState<BuildMastersDialog> createState() => _BuildMastersDialogState();
}

class _BuildMastersDialogState extends ConsumerState<BuildMastersDialog> {
  final _targets = <String, List<DbCapturedImage>>{};
  List<DbCapturedImage> _frames = [];
  List<DarkroomBuildGroup> _groups = [];
  final Set<int> _excluded = {};
  String? _target;
  String? _reference;
  String? _directory;
  DarkroomBuildPlan? _plan;
  Map<String, dynamic>? _report;
  bool _busy = true;
  bool _running = false;
  bool _reviewed = false;
  double _overlap = .95;
  double _eccentricity = .65;
  String _progress = 'Reading captured lights';
  String? _error;
  StreamSubscription? _progressSubscription;
  DarkroomBuildService get _service => ref.read(darkroomBuildServiceProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    super.dispose();
  }

  Future<void> _action(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _action(() async {
        final images = await ref.read(imagesDaoProvider).getAllImages();
        final targets = await ref.read(targetsDaoProvider).getAllTargets();
        final names = {for (final t in targets) t.id: t.name};
        for (final f
            in images.where((f) => f.frameType.toLowerCase() == 'light')) {
          var name = names[f.targetId];
          if (name == null) {
            try {
              name = FitsHeaderReader.stringValue(
                  await const FitsHeaderReader().readPrimaryHeader(f.filePath),
                  'OBJECT');
            } catch (_) {
              /* Unreadable files remain visible under their session. */
            }
          }
          name ??= 'Session ${f.sessionId ?? 'unassigned'}';
          _targets.putIfAbsent(name, () => []).add(f);
        }
      });

  Future<void> _prepare() => _action(() async {
        _progress = 'Matching calibration by night and equipment';
        _groups = await _service
            .prepare(_frames.where((f) => !_excluded.contains(f.id)).toList());
        if (_groups.isEmpty) {
          throw StateError('No accepted light frames remain.');
        }
        final candidates = _groups.expand((g) => g.frames).toList()
          ..sort((a, b) {
            final lA = (a.filter ?? '').toLowerCase() == 'l';
            final lB = (b.filter ?? '').toLowerCase() == 'l';
            if (lA != lB) return lA ? -1 : 1;
            return (b.qualityScore ?? 0).compareTo(a.qualityScore ?? 0);
          });
        _reference = candidates.first.filePath;
        _reviewed = false;
      });

  Future<void> _pickMaster(DarkroomBuildGroup group, String kind) =>
      _action(() async {
        final file = await openFile(acceptedTypeGroups: [_fitsFiles]);
        if (file != null) {
          group.calibration[kind] = file.path;
          if (kind == 'dark') {
            group.calibration.remove('bias');
          }
          if (kind == 'bias') {
            group.calibration.remove('dark');
          }
          _reviewed = false;
        }
      });

  Future<void> _buildCalibration(DarkroomBuildGroup group, String kind) =>
      _action(() async {
        final files = await openFiles(acceptedTypeGroups: [_fitsFiles]);
        if (files.isEmpty) return;
        final folder = await getDirectoryPath(
            confirmButtonText: 'Save calibration master here');
        if (folder == null) return;
        final output = p.join(
            folder, '${kind}_${DateTime.now().microsecondsSinceEpoch}.fits');
        if (kind == 'flat') {
          // A bias/dark-flat must be chosen deliberately; a long light dark is
          // never silently used to calibrate short flats.
          final bias = await openFile(
              acceptedTypeGroups: [_fitsFiles],
              confirmButtonText: 'Select master bias or dark-flat');
          if (bias == null) {
            throw StateError(
                'Select a matching master bias or dark-flat before building flats.');
          }
          await _service.buildCalibration(
              kind: kind,
              paths: files.map((f) => f.path).toList(),
              output: output,
              bias: bias.path);
        } else {
          await _service.buildCalibration(
              kind: kind,
              paths: files.map((f) => f.path).toList(),
              output: output);
        }
        group.calibration[kind] = output;
        if (kind == 'dark') {
          group.calibration.remove('bias');
        }
        if (kind == 'bias') {
          group.calibration.remove('dark');
        }
        _reviewed = false;
      });

  Future<void> _start() => _action(() async {
        _progress = 'Checking calibration choices';
        await _service.checkCalibration(_groups);
        final parent =
            await getDirectoryPath(confirmButtonText: 'Save masters here');
        if (parent == null) return;
        _directory =
            p.join(parent, 'Skotiq-${DateTime.now().microsecondsSinceEpoch}');
        _plan = _service.plan(
            target: _target!,
            groups: _groups,
            referencePath: _reference!,
            minOverlap: _overlap,
            maxEccentricity: _eccentricity,
            excluded: [
              for (final f in _frames
                  .where((f) => !f.isAccepted || _excluded.contains(f.id)))
                {
                  'filter': f.filter,
                  'path': f.filePath,
                  'reason': f.isAccepted
                      ? 'Excluded during review'
                      : f.rejectionReason ?? 'Capture quality rejection'
                }
            ]);
        await _run();
      });

  Future<void> _resume() => _action(() async {
        _progress = 'Opening saved build';
        final folder = await getDirectoryPath(
            confirmButtonText: 'Resume this Skotiq build');
        if (folder == null) return;
        final saved =
            jsonDecode(await File(p.join(folder, 'plan.json')).readAsString())
                as Map;
        _plan = DarkroomBuildPlan.fromJson(
            Map<String, dynamic>.from(saved['plan'] as Map));
        _directory = folder;
        await _run();
      });

  Future<void> _run() async {
    setState(() {
      _running = true;
      _report = null;
    });
    _progressSubscription =
        ref.read(postSessionSeamProvider).integrationProgress().listen((event) {
      if (mounted) {
        setState(() => _progress =
            '${event.phase} · ${(event.fraction * 100).round()}% of current filter');
      }
    });
    try {
      final report =
          await _service.run(_plan!, Directory(_directory!), onProgress: (s) {
        if (mounted) setState(() => _progress = s);
      });
      if (mounted) setState(() => _report = report);
    } finally {
      await _progressSubscription?.cancel();
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final available = _groups.expand((g) => g.frames).toList();
    return PopScope(
        canPop: !_busy,
        child: Dialog(
            child: SizedBox(
                width: 1000,
                height: 780,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(children: [
                          Expanded(
                              child: Text('Build masters',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall)),
                          IconButton(
                              onPressed:
                                  _busy ? null : () => Navigator.pop(context),
                              icon: const Icon(Icons.close))
                        ]),
                        const Text(
                            'Combine nights into aligned linear masters. Originals are kept. Review calibration, exclude poor frames, then export one common field.'),
                        const SizedBox(height: 12),
                        if (_error != null)
                          SelectableText(_error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                        if (_directory != null)
                          SelectableText('Build folder: $_directory'),
                        if (_busy) ...[
                          const LinearProgressIndicator(),
                          Text(_progress)
                        ],
                        Expanded(
                            child: ListView(children: [
                          if (_report != null) _result(),
                          if (_report == null && !_running) ...[
                            AccessibleDropdownFormField<String>(
                                initialValue: _target,
                                decoration: const InputDecoration(
                                    labelText: 'Target across all nights'),
                                items: [
                                  for (final name in _targets.keys)
                                    DropdownMenuItem(
                                        value: name,
                                        child: Text(
                                            '$name · ${_targets[name]!.length} captures'))
                                ],
                                onChanged: _busy
                                    ? null
                                    : (v) => setState(() {
                                          _target = v;
                                          _frames = _targets[v] ?? [];
                                          _groups = [];
                                          _excluded.clear();
                                          _reviewed = false;
                                        })),
                            if (_frames.isNotEmpty) ...[
                              ExpansionTile(
                                  title: Text(
                                      'Review ${_frames.length} frames · ${_frames.where((f) => f.isAccepted && !_excluded.contains(f.id)).length} included'),
                                  subtitle: const Text(
                                      'Capture-rejected frames stay excluded. Uncheck a night or individual frame to leave it out.'),
                                  children: [
                                    for (final date in _frames
                                        .map((f) => f.capturedAt
                                            .toLocal()
                                            .toIso8601String()
                                            .substring(0, 10))
                                        .toSet())
                                      _night(date),
                                  ]),
                              FilledButton(
                                  onPressed: _busy ? null : _prepare,
                                  child: const Text('Prepare calibration')),
                            ],
                            if (_groups.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              const Text(
                                  'Calibration by night, filter and camera settings. Check that flats belong to the same optical setup. Missing flats leave dust and vignetting uncorrected.'),
                              for (final g in _groups) _calibration(g),
                              AccessibleDropdownFormField<String>(
                                  initialValue: _reference,
                                  decoration: const InputDecoration(
                                      labelText:
                                          'Alignment reference (all filters share this field)'),
                                  items: [
                                    for (final f in available)
                                      DropdownMenuItem(
                                          value: f.filePath,
                                          child: Text(
                                              '${f.filter ?? ''} · ${f.fileName}',
                                              overflow: TextOverflow.ellipsis))
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(() => _reference = v),
                                  isExpanded: true),
                              Text(
                                  'Minimum field overlap: ${(_overlap * 100).round()}%'),
                              Slider(
                                  value: _overlap,
                                  min: .8,
                                  max: 1,
                                  divisions: 20,
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(() => _overlap = v)),
                              Text(
                                  'Maximum star eccentricity: ${_eccentricity.toStringAsFixed(2)} (lower is rounder)'),
                              Slider(
                                  value: _eccentricity,
                                  min: .3,
                                  max: .9,
                                  divisions: 60,
                                  onChanged: _busy
                                      ? null
                                      : (v) =>
                                          setState(() => _eccentricity = v)),
                              const Text(
                                  'Frames outside these limits are excluded with reasons. Every exported filter receives the same crop, covered by all its included exposures. A crop retaining less than 80% stops for review.'),
                              CheckboxListTile(
                                  value: _reviewed,
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(
                                          () => _reviewed = v ?? false),
                                  title: const Text(
                                      'I reviewed the calibration choices and any missing masters.')),
                            ],
                          ],
                        ])),
                        const SizedBox(height: 12),
                        Wrap(spacing: 12, children: [
                          if (!_running)
                            TextButton(
                                onPressed: _busy ? null : _resume,
                                child: const Text('Resume saved build')),
                          if (!_running && _report == null && _plan != null)
                            TextButton(
                                onPressed: _busy ? null : () => _action(_run),
                                child: const Text('Resume this build')),
                          if (_running)
                            OutlinedButton(
                                onPressed: () async {
                                  try {
                                    await _service.stop();
                                  } catch (e) {
                                    if (mounted) {
                                      setState(
                                          () => _error = 'Stop failed: $e');
                                    }
                                  }
                                },
                                child:
                                    const Text('Stop after current operation')),
                          if (_report == null && !_running)
                            FilledButton(
                                onPressed:
                                    _busy || !_reviewed || _groups.isEmpty
                                        ? null
                                        : _start,
                                child: const Text('Build and export masters')),
                        ]),
                      ]),
                ))));
  }

  Widget _night(String date) {
    final frames = _frames
        .where((f) => f.capturedAt.toLocal().toIso8601String().startsWith(date))
        .toList();
    return ExpansionTile(
        title: Row(children: [
          Checkbox(
              value: frames
                  .where((f) => f.isAccepted)
                  .any((f) => !_excluded.contains(f.id)),
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                        for (final f in frames) {
                          if (value == true) {
                            _excluded.remove(f.id);
                          } else {
                            _excluded.add(f.id);
                          }
                        }
                        _groups = [];
                        _reviewed = false;
                      })),
          Expanded(child: Text('$date · ${frames.length} frames'))
        ]),
        children: [
          for (final f in frames)
            CheckboxListTile(
                value: f.isAccepted && !_excluded.contains(f.id),
                onChanged: _busy || !f.isAccepted
                    ? null
                    : (v) => setState(() {
                          if (v == true) {
                            _excluded.remove(f.id);
                          } else {
                            _excluded.add(f.id);
                          }
                          _groups = [];
                          _reviewed = false;
                        }),
                title: Text('${f.filter ?? ''} · ${f.fileName}'),
                subtitle: Text(f.isAccepted
                    ? 'HFR ${f.hfr?.toStringAsFixed(2) ?? 'unknown'} · ${f.exposureDuration}s'
                    : f.rejectionReason ?? 'Rejected during capture'),
                secondary: _BuildFrameThumbnail(imageId: f.id)),
        ]);
  }

  Widget _calibration(DarkroomBuildGroup group) => ExpansionTile(
          title: Text(group.label),
          subtitle: Text(
              '${group.frames.length} frames · ${group.calibration.containsKey('flat') ? 'flat selected' : 'NO FLAT'}'),
          children: [
            if (group.warnings.isNotEmpty)
              const Text('Library match notes (before manual changes):'),
            for (final warning in group.warnings)
              Padding(padding: const EdgeInsets.all(4), child: Text(warning)),
            for (final kind in ['bias', 'dark', 'flat'])
              Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '$kind: ${group.calibration[kind] == null ? 'None' : p.basename(group.calibration[kind] as String)}'),
                        if (group.calibration[kind] != null)
                          SelectableText(group.calibration[kind] as String),
                        Wrap(children: [
                          TextButton(
                              onPressed:
                                  _busy ? null : () => _pickMaster(group, kind),
                              child: const Text('Choose master')),
                          TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _buildCalibration(group, kind),
                              child: const Text('Build from frames')),
                          IconButton(
                              tooltip: 'Use no $kind',
                              onPressed: _busy
                                  ? null
                                  : () => setState(() {
                                        group.calibration.remove(kind);
                                        _reviewed = false;
                                      }),
                              icon: const Icon(Icons.clear))
                        ]),
                      ])),
          ]);

  Widget _result() {
    final results = (_report!['results'] as List).cast<Map>();
    final delivery = _report!['delivery'] as Map;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Masters ready · ${delivery['width']} × ${delivery['height']}',
          style: Theme.of(context).textTheme.titleLarge),
      Text(
          '${((delivery['retainedArea'] as num) * 100).toStringAsFixed(1)}% of the field retained. Linear FITS files open directly in PixInsight; previews are stretched only for display.'),
      for (var i = 0; i < results.length; i++)
        ListTile(
            title: Text(
                '${results[i]['filter']}: ${results[i]['frameCount']} frames · ${((results[i]['totalIntegrationSec'] as num) / 3600).toStringAsFixed(2)} h'),
            subtitle: Text(
                '${(results[i]['skipped'] as List).length} excluded during processing'),
            leading: Image.file(
                File((delivery['masters'] as List)[i]['previewPath'] as String),
                width: 80),
            trailing: TextButton(
                onPressed: () async {
                  final uri = Uri.file(
                      (delivery['masters'] as List)[i]['path'] as String);
                  if (!await launchUrl(uri) && mounted) {
                    setState(() => _error =
                        'Could not open the FITS viewer. Open the output folder instead.');
                  }
                },
                child: const Text('Open master'))),
      SelectableText(_directory!),
      TextButton(
          onPressed: () => launchUrl(Uri.directory(_directory!)),
          child: const Text('Open output folder')),
      const Text(
          'The folder includes full-size originals, a frame audit, calibration choices, and the common-crop report. Completed masters also appear in Darkroom’s Masters tab.'),
    ]);
  }
}

class _BuildFrameThumbnail extends ConsumerWidget {
  const _BuildFrameThumbnail({required this.imageId});
  final int imageId;
  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(subThumbnailProvider(imageId)).when(
            loading: () =>
                const SizedBox(width: 64, child: LinearProgressIndicator()),
            error: (_, __) => const Icon(Icons.image_not_supported),
            data: (bytes) => InkWell(
                onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => Dialog(
                        child: InteractiveViewer(
                            child: Image.memory(bytes, fit: BoxFit.contain)))),
                child: Image.memory(bytes, width: 64)),
          );
}
