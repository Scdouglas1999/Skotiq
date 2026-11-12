// A DSLR or mirrorless camera's gain is one of its ISO speeds: the camera
// panel's gain field becomes an ISO picker and the offset row goes. The
// render path is lifted out of app.js and executed against the DOM shim, as
// in dashboard_honesty_test.js.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const { makeDocument } = require('./dom_shim');

const APP = fs.readFileSync(path.join(__dirname, '..', 'js', 'app.js'), 'utf8');
const HTML = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

function fn(name) {
  const re = new RegExp(
    '(?:  |  async )function ' + name + '\\([^)]*\\) \\{[\\s\\S]*?\\n  \\}',
  );
  const m = APP.match(re);
  assert.ok(m, name + ' must exist in app.js');
  return m[0];
}

function build(params, sources, exportName) {
  // eslint-disable-next-line no-new-func
  return new Function(...params, sources.join('\n') + '\n;return ' + exportName + ';');
}

const IDS = [
  'camera-gain', 'camera-iso', 'camera-gain-label', 'camera-offset-row',
  'btn-camera-apply-gain',
];

function panel(isoSpeeds, gain) {
  const doc = makeDocument(IDS);
  doc.getElementById('camera-gain').value = String(gain);
  const state = { cameraIsoSpeeds: isoSpeeds };
  const lifted = build(
    ['document', 'state'],
    [fn('clearElement'), fn('nearestIsoSpeed'), fn('currentCameraGain'),
      fn('renderCameraSensitivity')],
    '{ renderCameraSensitivity, currentCameraGain }',
  )(doc, state);
  lifted.renderCameraSensitivity();
  return { doc, state, ...lifted };
}

test('the page carries the ISO picker and a hideable offset row', () => {
  assert.match(HTML, /<select id="camera-iso"[^>]*hidden/);
  assert.match(HTML, /id="camera-offset-row"/);
});

test('a DSLR reads ISO with its own speeds and no offset', () => {
  const { doc, currentCameraGain } = panel([100, 200, 400, 800, 1600], 850);
  assert.equal(doc.getElementById('camera-gain-label').textContent, 'ISO');
  assert.equal(doc.getElementById('camera-gain').hidden, true);
  const select = doc.getElementById('camera-iso');
  assert.equal(select.hidden, false);
  assert.deepEqual(select.children.map((o) => o.textContent), ['100', '200', '400', '800', '1600']);
  assert.equal(select.value, '800', 'a gain between speeds shows the one the camera takes');
  assert.equal(doc.getElementById('camera-offset-row').hidden, true);
  select.value = '1600';
  assert.equal(currentCameraGain(), 1600);
});

test('a gain camera keeps the gain field and the offset row', () => {
  const { doc, currentCameraGain } = panel([], 120);
  assert.equal(doc.getElementById('camera-gain-label').textContent, 'Gain');
  assert.equal(doc.getElementById('camera-gain').hidden, false);
  assert.equal(doc.getElementById('camera-iso').hidden, true);
  assert.equal(doc.getElementById('camera-offset-row').hidden, false);
  assert.equal(currentCameraGain(), 120);
});
