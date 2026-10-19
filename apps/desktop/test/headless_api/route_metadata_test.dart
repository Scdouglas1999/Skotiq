import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/route_metadata.dart';

void main() {
  group('resource-key tagging (fine-grained auth)', () {
    test('maps device/feature prefixes to their resource key', () {
      expect(
        resourceKeyForEndpoint(method: 'POST', path: '/api/camera/expose'),
        'camera',
      );
      expect(
        resourceKeyForEndpoint(method: 'POST', path: '/api/mount/slew'),
        'mount',
      );
      expect(
        resourceKeyForEndpoint(method: 'POST', path: '/api/filter-wheel/set'),
        'filter-wheel',
      );
      expect(
        resourceKeyForEndpoint(method: 'POST', path: '/api/devices/connect'),
        'devices',
      );
      expect(
        resourceKeyForEndpoint(method: 'GET', path: '/api/calibration/darks'),
        'calibration',
      );
      expect(
        resourceKeyForEndpoint(method: 'GET', path: '/api/calibration-library'),
        'calibration',
      );
      expect(
        resourceKeyForEndpoint(method: 'GET', path: '/api/files/browse'),
        'filesystem',
      );
    });

    test('collaborative-sky routes map to their own resource, not system', () {
      // Falling through to `system` would conflate collaborative access with
      // admin: a fine-grained token would have to hold `system`, and any
      // `system` token would gain collaborative access.
      expect(
        resourceKeyForEndpoint(
          method: 'POST',
          path: '/api/mosaic/collaborative/publish',
        ),
        'mosaic',
      );
      expect(
        resourceKeyForEndpoint(method: 'POST', path: '/api/coimaging/sessions'),
        'coimaging',
      );
      expect(
        resourceKeyForEndpoint(
          method: 'GET',
          path: '/api/constellation/targets',
        ),
        'constellation',
      );
      // The live collaboration surface (shared-viewer join, broadcast preview,
      // chat, annotations) is the last collaborative route that still fell
      // through to `system` — it maps to the collaborative `constellation`
      // resource, so a fine-grained token no longer needs `system` to run a
      // shared viewing session (and a `system` grant no longer silently gains
      // it).
      expect(
        resourceKeyForEndpoint(
          method: 'POST',
          path: '/api/collaboration/viewers/join',
        ),
        'constellation',
      );
      expect(
        resourceKeyForEndpoint(method: 'POST', path: '/api/collaboration/chat'),
        'constellation',
      );
      expect(
        resourceKeyForEndpoint(method: 'GET', path: '/api/collaboration/state'),
        'constellation',
      );
    });

    test('public/system probes map to the info resource', () {
      expect(resourceKeyForEndpoint(method: 'GET', path: '/api/info'), 'info');
      expect(
        resourceKeyForEndpoint(method: 'GET', path: '/api/status'),
        'info',
      );
    });

    test('unmapped paths fail closed to the system resource', () {
      expect(
        resourceKeyForEndpoint(method: 'POST', path: '/api/totally-unknown'),
        'system',
      );
    });
  });

  group('darkroom peer-delivery surface', () {
    const manifest = '/api/darkroom/delivery/manifest/<jobId>';
    const artifact = '/api/darkroom/delivery/artifact/<jobId>/<artifactId>';
    const ack = '/api/darkroom/delivery/ack/<jobId>';

    test('carries its own resource key rather than falling through to '
        'system', () {
      // Falling through to `system` means any fine-grained token holding
      // `system` silently gained the published-master surface, and a token
      // holding only the darkroom resource could not use it at all.
      expect(resourceKeyForEndpoint(method: 'GET', path: manifest), 'darkroom');
      expect(resourceKeyForEndpoint(method: 'GET', path: artifact), 'darkroom');
      expect(resourceKeyForEndpoint(method: 'POST', path: ack), 'darkroom');
    });

    test('reads are control scope, not view', () {
      // These GETs stream every published master byte-for-byte. A read-only
      // credential — the phone by the bed, a shared run-watch link — has no
      // business pulling the night's masters, on the same principle that made
      // GET /api/settings control scope.
      expect(
        requiredAuthScopeNameForEndpoint(method: 'GET', path: manifest),
        'control',
      );
      expect(
        requiredAuthScopeNameForEndpoint(method: 'GET', path: artifact),
        'control',
      );
      expect(
        requiredAuthScopeNameForEndpoint(method: 'POST', path: ack),
        'control',
      );
    });

    test('the acknowledgement is rate limited like the rest of the control '
        'surface', () {
      expect(endpointRateLimitFor(method: 'POST', path: ack), isNotNull);
    });

    test('artifact egress is audited', () {
      // The bytes leave the appliance, exactly like the mosaic output
      // download that is already audited.
      expect(
        highRiskAuditActionFor(method: 'GET', path: artifact),
        'darkroom_artifact_download',
      );
      expect(
        highRiskAuditActionFor(
          method: 'GET',
          path: '/api/darkroom/delivery/artifact/7/abc123',
        ),
        'darkroom_artifact_download',
      );
    });
  });

  group('OpenAPI route metadata', () {
    test('converts shelf route parameters to OpenAPI parameters', () {
      expect(openApiPath('/api/targets/<id>'), '/api/targets/{id}');
      expect(openApiPath('/dashboard/<path|.*>'), '/dashboard/{path}');
    });

    test('builds HTTP route spec and excludes WebSocket routes', () {
      final spec = buildOpenApiSpec(
        port: 8081,
        routes: const [
          'GET /api/info',
          'GET /api/files/browse',
          'POST /api/mount/slew',
          'POST /api/devices/connect',
          'POST /api/targets/<id>/favorite',
          'WS /events',
        ],
      );

      expect(spec['openapi'], '3.0.3');
      expect((spec['servers'] as List).single['url'], 'http://localhost:8081');
      expect(
        spec['components']['securitySchemes']['bearerAuth']['scheme'],
        'bearer',
      );

      final paths = spec['paths'] as Map<String, dynamic>;
      expect(paths, contains('/api/info'));
      expect(paths, contains('/api/files/browse'));
      expect(paths, contains('/api/mount/slew'));
      expect(paths, contains('/api/targets/{id}/favorite'));
      expect(paths, isNot(contains('/events')));
      expect(paths['/api/targets/{id}/favorite'], contains('post'));
      expect(
        paths['/api/mount/slew']['post']['requestBody']['content'],
        contains('application/json'),
      );
      final connectBody =
          paths['/api/devices/connect']['post']['requestBody']
              as Map<String, dynamic>;
      expect(connectBody['required'], isTrue);
      final connectSchema =
          connectBody['content']['application/json']['schema']
              as Map<String, dynamic>;
      expect(
        connectSchema['required'],
        containsAll(['deviceId', 'deviceType']),
      );
      expect(
        connectSchema['properties']['deviceType']['enum'],
        containsAll(['camera', 'filterWheel', 'coverCalibrator']),
      );
      final info = paths['/api/info']['get'] as Map<String, dynamic>;
      expect(info['x-auth-required'], isFalse);
      expect(info['x-required-scope'], 'public');
      expect(info, isNot(contains('security')));
      expect(info['responses'], contains('426'));
      expect(info['responses'], isNot(contains('429')));
      final fileBrowse =
          paths['/api/files/browse']['get'] as Map<String, dynamic>;
      expect(fileBrowse['x-auth-required'], isTrue);
      expect(fileBrowse['x-required-scope'], 'admin');
      expect(fileBrowse['security'], isNotEmpty);
      expect(fileBrowse['responses'], contains('429'));
      expect(
        fileBrowse['x-rate-limit']['maxRequests'],
        defaultControlRateLimitMaxRequests,
      );
      expect(fileBrowse['x-audit-action'], 'file_browse');
      final slew = paths['/api/mount/slew']['post'] as Map<String, dynamic>;
      expect(slew['x-auth-required'], isTrue);
      expect(slew['x-required-scope'], 'control');
      expect(slew['security'], isNotEmpty);
      expect(slew['responses'], contains('413'));
      expect(slew['responses'], contains('429'));
      expect(slew['responses'], contains('426'));
      expect(slew['x-max-request-body-bytes'], oneMiB);
      expect(
        slew['x-rate-limit']['maxRequests'],
        highRiskControlRateLimitMaxRequests,
      );
      expect(slew['x-audit-action'], 'mount_slew');
    });
  });

  group('auth metadata', () {
    test('classifies public, view, control, and admin endpoint scopes', () {
      expect(
        requiredAuthScopeNameForEndpoint(method: 'GET', path: '/api/info'),
        'public',
      );
      expect(
        requiredAuthScopeNameForEndpoint(method: 'GET', path: '/api/status'),
        'view',
      );
      expect(
        requiredAuthScopeNameForEndpoint(
          method: 'POST',
          path: '/api/mount/slew',
        ),
        'control',
      );
      expect(
        requiredAuthScopeNameForEndpoint(
          method: 'GET',
          path: '/api/files/browse',
        ),
        'admin',
      );
      expect(
        requiredAuthScopeNameForEndpoint(
          method: 'POST',
          path: '/api/backup/restore',
        ),
        'admin',
      );
    });
  });

  group('request body limits', () {
    test('uses tight default limit for control requests', () {
      expect(requestBodyLimitForPath('/api/mount/slew'), oneMiB);
    });

    test(
      'uses larger explicit limits for image processing and backup upload',
      () {
        expect(requestBodyLimitForPath('/api/imaging/stretch'), 64 * oneMiB);
        expect(requestBodyLimitForPath('/api/imaging/stats'), 64 * oneMiB);
        expect(requestBodyLimitForPath('/api/imaging/debayer'), 64 * oneMiB);
        expect(requestBodyLimitForPath('/api/imaging/save-fits'), 64 * oneMiB);
        expect(
          requestBodyLimitForPath('/api/backup/upload-restore'),
          256 * oneMiB,
        );
      },
    );

    test('allows GET and missing Content-Length headers', () {
      expect(
        validateContentLength(
          method: 'GET',
          path: '/api/mount/slew',
          contentLengthHeader: '${oneMiB + 1}',
        ),
        isNull,
      );
      expect(
        validateContentLength(
          method: 'POST',
          path: '/api/mount/slew',
          contentLengthHeader: null,
        ),
        isNull,
      );
    });

    test('rejects invalid Content-Length headers', () {
      final result = validateContentLength(
        method: 'POST',
        path: '/api/mount/slew',
        contentLengthHeader: 'invalid',
      );

      expect(result, isNotNull);
      expect(result!['statusCode'], HttpStatus.badRequest);
      expect(result['body'], contains('error'));
    });

    test('rejects oversized default control requests', () {
      final result = validateContentLength(
        method: 'POST',
        path: '/api/mount/slew',
        contentLengthHeader: '${oneMiB + 1}',
      );

      expect(result, isNotNull);
      expect(result!['statusCode'], HttpStatus.requestEntityTooLarge);
      expect((result['body'] as Map<String, dynamic>)['maxBytes'], oneMiB);
    });
  });

  group('endpoint rate limits', () {
    test('does not rate limit ordinary read endpoints', () {
      expect(endpointRateLimitFor(method: 'GET', path: '/api/info'), isNull);
    });

    test('uses high-risk limits for release-gated remote commands', () {
      for (final path in const [
        '/api/devices/connect',
        '/api/devices/disconnect',
        '/api/mount/slew',
        '/api/mount/slew-alt-az',
        '/api/mount/park',
        '/api/mount/unpark',
        '/api/mount/home',
        '/api/mount/find-home',
        '/api/mount/set-park',
        '/api/framing/slew-to-target',
        '/api/framing/center-on-target',
        '/api/framing/park',
        '/api/framing/unpark',
        '/api/dome/open',
        '/api/dome/close',
        '/api/dome/slew',
        '/api/dome/park',
        '/api/backup/restore',
        '/api/backup/upload-restore',
        '/api/sequencer/start',
        '/api/sequencer/stop',
        '/api/sequencer/resume',
        '/api/sequencer/request-meridian-flip',
      ]) {
        expect(
          endpointRateLimitFor(method: 'POST', path: path)!.maxRequests,
          highRiskControlRateLimitMaxRequests,
          reason: '$path must use high-risk control limits.',
        );
      }
    });

    test('uses high-risk limits for collaborative-mosaic egress + assemble + '
        'output download', () {
      // Both the templated (route-enumeration) and instantiated
      // (request-time) forms must escalate to the high-risk tier: the
      // panel upload ships a full-resolution master off the device,
      // assemble runs a heavy native stitch, and the output download pulls
      // hub-served bytes and writes them to the appliance filesystem.
      for (final path in const [
        '/api/mosaic/projects/<projectId>/panels/<panelIndex>/upload',
        '/api/mosaic/projects/7/panels/3/upload',
        '/api/mosaic/projects/<projectId>/assemble',
        '/api/mosaic/projects/7/assemble',
        '/api/mosaic/projects/<projectId>/output',
        '/api/mosaic/projects/7/output',
      ]) {
        expect(
          endpointRateLimitFor(method: 'POST', path: path)!.maxRequests,
          highRiskControlRateLimitMaxRequests,
          reason: '$path must use high-risk control limits.',
        );
        expect(
          isHighRiskControlPath(path),
          isTrue,
          reason: '$path must be a high-risk control path.',
        );
      }
    });

    test('uses default limits for other collaborative-mosaic controls', () {
      // publish / join / claim are mutating but neither data egress nor heavy
      // compute, so they ride the default control window via the
      // `/api/mosaic/` prefix. (output download is high-risk: covered above.)
      for (final path in const [
        '/api/mosaic/projects/7/publish',
        '/api/mosaic/projects/7/join',
        '/api/mosaic/projects/7/panels/3/claim',
      ]) {
        expect(
          endpointRateLimitFor(method: 'POST', path: path)!.maxRequests,
          defaultControlRateLimitMaxRequests,
          reason: '$path must use default control limits.',
        );
        expect(
          isHighRiskControlPath(path),
          isFalse,
          reason: '$path must not be a high-risk control path.',
        );
      }
    });

    test('rate-limits live collaboration mutating endpoints (default tier)', () {
      // Viewer join / chat / preview / annotations are mutating collaborative
      // controls, so — like the mosaic/coimaging control surface — they ride the
      // default control window instead of being unlimited (a joined viewer must
      // not be able to flood an unattended rig with chat/preview posts).
      for (final path in const [
        '/api/collaboration/viewers/join',
        '/api/collaboration/chat',
        '/api/collaboration/preview',
        '/api/collaboration/annotations',
      ]) {
        expect(
          endpointRateLimitFor(method: 'POST', path: path)?.maxRequests,
          defaultControlRateLimitMaxRequests,
          reason: '$path must use default control limits, not be unlimited.',
        );
      }
    });

    test(
      'uses high-risk limits + audits live co-imaging contribute egress',
      () {
        // sub-complete + contribute fold this rig's additive sums off-device to
        // a remote hub (sub-complete also drives heavy native fusion), so both
        // the templated and instantiated forms escalate to the high-risk tier
        // AND emit the `coimaging_sub_contribute` audit action.
        for (final path in const [
          '/api/coimaging/sessions/<sessionId>/sub-complete',
          '/api/coimaging/sessions/abc123/sub-complete',
          '/api/coimaging/sessions/<sessionId>/contribute',
          '/api/coimaging/sessions/abc123/contribute',
        ]) {
          expect(
            endpointRateLimitFor(method: 'POST', path: path)!.maxRequests,
            highRiskControlRateLimitMaxRequests,
            reason: '$path must use high-risk control limits.',
          );
          expect(
            isHighRiskControlPath(path),
            isTrue,
            reason: '$path must be a high-risk control path.',
          );
          expect(
            highRiskAuditActionFor(method: 'POST', path: path),
            'coimaging_sub_contribute',
            reason: '$path must emit the co-imaging contribute audit action.',
          );
        }
      },
    );

    test('uses default limits for other live co-imaging + constellation '
        'controls', () {
      // create / join / leave / close / baton are mutating but neither data
      // egress nor heavy fusion, so they ride the default control window via the
      // `/api/coimaging/` + `/api/constellation/` prefixes.
      for (final path in const [
        '/api/coimaging/sessions',
        '/api/coimaging/sessions/s1/join',
        '/api/coimaging/sessions/s1/close',
        '/api/coimaging/sessions/s1/baton/auto',
        '/api/constellation/contribute',
      ]) {
        expect(
          endpointRateLimitFor(method: 'POST', path: path)!.maxRequests,
          defaultControlRateLimitMaxRequests,
          reason: '$path must use default control limits.',
        );
        expect(
          isHighRiskControlPath(path),
          isFalse,
          reason: '$path must not be a high-risk control path.',
        );
      }
    });

    test('rate-limits calibration-library mutating endpoints (default '
        'tier)', () {
      // The unified Calibration Library Manager write surface sits under the
      // hyphenated `/api/calibration-library/` prefix, which does NOT match
      // `/api/calibration/`. It is enrolled in the control prefix list so the
      // off-device publish and its siblings get the default per-endpoint
      // window instead of only the coarse write token bucket.
      for (final path in const [
        '/api/calibration-library/publish',
        '/api/calibration-library/match',
        '/api/calibration-library/accept',
        '/api/calibration-library/retract',
      ]) {
        expect(
          endpointRateLimitFor(method: 'POST', path: path)?.maxRequests,
          defaultControlRateLimitMaxRequests,
          reason: '$path must use default control limits, not be unlimited.',
        );
      }
    });

    test('rate limits file browsing without blocking ordinary reads', () {
      expect(
        endpointRateLimitFor(
          method: 'GET',
          path: '/api/files/browse',
        )!.maxRequests,
        defaultControlRateLimitMaxRequests,
      );
      expect(endpointRateLimitFor(method: 'GET', path: '/api/status'), isNull);
    });

    test('uses default limits for other control endpoints', () {
      expect(
        endpointRateLimitFor(
          method: 'POST',
          path: '/api/camera/cooling',
        )!.maxRequests,
        defaultControlRateLimitMaxRequests,
      );
    });

    test('blocks requests after the endpoint limit is reached', () {
      var now = DateTime(2026, 5, 5, 1);
      final limiter = EndpointRateLimiter(now: () => now);

      for (var i = 0; i < highRiskControlRateLimitMaxRequests; i++) {
        final decision = limiter.check(
          clientKey: 'client-a',
          method: 'POST',
          path: '/api/mount/slew',
        );
        expect(decision.allowed, isTrue);
      }

      final blocked = limiter.check(
        clientKey: 'client-a',
        method: 'POST',
        path: '/api/mount/slew',
      );
      expect(blocked.allowed, isFalse);
      expect(blocked.retryAfterSeconds, greaterThan(0));

      now = now.add(defaultControlRateLimitWindow);
      final afterWindow = limiter.check(
        clientKey: 'client-a',
        method: 'POST',
        path: '/api/mount/slew',
      );
      expect(afterWindow.allowed, isTrue);
    });
  });

  group('high-risk audit metadata', () {
    test('marks high-risk remote commands for audit logging', () {
      const expectedActions = {
        '/api/devices/connect': 'device_connect',
        '/api/devices/disconnect': 'device_disconnect',
        '/api/mount/slew': 'mount_slew',
        '/api/mount/slew-alt-az': 'mount_slew_alt_az',
        '/api/mount/park': 'mount_park',
        '/api/mount/unpark': 'mount_unpark',
        '/api/mount/home': 'mount_home',
        '/api/mount/find-home': 'mount_home',
        '/api/mount/set-park': 'mount_set_park',
        '/api/framing/slew-to-target': 'framing_slew_to_target',
        '/api/framing/center-on-target': 'framing_center_on_target',
        '/api/framing/park': 'framing_park',
        '/api/framing/unpark': 'framing_unpark',
        '/api/dome/open': 'dome_open',
        '/api/dome/close': 'dome_close',
        '/api/dome/slew': 'dome_slew',
        '/api/dome/park': 'dome_park',
        '/api/backup/restore': 'backup_restore',
        '/api/backup/upload-restore': 'backup_upload_restore',
        '/api/sequencer/start': 'sequence_start',
        '/api/sequencer/stop': 'sequence_stop',
        '/api/sequencer/resume': 'sequence_resume',
        '/api/sequencer/request-meridian-flip':
            'sequence_request_meridian_flip',
      };

      for (final entry in expectedActions.entries) {
        expect(
          highRiskAuditActionFor(method: 'POST', path: entry.key),
          entry.value,
          reason: '${entry.key} must produce a high-risk audit action.',
        );
      }

      expect(
        highRiskAuditActionFor(method: 'GET', path: '/api/files/browse'),
        'file_browse',
      );
    });

    test('audits collaborative-mosaic egress + assemble (parameterised)', () {
      // Both templated and instantiated path forms must produce an audit
      // row so an operator can trace who triggered the off-device egress
      // or the heavy stitch.
      expect(
        highRiskAuditActionFor(
          method: 'POST',
          path: '/api/mosaic/projects/<projectId>/panels/<panelIndex>/upload',
        ),
        'mosaic_panel_upload',
      );
      expect(
        highRiskAuditActionFor(
          method: 'POST',
          path: '/api/mosaic/projects/7/panels/3/upload',
        ),
        'mosaic_panel_upload',
      );
      expect(
        highRiskAuditActionFor(
          method: 'POST',
          path: '/api/mosaic/projects/<projectId>/assemble',
        ),
        'mosaic_assemble',
      );
      expect(
        highRiskAuditActionFor(
          method: 'POST',
          path: '/api/mosaic/projects/7/assemble',
        ),
        'mosaic_assemble',
      );
      // Owner/admin force-release is a destructive recovery action (evicting a
      // squatting claim or a poisoned upload), so both path forms must produce
      // an audit row recording who evicted which panel.
      expect(
        highRiskAuditActionFor(
          method: 'POST',
          path:
              '/api/mosaic/projects/<projectId>/panels/<panelIndex>/'
              'force-release',
        ),
        'mosaic_force_release',
      );
      expect(
        highRiskAuditActionFor(
          method: 'POST',
          path: '/api/mosaic/projects/7/panels/3/force-release',
        ),
        'mosaic_force_release',
      );
      // The finished-mosaic download writes hub-served bytes to disk, so both
      // path forms must produce an audit row too.
      expect(
        highRiskAuditActionFor(
          method: 'POST',
          path: '/api/mosaic/projects/<projectId>/output',
        ),
        'mosaic_output_download',
      );
      expect(
        highRiskAuditActionFor(
          method: 'POST',
          path: '/api/mosaic/projects/7/output',
        ),
        'mosaic_output_download',
      );
      // Sibling collaborative POSTs that are neither egress nor heavy
      // compute must NOT produce an audit action.
      expect(
        highRiskAuditActionFor(
          method: 'POST',
          path: '/api/mosaic/projects/7/panels/3/claim',
        ),
        isNull,
      );
      expect(
        highRiskAuditActionFor(
          method: 'POST',
          path: '/api/mosaic/projects/7/publish',
        ),
        isNull,
      );
    });

    test('does not audit ordinary status reads', () {
      expect(
        highRiskAuditActionFor(method: 'GET', path: '/api/status'),
        isNull,
      );
    });
  });

  // per-token / route-class token bucket. Verifies bucket math,
  // refill, and the route classifier so the runtime middleware can rely
  // on (a) the classifier never returning the wrong class for known
  // hot endpoints and (b) the bucket producing actionable Retry-After
  // values when exhausted.
  group('TokenBucketRateLimiter', () {
    test('classifies live-view, image downloads, reads and writes', () {
      expect(
        tokenRouteClassFor(method: 'GET', path: '/api/camera/live-view/frame'),
        TokenRouteClass.liveView,
      );
      expect(
        tokenRouteClassFor(method: 'GET', path: '/api/images/42/download'),
        TokenRouteClass.imageDownload,
      );
      expect(
        tokenRouteClassFor(method: 'POST', path: '/api/imaging/raw-data'),
        TokenRouteClass.imageDownload,
      );
      expect(
        tokenRouteClassFor(
          method: 'GET',
          path: '/api/calibration/darks/3/download',
        ),
        TokenRouteClass.imageDownload,
      );
      expect(
        tokenRouteClassFor(method: 'GET', path: '/api/devices/connected'),
        TokenRouteClass.read,
      );
      expect(
        tokenRouteClassFor(method: 'POST', path: '/api/mount/slew'),
        TokenRouteClass.write,
      );
      // Bucket class names match the task spec wording.
      expect(tokenRouteClassName(TokenRouteClass.read), 'read');
      expect(tokenRouteClassName(TokenRouteClass.write), 'write');
      expect(tokenRouteClassName(TokenRouteClass.liveView), 'live-view');
      expect(
        tokenRouteClassName(TokenRouteClass.imageDownload),
        'image-download',
      );
    });

    test('default bucket capacities match the task spec', () {
      expect(defaultTokenBucketConfigs[TokenRouteClass.read]!.capacity, 60);
      expect(defaultTokenBucketConfigs[TokenRouteClass.write]!.capacity, 20);
      expect(defaultTokenBucketConfigs[TokenRouteClass.liveView]!.capacity, 30);
      expect(
        defaultTokenBucketConfigs[TokenRouteClass.imageDownload]!.capacity,
        5,
      );
    });

    test('exhausting a bucket returns 429 with refill-based retryAfter', () {
      // Pin the clock so the test is deterministic. The bucket's refill
      // formula depends on wall-clock microsecond elapsed time, and Dart's
      // microtask scheduling can otherwise sneak a few hundred microseconds
      // between two `tryConsume` calls.
      var now = DateTime.utc(2026, 1, 1, 0, 0, 0);
      final limiter = TokenBucketRateLimiter(
        configByClass: const {
          TokenRouteClass.write: TokenBucketConfig(
            capacity: 3,
            refillTokens: 3,
            refillPeriod: Duration(seconds: 1),
          ),
        },
        now: () => now,
      );

      // First three should pass with no time elapsed.
      for (var i = 0; i < 3; i++) {
        final decision = limiter.tryConsume(
          tokenId: 'tokA',
          routeClass: TokenRouteClass.write,
        );
        expect(decision.allowed, isTrue, reason: 'request $i should pass');
        expect(decision.bucket, 'token-write');
        expect(decision.maxRequests, 3);
      }

      // Fourth must fail.
      final denied = limiter.tryConsume(
        tokenId: 'tokA',
        routeClass: TokenRouteClass.write,
      );
      expect(denied.allowed, isFalse);
      expect(denied.bucket, 'token-write');
      expect(denied.retryAfterSeconds, greaterThanOrEqualTo(1));

      // Wait long enough to refill the entire bucket and verify the
      // success path returns immediately.
      now = now.add(const Duration(seconds: 2));
      final after = limiter.tryConsume(
        tokenId: 'tokA',
        routeClass: TokenRouteClass.write,
      );
      expect(
        after.allowed,
        isTrue,
        reason: 'bucket should have fully refilled after 2s',
      );
    });

    test('isolates buckets per (tokenId, routeClass) pair', () {
      // Distinct tokens MUST NOT share a bucket — that was the whole
      // point of the refactor away from IP-keyed buckets. Verify
      // by exhausting one token's read bucket and asserting a different
      // token still has a fresh budget.
      final limiter = TokenBucketRateLimiter(
        configByClass: const {
          TokenRouteClass.read: TokenBucketConfig(
            capacity: 2,
            refillTokens: 2,
            refillPeriod: Duration(seconds: 1),
          ),
        },
      );
      // Drain tokA's read bucket.
      expect(
        limiter
            .tryConsume(tokenId: 'tokA', routeClass: TokenRouteClass.read)
            .allowed,
        isTrue,
      );
      expect(
        limiter
            .tryConsume(tokenId: 'tokA', routeClass: TokenRouteClass.read)
            .allowed,
        isTrue,
      );
      expect(
        limiter
            .tryConsume(tokenId: 'tokA', routeClass: TokenRouteClass.read)
            .allowed,
        isFalse,
      );
      // tokB starts fresh.
      expect(
        limiter
            .tryConsume(tokenId: 'tokB', routeClass: TokenRouteClass.read)
            .allowed,
        isTrue,
      );
    });
  });
}
