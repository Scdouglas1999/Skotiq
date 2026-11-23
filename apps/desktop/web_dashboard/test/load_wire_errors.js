'use strict';

// The pages read WIRE_ERROR_CODES from the script the host serves as
// js/wire-errors.js. The host builds it from ApiErrorCodes; fixtures/wire-errors.js
// is that script (kept equal by apps/desktop/test/headless_api/wire_errors_fixture_test.dart).
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

if (typeof globalThis.WIRE_ERROR_CODES === 'undefined') {
  const source = fs.readFileSync(path.join(__dirname, 'fixtures', 'wire-errors.js'), 'utf8');
  globalThis.WIRE_ERROR_CODES = vm.runInThisContext(`${source}\nWIRE_ERROR_CODES;`);
}
