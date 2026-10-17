/*
 * Skotiq Run-Watch — service worker.
 *
 * Responsibilities:
 *
 *   1. Offline shell — cache index.html + CSS + JS + manifest + icons so
 *      the SPA opens instantly on a flaky LAN even when the rig
 *      computer is briefly unreachable. We do NOT cache /api/*; live
 *      data must always come from the server (or surface as
 *      "reconnecting" in the UI).
 *
 *   2. Push notifications — the Push API delivers an opaque payload
 *      from the desktop's push notification stream when the user has
 *      opted in. We just unwrap the JSON and surface it as a system
 *      notification with the click action wired back to /run-watch/.
 *
 *   3. Auto-update — bump CACHE_VERSION when shipping a new bundle to
 *      invalidate the offline shell across all installed instances.
 */
'use strict';

const CACHE_VERSION = 'skotiq-run-watch-v1';
const SHELL_FILES = [
  '/run-watch/',
  '/run-watch/index.html',
  '/run-watch/css/style.css',
  '/run-watch/js/run-watch.js',
  '/run-watch/manifest.json',
  '/run-watch/icons/icon.svg',
  '/run-watch/icons/icon-192.svg',
  '/run-watch/icons/icon-512.svg',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) => cache.addAll(SHELL_FILES)),
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((k) => k !== CACHE_VERSION)
          .map((k) => caches.delete(k)),
      ),
    ),
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // Never intercept API or SSE traffic. Even a single cached snapshot
  // would mislead the operator about the rig state. The point of the
  // service worker is to keep the UI shell available, not the data.
  if (url.pathname.startsWith('/api/')) {
    return;
  }

  // Only handle GETs from our scope.
  if (event.request.method !== 'GET') return;
  if (!url.pathname.startsWith('/run-watch/')) return;

  event.respondWith(
    caches.open(CACHE_VERSION).then(async (cache) => {
      try {
        const fresh = await fetch(event.request);
        // Update cache opportunistically so the next launch has the
        // newest shell. Only cache 2xx so a 404 doesn't poison the
        // offline copy.
        if (fresh && fresh.ok) {
          cache.put(event.request, fresh.clone());
        }
        return fresh;
      } catch (_) {
        const cached = await cache.match(event.request);
        if (cached) return cached;
        // Fallback to root index for SPA navigation requests.
        if (event.request.mode === 'navigate') {
          const root = await cache.match('/run-watch/index.html');
          if (root) return root;
        }
        return new Response('Offline', { status: 503, statusText: 'Offline' });
      }
    }),
  );
});

// Web Push handler — the Push API delivers a binary payload that we
// expect to be JSON-encoded. The desktop's push notification service
// (see PushNotificationService) emits `{ title, body, eventType,
// category }` envelopes; mirror that shape here.
self.addEventListener('push', (event) => {
  let payload = {};
  if (event.data) {
    try { payload = event.data.json(); }
    catch { payload = { title: 'Skotiq', body: event.data.text() }; }
  }
  const title = payload.title || 'Skotiq';
  const body = payload.body || payload.message || '';
  event.waitUntil(
    self.registration.showNotification(title, {
      body,
      icon: '/run-watch/icons/icon-192.svg',
      badge: '/run-watch/icons/icon-192.svg',
      tag: payload.eventType || 'skotiq',
      data: payload,
      vibrate: [200, 80, 200],
      requireInteraction: payload.severity === 'critical',
    }),
  );
});

// Notification click — focus the existing tab if any, else open a new one.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    const allClients = await self.clients.matchAll({
      type: 'window',
      includeUncontrolled: true,
    });
    for (const client of allClients) {
      if (client.url.includes('/run-watch/') && 'focus' in client) {
        return client.focus();
      }
    }
    if (self.clients.openWindow) {
      return self.clients.openWindow('/run-watch/');
    }
  })());
});

// Allow the page to ask us to take over immediately after activation.
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
