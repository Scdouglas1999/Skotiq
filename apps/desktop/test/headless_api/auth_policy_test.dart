import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api/handlers/system_handlers.dart'
    show availableHeadlessEndpoints;

void main() {
  group('headless token scope parsing', () {
    test('accepts documented scope aliases', () {
      expect(parseHeadlessTokenScope('view-only'), HeadlessTokenScope.view);
      expect(
        parseHeadlessTokenScope('imaging-control'),
        HeadlessTokenScope.control,
      );
      expect(parseHeadlessTokenScope('admin'), HeadlessTokenScope.admin);
    });

    test('rejects unknown scopes', () {
      expect(parseHeadlessTokenScope('operator'), isNull);
      expect(parseHeadlessTokenScope(null), isNull);
    });
  });

  group('headless required-scope fail-closed default', () {
    test('public endpoints resolve to the lowest scope', () {
      // GET /api/info is the only public endpoint; any token rank may pass.
      expect(
        HeadlessAuthPolicy.requiredScopeFor(method: 'GET', path: '/api/info'),
        HeadlessTokenScope.view,
      );
    });

    test(
      'a scope name the parser does not recognise requires admin, not view',
      () {
        // Regression pin for the fail-closed default in requiredScopeFor:
        // route metadata only emits public/view/control/admin today, so an
        // unknown name can only appear through a future drift between
        // route_metadata.dart and parseHeadlessTokenScope. If that happens
        // the route must lock up to admin rather than silently degrade to
        // view. parseHeadlessTokenScope is the seam both share — proving it
        // rejects the name plus this policy test pins the admin fallback.
        expect(parseHeadlessTokenScope('superuser'), isNull);
        // Every real route still resolves to a parseable scope.
        for (final probe in [
          ('GET', '/api/status'),
          ('POST', '/api/camera/expose'),
          ('DELETE', '/api/backup/1'),
          ('WS', '/events'),
        ]) {
          expect(
            HeadlessAuthPolicy.requiredScopeFor(
              method: probe.$1,
              path: probe.$2,
            ),
            isA<HeadlessTokenScope>(),
          );
        }
      },
    );
  });

  group('headless auth policy', () {
    test('view tokens can read ordinary status endpoints and events', () {
      expect(
        HeadlessAuthPolicy.allows(
          actual: HeadlessTokenScope.view,
          method: 'GET',
          path: '/api/status',
        ),
        isTrue,
      );
      expect(
        HeadlessAuthPolicy.allows(
          actual: HeadlessTokenScope.view,
          method: 'WS',
          path: '/events',
        ),
        isTrue,
      );
    });

    test('view tokens cannot issue control commands or browse files', () {
      expect(
        HeadlessAuthPolicy.allows(
          actual: HeadlessTokenScope.view,
          method: 'POST',
          path: '/api/camera/expose',
        ),
        isFalse,
      );
      expect(
        HeadlessAuthPolicy.allows(
          actual: HeadlessTokenScope.view,
          method: 'GET',
          path: '/api/files/browse',
        ),
        isFalse,
      );
    });

    test('control tokens can operate devices but not administer backups', () {
      expect(
        HeadlessAuthPolicy.allows(
          actual: HeadlessTokenScope.control,
          method: 'POST',
          path: '/api/mount/slew',
        ),
        isTrue,
      );
      expect(
        HeadlessAuthPolicy.allows(
          actual: HeadlessTokenScope.control,
          method: 'POST',
          path: '/api/backup/restore',
        ),
        isFalse,
      );
    });

    test('admin tokens can access administrative endpoints', () {
      expect(
        HeadlessAuthPolicy.allows(
          actual: HeadlessTokenScope.admin,
          method: 'POST',
          path: '/api/backup/restore',
        ),
        isTrue,
      );
      expect(
        HeadlessAuthPolicy.allows(
          actual: HeadlessTokenScope.admin,
          method: 'GET',
          path: '/api/self-test',
        ),
        isTrue,
      );
    });

    test('mosaic force-release is gated like claim: view denied, control ok', () {
      // The owner/admin panel eviction is a mutating collaborative-mosaic route,
      // so it sits on the control surface exactly like claim — a view-only token
      // must be denied at the gate rather than reaching the handler and failing
      // late, while a control token is admitted (the hub then enforces
      // owner/admin ownership on top).
      const forceRelease = '/api/mosaic/projects/7/panels/3/force-release';
      const claim = '/api/mosaic/projects/7/panels/3/claim';
      expect(
        HeadlessAuthPolicy.allows(
          actual: HeadlessTokenScope.view,
          method: 'POST',
          path: forceRelease,
        ),
        isFalse,
      );
      expect(
        HeadlessAuthPolicy.allows(
          actual: HeadlessTokenScope.control,
          method: 'POST',
          path: forceRelease,
        ),
        isTrue,
      );
      // Same coarse scope as the sibling claim route (no privilege drift).
      expect(
        HeadlessAuthPolicy.requiredScopeFor(method: 'POST', path: forceRelease),
        HeadlessAuthPolicy.requiredScopeFor(method: 'POST', path: claim),
      );
    });
  });

  group('coarse → grant back-compat bridge (no privilege drift)', () {
    // The keystone invariant: a grant produced by HeadlessAuthGrant
    // .fromCoarse(scope) MUST permit EXACTLY the endpoints the coarse rank
    // check allows — no silent gain or loss of access — for every endpoint in
    // the authoritative catalog.
    test('fromCoarse(scope).permits == legacy allows over every endpoint', () {
      final endpoints = availableHeadlessEndpoints();
      expect(endpoints, isNotEmpty);
      for (final scope in HeadlessTokenScope.values) {
        final grant = HeadlessAuthGrant.fromCoarse(scope);
        for (final route in endpoints) {
          final parts = route.split(' ');
          if (parts.length != 2) continue;
          final method = parts.first.toUpperCase();
          final path = parts.last;

          final legacy = HeadlessAuthPolicy.allows(
            actual: scope,
            method: method,
            path: path,
          );
          final fine = HeadlessAuthPolicy.permits(
            grant: grant,
            method: method,
            path: path,
          );
          expect(
            fine,
            legacy,
            reason:
                'drift for $scope on $method $path '
                '(legacy=$legacy fine=$fine)',
          );
        }
      }
    });

    test('the bridge also agrees on the WS event stream', () {
      for (final scope in HeadlessTokenScope.values) {
        final grant = HeadlessAuthGrant.fromCoarse(scope);
        expect(
          HeadlessAuthPolicy.permits(
            grant: grant,
            method: 'WS',
            path: '/events',
          ),
          HeadlessAuthPolicy.allows(
            actual: scope,
            method: 'WS',
            path: '/events',
          ),
        );
      }
    });
  });

  group('fine-grained grants', () {
    test('camera:control,mount:view exposes camera control but not mount', () {
      final grant = HeadlessAuthGrant.parseSpec('camera:control,mount:view')!;
      // camera control is granted.
      expect(
        HeadlessAuthPolicy.permits(
          grant: grant,
          method: 'POST',
          path: '/api/camera/expose',
        ),
        isTrue,
      );
      // mount slew (control) is denied — only view was granted.
      expect(
        HeadlessAuthPolicy.permits(
          grant: grant,
          method: 'POST',
          path: '/api/mount/slew',
        ),
        isFalse,
      );
      // mount status (view) is allowed.
      expect(
        HeadlessAuthPolicy.permits(
          grant: grant,
          method: 'GET',
          path: '/api/mount/status',
        ),
        isTrue,
      );
      // a resource it never named (focuser) is denied at every level.
      expect(
        HeadlessAuthPolicy.permits(
          grant: grant,
          method: 'GET',
          path: '/api/focuser/status',
        ),
        isFalse,
      );
      // admin-only endpoints stay denied for a non-admin fine-grained grant.
      expect(
        HeadlessAuthPolicy.permits(
          grant: grant,
          method: 'POST',
          path: '/api/backup/restore',
        ),
        isFalse,
      );
    });

    test('device connect/disconnect needs explicit devices:control', () {
      final cameraOnly = HeadlessAuthGrant.parseSpec('camera:control')!;
      expect(
        HeadlessAuthPolicy.permits(
          grant: cameraOnly,
          method: 'POST',
          path: '/api/devices/connect',
        ),
        isFalse,
      );
      final withDevices = HeadlessAuthGrant.parseSpec(
        'camera:control,devices:control',
      )!;
      expect(
        HeadlessAuthPolicy.permits(
          grant: withDevices,
          method: 'POST',
          path: '/api/devices/connect',
        ),
        isTrue,
      );
    });

    test('collaborative-sky resources are mutually isolated (scope-denial '
        'matrix)', () {
      // The fine-grained isolation guarantee for the collaborative surface:
      // a token scoped to ONE collaborative resource must not reach any other,
      // and none of them leaks in via a `system` grant. Rows = grant spec,
      // columns = a representative endpoint on each collaborative resource.
      const mosaicPublish = ('POST', '/api/mosaic/projects/7/publish');
      const coimagingCreate = ('POST', '/api/coimaging/sessions');
      const collabChat = ('POST', '/api/collaboration/chat');

      bool permits(HeadlessAuthGrant g, (String, String) ep) =>
          HeadlessAuthPolicy.permits(grant: g, method: ep.$1, path: ep.$2);

      final mosaicOnly = HeadlessAuthGrant.parseSpec('mosaic:control')!;
      expect(permits(mosaicOnly, mosaicPublish), isTrue);
      expect(
        permits(mosaicOnly, coimagingCreate),
        isFalse,
        reason: 'a mosaic token must not create a co-imaging session',
      );
      expect(
        permits(mosaicOnly, collabChat),
        isFalse,
        reason: 'a mosaic token must not post to the collaboration surface',
      );

      final coimagingOnly = HeadlessAuthGrant.parseSpec('coimaging:control')!;
      expect(permits(coimagingOnly, coimagingCreate), isTrue);
      expect(permits(coimagingOnly, mosaicPublish), isFalse);
      expect(permits(coimagingOnly, collabChat), isFalse);

      // The live collaboration surface is named by either `collaboration` or its
      // underlying `constellation` resource key; both grant it and nothing else.
      for (final spec in const [
        'collaboration:control',
        'constellation:control',
      ]) {
        final collabOnly = HeadlessAuthGrant.parseSpec(spec)!;
        expect(
          permits(collabOnly, collabChat),
          isTrue,
          reason: '$spec must permit the collaboration surface',
        );
        expect(permits(collabOnly, mosaicPublish), isFalse);
        expect(permits(collabOnly, coimagingCreate), isFalse);
      }

      // A `system`-only token must NOT inherit any collaborative resource — the
      // exact leak that mapping `/api/collaboration/` off the `system` catch-all
      // closes.
      final systemOnly = HeadlessAuthGrant.parseSpec('system:control')!;
      expect(permits(systemOnly, mosaicPublish), isFalse);
      expect(permits(systemOnly, coimagingCreate), isFalse);
      expect(permits(systemOnly, collabChat), isFalse);
    });

    test('spec parsing round-trips and rejects malformed input', () {
      expect(HeadlessAuthGrant.parseSpec('admin')!.isAdmin, isTrue);
      expect(HeadlessAuthGrant.parseSpec('view')!.toSpec(), 'view');
      expect(HeadlessAuthGrant.parseSpec('control')!.toSpec(), 'control');
      expect(
        HeadlessAuthGrant.parseSpec('camera:control,mount:view')!.toSpec(),
        'camera:control,mount:view',
      );
      // unknown resource / level / shape → null (caller fails closed).
      expect(HeadlessAuthGrant.parseSpec('warp:control'), isNull);
      expect(HeadlessAuthGrant.parseSpec('camera:superuser'), isNull);
      expect(HeadlessAuthGrant.parseSpec('camera'), isNull);
      expect(HeadlessAuthGrant.parseSpec(''), isNull);
      expect(HeadlessAuthGrant.parseSpec(null), isNull);
    });

    test('a fine-grained mutating grant projects to control coarse', () {
      final grant = HeadlessAuthGrant.parseSpec('camera:control')!;
      expect(grant.coarseScope, HeadlessTokenScope.control);
      final readOnly = HeadlessAuthGrant.parseSpec('camera:view')!;
      expect(readOnly.coarseScope, HeadlessTokenScope.view);
    });
  });

  group('scope denial body', () {
    test('never asserts the requirement is met while denying', () {
      // A fine-grained view grant that does not name `system` is refused
      // /api/run-watch/snapshot. Its coarse projection is `view` and the
      // route's coarse requirement is `view`, so the back-compat pair used to
      // read requiredScope=view beside tokenScope=view — the two fields a
      // human reads first, both agreeing, on a refusal.
      final grant = HeadlessAuthGrant.parseSpec('camera:view,mount:view')!;
      final body = HeadlessAuthPolicy.scopeDenialBody(
        grant: grant,
        method: 'GET',
        path: '/api/run-watch/snapshot',
      );

      expect(body['requiredResource'], 'system');
      expect(body['requiredLevel'], 'view');
      expect(body['tokenLevel'], 'none');
      expect(body.containsKey('requiredScope'), isFalse);
      expect(body.containsKey('tokenScope'), isFalse);
    });

    test('emits the coarse pair when it explains the refusal', () {
      final grant = HeadlessAuthGrant.fromCoarse(HeadlessTokenScope.view);
      final body = HeadlessAuthPolicy.scopeDenialBody(
        grant: grant,
        method: 'POST',
        path: '/api/sequencer/pause',
      );

      expect(body['requiredScope'], 'control');
      expect(body['tokenScope'], 'view');
      expect(body['requiredResource'], 'sequencer');
      expect(body['requiredLevel'], 'control');
      expect(body['tokenLevel'], 'view');
    });

    test('the message names what is held and what is required', () {
      final grant = HeadlessAuthGrant.fromCoarse(HeadlessTokenScope.view);
      final body = HeadlessAuthPolicy.scopeDenialBody(
        grant: grant,
        method: 'POST',
        path: '/api/sequencer/pause',
      );
      final message = body['message'] as String;

      // The leading clause is the wire contract paired clients match on.
      expect(message, startsWith('Token scope is not permitted'));
      expect(message, contains('holds view on sequencer'));
      expect(message, contains('control is required'));
      expect(body['error'], 'Access denied');
    });

    test('an admin-only route reports admin as the requirement', () {
      final grant = HeadlessAuthGrant.fromCoarse(HeadlessTokenScope.control);
      final body = HeadlessAuthPolicy.scopeDenialBody(
        grant: grant,
        method: 'GET',
        path: '/api/pairing/active',
      );

      expect(body['requiredLevel'], 'admin');
      expect(body['tokenLevel'], 'control');
      expect(body['requiredScope'], 'admin');
      expect(body['tokenScope'], 'control');
    });

    test('every coarse pair it emits reads as a refusal on its own', () {
      // Sweep the grants and routes the appliance actually mints and gates:
      // wherever the body still carries the coarse pair, the pair must rank
      // as a genuine shortfall rather than as two equal words.
      final grants = <HeadlessAuthGrant>[
        HeadlessAuthGrant.fromCoarse(HeadlessTokenScope.view),
        HeadlessAuthGrant.fromCoarse(HeadlessTokenScope.control),
        HeadlessAuthGrant.parseSpec('camera:view,mount:view')!,
        HeadlessAuthGrant.parseSpec('camera:control')!,
        HeadlessAuthGrant.parseSpec('sequencer:view')!,
      ];
      const routes = <(String, String)>[
        ('GET', '/api/status'),
        ('GET', '/api/settings'),
        ('GET', '/api/run-watch/snapshot'),
        ('POST', '/api/sequencer/pause'),
        ('POST', '/api/mount/slew'),
        ('GET', '/api/pairing/active'),
        ('DELETE', '/api/backup/1'),
      ];
      const rank = {'view': 0, 'control': 1, 'admin': 2};

      for (final grant in grants) {
        for (final (method, path) in routes) {
          if (HeadlessAuthPolicy.permits(
            grant: grant,
            method: method,
            path: path,
          )) {
            continue;
          }
          final body = HeadlessAuthPolicy.scopeDenialBody(
            grant: grant,
            method: method,
            path: path,
          );
          if (!body.containsKey('requiredScope')) continue;
          final required = rank[body['requiredScope']]!;
          final held = rank[body['tokenScope']]!;
          expect(
            held,
            lessThan(required),
            reason:
                '$method $path emitted requiredScope=${body['requiredScope']} '
                'beside tokenScope=${body['tokenScope']} on a refusal',
          );
        }
      }
    });
  });
}
