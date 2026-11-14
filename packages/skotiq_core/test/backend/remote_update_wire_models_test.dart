import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/src/models/backend/remote_update_models.dart';

void main() {
  group('remote update wire models', () {
    test('queued admission uses status and the caller operation', () {
      final job = RemoteJob.fromJson({
        'jobId': 'job-1',
        'status': 'queued',
      }, fallbackOperation: 'system.update.check');

      expect(job.jobId, 'job-1');
      expect(job.operation, 'system.update.check');
      expect(job.state, 'queued');
    });

    test('job admissions fail loudly when identity is missing', () {
      expect(
        () => RemoteJob.fromJson({
          'status': 'queued',
        }, fallbackOperation: 'system.update.check'),
        throwsFormatException,
      );
      expect(
        () => RemoteJob.fromJson({'jobId': 'job-1', 'status': 'queued'}),
        throwsFormatException,
      );
    });

    test('missing signing capability refuses the status', () {
      expect(
        () => RemoteUpdateStatus.fromJson({
          'state': 'available',
          'availableVersion': '6.1.0',
        }),
        throwsFormatException,
      );
      final status = RemoteUpdateStatus.fromJson({
        'state': 'available',
        'availableVersion': '6.1.0',
        'canAuthenticateUpdates': false,
      });
      expect(status.hasAvailableUpdate, isTrue);
      expect(status.canAuthenticateUpdates, isFalse);
    });

    test('invalid progress is not rendered as a plausible status', () {
      expect(
        () => RemoteUpdateStatus.fromJson({
          'state': 'downloading',
          'progressPct': double.nan,
        }),
        throwsFormatException,
      );
      expect(
        () => RemoteUpdateStatus.fromJson({
          'state': 'downloading',
          'progressPct': 101,
        }),
        throwsFormatException,
      );
    });

    test(
      'version identity is required instead of defaulting to build zero',
      () {
        expect(
          () => RemoteVersionInfo.fromJson({
            'currentVersion': '6.0.0',
            'channel': 'stable',
            'platform': 'linux',
          }),
          throwsFormatException,
        );
        expect(
          () => RemoteVersionInfo.fromJson({
            'currentVersion': '',
            'buildNumber': 60,
            'channel': 'stable',
            'platform': 'linux',
          }),
          throwsFormatException,
        );
      },
    );

    test('update source comes from the host source field', () {
      Map<String, Object?> version(Map<String, Object?> extra) => {
        'currentVersion': '7.2.0',
        'buildNumber': 42,
        'channel': 'stable',
        'platform': 'linux',
        ...extra,
      };

      // A host reading GitHub releases has no server URL; the source field is
      // what tells the client OTA is on.
      final github = RemoteVersionInfo.fromJson(
        version({'updateSource': 'github-releases'}),
      );
      expect(github.updateServerUrl, isNull);
      expect(github.updateSource, 'github-releases');

      final noSource = RemoteVersionInfo.fromJson(
        version({'updateServerUrl': 'https://updates.example.com'}),
      );
      expect(noSource.updateSource, isNull);

      expect(RemoteVersionInfo.fromJson(version({})).updateSource, isNull);
    });
  });
}
