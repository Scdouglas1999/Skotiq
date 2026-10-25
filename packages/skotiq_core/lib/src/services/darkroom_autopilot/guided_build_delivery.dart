import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../database/daos/darkroom_jobs_dao.dart';
import '../../models/darkroom/darkroom_job.dart';
import '../../models/darkroom/darkroom_links.dart';
import '../../models/darkroom/delivery.dart';
import '../../models/notification/notification_categories.dart';
import '../darkroom_build_jobs.dart';
import '../darkroom_build_service.dart' show describeIntegration;
import '../darkroom_delivery/delivery_artifact.dart';
import '../darkroom_delivery/delivery_failure.dart';
import '../darkroom_delivery/delivery_providers.dart';
import '../darkroom_delivery/delivery_service.dart';
import '../logging_service.dart';
import '../notification_service.dart';

/// What delivering one finished guided build did.
class GuidedBuildDeliveryOutcome {
  const GuidedBuildDeliveryOutcome({
    required this.jobId,
    required this.title,
    required this.message,
    required this.delivery,
    required this.problems,
    required this.announced,
  });

  /// The `darkroom_jobs` row the delivery journal is keyed on.
  final int jobId;
  final String title;
  final String message;
  final DeliveryRunReport? delivery;
  final List<String> problems;

  /// Whether the morning message left the process.
  final bool announced;
}

/// The morning half of an unattended night for a guided multi-night build:
/// hand its linear masters, composites, previews and report to the configured
/// delivery destinations, then send one morning message summarizing the
/// build.
///
/// The guided build already writes the stretched previews and the color
/// composites, so the dawn pass's draft recipes are not run over its masters.
///
/// The job row carries no session: it exists to key the delivery journal (so
/// the retry sweep can finish an interrupted copy), and a row without a
/// session is never re-run as a dawn draft pass.
class GuidedBuildDelivery {
  GuidedBuildDelivery({
    required DarkroomJobsDao jobs,
    required DeliveryService delivery,
    required NotificationService notifications,
    LoggingService? logger,
  }) : _jobs = jobs,
       _delivery = delivery,
       _notifications = notifications,
       _logger = logger;

  final DarkroomJobsDao _jobs;
  final DeliveryService _delivery;
  final NotificationService _notifications;
  final LoggingService? _logger;

  /// Deliver [job], a guided build that finished with masters, and announce
  /// it unless [announce] is false (a night-end run sends one message for the
  /// whole night). Never throws for a delivery or notification problem; both
  /// are lines in the message and the outcome.
  Future<GuidedBuildDeliveryOutcome> deliver(
    DarkroomBuildJob job, {
    bool announce = true,
  }) async {
    final report = job.report;
    if (job.stage != DarkroomJobStage.done || report == null) {
      throw StateError('${job.target}: the build has no masters to deliver.');
    }
    final summary = summarizeGuidedBuild(job);
    final jobId = await _jobs.enqueue(
      kind: DarkroomJobKind.dawn,
      note: 'Guided master build delivery: ${job.target}',
    );
    await _jobs.markRunning(jobId);

    final artifacts = <DeliveryArtifact>[];
    final problems = <String>[];
    final sources = guidedBuildArtifacts(job);
    for (final entry in sources.entries) {
      for (final path in entry.value) {
        try {
          artifacts.add(
            await DeliveryArtifact.describeArtifact(
              content: entry.key,
              path: path,
            ),
          );
        } on DeliveryFailure catch (error) {
          problems.add(
            '${p.basename(path)} was not delivered: ${error.message}.',
          );
        }
      }
    }
    DeliveryRunReport? delivered;
    if (artifacts.isNotEmpty) {
      delivered = await _delivery.deliverJobArtifacts(
        DeliveryArtifactSet(jobId: jobId, artifacts: artifacts),
      );
      problems
        ..addAll(delivered.problems)
        ..addAll([for (final d in delivered.destinations) ...d.problems]);
    } else {
      problems.add('Nothing was delivered: no output file could be read.');
    }

    final lines = [
      summary,
      if (delivered != null && delivered.destinations.isNotEmpty)
        'Delivered ${delivered.delivered} file'
            '${delivered.delivered == 1 ? '' : 's'} to '
            '${delivered.destinations.length} destination'
            '${delivered.destinations.length == 1 ? '' : 's'}.',
      if (delivered != null && delivered.destinations.isEmpty)
        'No delivery destination is set up; the files are in '
            '${job.directory}.',
      ...problems,
    ];
    final title = 'Masters ready: ${job.target}';
    final message = lines.join(' ');
    var announced = false;
    if (announce) {
      announced = await _announce(job, title, message);
    }
    await _jobs.markDone(jobId, note: message);
    return GuidedBuildDeliveryOutcome(
      jobId: jobId,
      title: title,
      message: message,
      delivery: delivered,
      problems: problems,
      announced: announced,
    );
  }

  Future<bool> _announce(
    DarkroomBuildJob job,
    String title,
    String message,
  ) async {
    var announced = false;
    try {
      final dispatch = await _notifications.notifyDetailed(
        event: NotificationEvent.sequenceComplete,
        title: title,
        message: message,
        routeAs: NotificationCategory.darkroomDraftReady,
        deepLink: darkroomTargetPayload(job.target),
      );
      announced = dispatch.anyDelivered;
      if (!announced) {
        _logger?.info(
          'The morning message for ${job.target} was not sent: '
          '${dispatch.describe()}',
          source: 'GuidedBuildDelivery',
        );
      }
    } catch (error) {
      _logger?.warning(
        'The morning message for ${job.target} could not be sent: $error',
        source: 'GuidedBuildDelivery',
      );
    }
    return announced;
  }
}

/// The files a finished guided build hands to delivery: the cropped linear
/// masters and the composites, their stretched previews, and the build
/// report with its frame audit.
Map<ArtifactContent, List<String>> guidedBuildArtifacts(DarkroomBuildJob job) {
  final report = job.report!;
  final delivery = Map<String, dynamic>.from(report['delivery'] as Map);
  final masters = <String>[];
  final previews = <String>[];
  for (final m in delivery['masters'] as List) {
    final master = m as Map;
    masters.add(master['path'] as String);
    final preview = master['previewPath'];
    if (preview is String) previews.add(preview);
  }
  final composites = delivery['composites'];
  if (composites is Map) {
    for (final key in ['rgbPath', 'rgbXisfPath', 'lrgbPath', 'lrgbXisfPath']) {
      final path = composites[key];
      if (path is String) masters.add(path);
    }
  }
  final directory = job.directory;
  return {
    ArtifactContent.linearMasters: masters,
    ArtifactContent.draftRender: previews,
    if (directory != null)
      ArtifactContent.nightReport: [
        p.join(directory, 'report.json'),
        p.join(directory, 'frame-audit.csv'),
      ],
  };
}

/// One paragraph on a finished guided build: nights, subs used and left out
/// per filter, the retained crop, composites, and the build's warnings.
String summarizeGuidedBuild(DarkroomBuildJob job) {
  final report = job.report!;
  final plan = Map<String, dynamic>.from(report['plan'] as Map);
  final results = (report['results'] as List).cast<Map>();
  final failures = (report['failures'] as List? ?? const []).cast<Map>();
  final delivery = Map<String, dynamic>.from(report['delivery'] as Map);
  final nights = <String>{
    for (final g in plan['groups'] as List)
      ((g as Map)['label'] as String).split(' · ').first,
  };
  var used = 0;
  var offered = 0;
  for (final g in plan['groups'] as List) {
    offered += ((g as Map)['lights'] as List).length;
  }
  final perFilter = <String>[];
  for (final r in results) {
    final count = (r['frameCount'] as num).toInt();
    used += count;
    final seconds = r['totalIntegrationSec'] as num?;
    perFilter.add(
      '${r['filter']} $count sub${count == 1 ? '' : 's'}'
      '${seconds == null ? '' : ', ${describeIntegration(seconds)}'}',
    );
  }
  // Lights offered to the build that no master took, and lights left out
  // before it (capture rejections).
  final leftOut =
      offered - used + (plan['excluded'] as List? ?? const []).length;
  final retained = delivery['retainedArea'] as num?;
  final width = delivery['width'];
  final height = delivery['height'];
  final composites = delivery['composites'];
  final made = [
    if (composites is Map && composites['rgbPath'] != null) 'RGB',
    if (composites is Map && composites['lrgbPath'] != null) 'LRGB',
  ];
  return [
    '${nights.length} night${nights.length == 1 ? '' : 's'}, $used '
        'sub${used == 1 ? '' : 's'} used, $leftOut left out.',
    '${perFilter.join('; ')}.',
    if (retained != null)
      '${(retained * 100).toStringAsFixed(1)}% of the field kept'
          '${width != null && height != null ? ' ($width x $height px)' : ''}.',
    if (made.isNotEmpty) 'Composites: ${made.join(', ')}.',
    if (failures.isNotEmpty)
      'Not built: ${failures.map((f) => f['filter']).join(', ')}.',
    ...job.warnings,
  ].join(' ');
}

final guidedBuildDeliveryProvider = Provider<GuidedBuildDelivery>((ref) {
  return GuidedBuildDelivery(
    jobs: ref.watch(darkroomJobsDaoProvider),
    delivery: ref.watch(deliveryServiceProvider),
    notifications: ref.watch(notificationServiceProvider),
    logger: ref.watch(loggingServiceProvider),
  );
});
