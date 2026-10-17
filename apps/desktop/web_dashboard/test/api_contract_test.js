const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

function createClient(overrides) {
  const apiPath = path.join(__dirname, '..', 'js', 'api.js');
  const source = fs.readFileSync(apiPath, 'utf8');
  const sandbox = {
    AbortController,
    Map,
    Set,
    URLSearchParams,
    clearInterval,
    clearTimeout,
    console,
    ...(overrides || {}),
    setInterval,
    setTimeout,
  };
  vm.createContext(sandbox);
  vm.runInContext(`${source}\nthis.TestApi = SkotiqApi;`, sandbox);
  return new sandbox.TestApi();
}

test('dome sync sends the host enable key for both toggle states', async () => {
  const client = createClient();
  const requests = [];
  client._post = async (requestPath, body) => {
    requests.push({ requestPath, body });
    return {};
  };

  await client.domeSyncToMount('dome-1', true);
  await client.domeSyncToMount('dome-1', false);

  // Bodies originate in the VM context, so normalize away cross-realm object
  // prototypes before structural comparison.
  assert.deepEqual(JSON.parse(JSON.stringify(requests)), [
    {
      requestPath: '/api/dome/sync',
      body: { deviceId: 'dome-1', enable: true },
    },
    {
      requestPath: '/api/dome/sync',
      body: { deviceId: 'dome-1', enable: false },
    },
  ]);
});

test('saved sequence load-and-start stays server-side and uses a numeric id', async () => {
  const client = createClient();
  const requests = [];
  client._get = async () => {
    throw new Error('load-and-start must not synthesize native JSON in JS');
  };
  client._post = async (requestPath, body) => {
    requests.push({ requestPath, body });
    return { status: 'started' };
  };

  await client.sequencerLoadAndStart('42');

  assert.deepEqual(JSON.parse(JSON.stringify(requests)), [
    {
      requestPath: '/api/sequencer/load-and-start',
      body: { sequenceId: 42 },
    },
  ]);
  await assert.rejects(
    client.sequencerLoadAndStart('not-a-number'),
    /Invalid sequence id/,
  );
});

test('bearer gallery media uses authenticated blob requests, never URL tokens', async () => {
  const fetches = [];
  const client = createClient({
    fetch: async (url, options) => {
      fetches.push({ url, options });
      return {
        ok: true,
        status: 200,
        headers: { get: () => '' },
        blob: async () => ({}),
        text: async () => '',
      };
    },
  });
  client.configure('http://skotiq.local:8080', 'secret-token', 'browser-1');

  assert.equal(client.usesHeaderAuth, true);
  assert.equal(
    client.imageDownloadUrl(7),
    'http://skotiq.local:8080/api/images/7/download',
  );
  assert.equal(client.imageDownloadUrl(7).includes('access_token'), false);

  await client.imageThumbnailBlob(7, { maxWidth: 280, quality: 70 });
  await client.imageDownloadBlob(7);
  assert.deepEqual(fetches.map((entry) => entry.url), [
    'http://skotiq.local:8080/api/images/7/thumbnail?maxWidth=280&quality=70',
    'http://skotiq.local:8080/api/images/7/download',
  ]);
  assert.equal(fetches[0].options.headers.Authorization, 'Bearer secret-token');
  assert.equal(fetches[1].options.headers.Authorization, 'Bearer secret-token');
});

test('remembered cookie sessions mint a WebSocket ticket', async () => {
  const openedUrls = [];
  class FakeWebSocket {
    static CONNECTING = 0;
    static OPEN = 1;

    constructor(url) {
      openedUrls.push(url);
      this.readyState = FakeWebSocket.CONNECTING;
    }
  }

  const client = createClient({ WebSocket: FakeWebSocket });
  client.configure('http://skotiq.local:8080', '', 'browser-1');
  client._useSessionCookie = true;
  client._csrfToken = 'cookie-csrf';
  let ticketRequests = 0;
  client.issueWebSocketTicket = async () => {
    ticketRequests += 1;
    return { ticket: 'cookie-ws-ticket', expiresInSeconds: 60 };
  };

  await client.connectWebSocket();

  assert.equal(ticketRequests, 1);
  assert.equal(openedUrls.length, 1);
  const socketUrl = new URL(openedUrls[0]);
  assert.equal(socketUrl.protocol, 'ws:');
  assert.equal(socketUrl.pathname, '/events');
  assert.equal(socketUrl.searchParams.get('ticket'), 'cookie-ws-ticket');
  assert.equal(socketUrl.searchParams.get('token'), null);
  assert.equal(socketUrl.searchParams.get('deviceId'), 'browser-1');
});

test('raw image data decodes the little-endian u16 wire contract', async () => {
  const bytes = Uint8Array.from([
    0x00, 0x00,
    0x01, 0x00,
    0xff, 0x00,
    0x00, 0x01,
    0x34, 0x12,
    0xff, 0xff,
  ]);
  const client = createClient({
    fetch: async () => ({
      ok: true,
      status: 200,
      arrayBuffer: async () => bytes.buffer,
      headers: { get: () => 'application/octet-stream' },
      text: async () => '',
    }),
  });
  client.configure('http://skotiq.local:8080', 'secret-token', 'browser-1');

  const pixels = await client.getLastRawImageData('cam-1');

  assert.deepEqual(Array.from(pixels), [0, 1, 255, 256, 0x1234, 0xffff]);
});

test('target search merges saved targets with installed catalog objects', async () => {
  const client = createClient();
  client._get = async (requestPath) => {
    if (requestPath.startsWith('/api/targets/search')) {
      return {
        targets: [{
          id: 7,
          name: 'Saved target',
          catalogId: 'USER-7',
          ra: 1,
          dec: 2,
        }],
      };
    }
    if (requestPath.startsWith('/api/planetarium/catalog/search')) {
      return {
        results: [{
          name: 'Andromeda Galaxy',
          catalogId: 'M31',
          ra: 10.684,
          raHours: 0.7123,
          dec: 41.269,
          type: 'Galaxy',
        }],
      };
    }
    throw new Error('Unexpected request: ' + requestPath);
  };

  const result = await client.targetsSearch('M31');

  assert.equal(result.targets.length, 2);
  assert.equal(result.targets[1].catalogId, 'M31');
  assert.equal(result.targets[1].ra, 0.7123);
  assert.equal(result.targets[1].id, null);
});

test('WebSocket heartbeat frames emit activity without becoming app events', async () => {
  class FakeWebSocket {
    static CONNECTING = 0;
    static OPEN = 1;

    constructor() {
      this.readyState = FakeWebSocket.CONNECTING;
      this.sent = [];
    }

    send(payload) {
      this.sent.push(payload);
    }

    close() {
      this.readyState = FakeWebSocket.CONNECTING;
    }
  }

  const client = createClient({ WebSocket: FakeWebSocket });
  client.configure('http://skotiq.local:8080', 'secret-token', 'browser-1');
  const activity = [];
  const events = [];
  client.on('ws:activity', (data) => activity.push(data));
  client.on('event', (data) => events.push(data));
  await client.connectWebSocket();
  client._ws.readyState = FakeWebSocket.OPEN;
  client._ws.onopen();
  client._ws.onmessage({ data: JSON.stringify({ type: 'pong' }) });

  assert.deepEqual(JSON.parse(JSON.stringify(activity)), [{ type: 'pong' }]);
  assert.deepEqual(events, []);
  client.disconnectWebSocket();
});

// ---------------------------------------------------------------------------
// D4-01 / D4-02 — a 2xx that carries nothing is a FAILED exchange
//
// `if (!text) return {}` handed every caller a well-formed empty payload.
// Measured against the release bundle with four connected simulator devices
// and twelve registered frames on the wire: an empty-bodied 200 on
// /api/devices/connected made the dashboard state "No devices connected" with
// no stale line, no toast and no log entry, header still reading "Connected";
// the same body — and a body of `null` — on /api/images produced "No captured
// images yet." over the twelve. The sibling client already refuses this shape.
// ---------------------------------------------------------------------------

function answeringClient(body, status) {
  return createClient({
    fetch: async () => ({
      ok: (status || 200) < 400,
      status: status || 200,
      headers: new Map([['content-type', 'application/json']]),
      text: async () => body,
    }),
  });
}

test('a 200 with an empty body is refused, never read as an empty payload', async () => {
  const client = answeringClient('');
  await assert.rejects(
    () => client.getConnectedDevices(),
    (e) => {
      assert.equal(e.kind, 'unusable_answer');
      assert.match(e.message, /empty body/);
      assert.equal(e.detail.status, 200);
      return true;
    },
  );
});

test('a 200 whose body is JSON null carries no answer either', async () => {
  const client = answeringClient('null');
  await assert.rejects(
    () => client.imagesGetAll({ limit: 24 }),
    (e) => e.kind === 'unusable_answer' && /body is null/.test(e.message),
  );
});

test('the other falsy JSON scalars are refused by the same rule', async () => {
  for (const body of ['0', 'false', '""']) {
    const client = answeringClient(body);
    await assert.rejects(
      () => client.getStatus(),
      (e) => e.kind === 'unusable_answer',
      'body ' + body + ' must not be read as a payload',
    );
  }
});

test('a body that says empty IS an answer, and is delivered as one', async () => {
  const client = answeringClient('{"devices":[]}');
  assert.deepEqual(
    JSON.parse(JSON.stringify(await client.getConnectedDevices())),
    { devices: [] },
    'a server that lists zero devices has told the dashboard something',
  );
});

test('a refusal message never interpolates the body it refused', async () => {
  const client = answeringClient('""');
  await assert.rejects(
    () => client.getStatus(),
    (e) => !e.message.includes('""') && /empty string/.test(e.message),
  );
});

// ---------------------------------------------------------------------------
// A 2xx whose body is TRUTHY but is not an object is the same failed exchange.
//
// The falsy-only guard let a list or a bare scalar through as a payload.
// Measured against the release bundle with a single CDP interceptor on
// /api/info and everything else genuinely live: a 200 carrying `[1,2,3]` —
// identically `"hello"`, `42` and `true` — logged
// `SYSTEM  Connected to undefined vundefined` into the operator's Event Log,
// left the header pill reading "Connected", and dropped the "Auth" chip the
// control run showed, because `info.authRequired` was `undefined` and the
// needs-credential branch never fired.
// ---------------------------------------------------------------------------

test('a 200 whose body is a JSON list is refused, not read as a payload',
  async () => {
    const client = answeringClient('[1,2,3]');
    await assert.rejects(
      () => client.getInfo(),
      (e) => {
        assert.equal(e.kind, 'unusable_answer');
        assert.match(e.message, /body is a list/);
        assert.equal(e.detail.status, 200);
        return true;
      },
    );
  });

test('an empty JSON list is refused too — a list is not an object',
  async () => {
    const client = answeringClient('[]');
    await assert.rejects(
      () => client.getConnectedDevices(),
      (e) => e.kind === 'unusable_answer' && /body is a list/.test(e.message),
      'an empty list has no "devices" field and must not stand in for one',
    );
  });

test('the truthy JSON scalars are refused by the same rule', async () => {
  const cases = [
    ['"hello"', /body is a string/],
    ['42', /body is a number/],
    ['true', /body is the boolean true/],
    ['-1.5', /body is a number/],
  ];
  for (const [body, pattern] of cases) {
    const client = answeringClient(body);
    await assert.rejects(
      () => client.getInfo(),
      (e) => e.kind === 'unusable_answer' && pattern.test(e.message),
      'body ' + body + ' must not be read as a payload',
    );
  }
});

test('a refusal message never interpolates a truthy non-object body',
  async () => {
    const client = answeringClient('"sudo rm -rf /"');
    await assert.rejects(
      () => client.getInfo(),
      (e) => !e.message.includes('sudo') && /body is a string/.test(e.message),
    );
  });

test('every wrapper method routes through the same shape guard', async () => {
  // The guard lives in `_request`, so `_get`/`_post`/`_put`/`_delete` and
  // `_getWithTimeout` all inherit it — one method per wrapper proves the
  // whole surface, and `connect()` covers the timeout path that reads
  // /api/info during the handshake.
  const client = answeringClient('[1,2,3]');
  const calls = [
    ['_get',    () => client.getStatus()],
    ['_post',   () => client.sequencerStart()],
    ['_put',    () => client.targetsUpdate('t1', { name: 'M31' })],
    ['_delete', () => client._delete('/api/targets/t1')],
    ['_getWithTimeout', () => client._getWithTimeout('/api/info', 1000)],
  ];
  for (const [wrapper, call] of calls) {
    await assert.rejects(
      call,
      (e) => e.kind === 'unusable_answer',
      wrapper + ' must refuse a non-object answer like every other caller',
    );
  }
});

test('an object body is still delivered untouched', async () => {
  const client = answeringClient(
    '{"name":"Skotiq Headless","version":"6.2.0","authRequired":true}',
  );
  const info = JSON.parse(JSON.stringify(await client.getInfo()));
  assert.equal(info.name, 'Skotiq Headless');
  assert.equal(info.version, '6.2.0');
  assert.equal(info.authRequired, true);
});
