'use strict';

// The pages read RUN_STATE from the script the host serves as js/run-state.js.
// The host builds it from RunStateScript; fixtures/run-state.js is that script
// (kept equal by apps/desktop/test/headless_api/run_state_script_test.dart).
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

if (typeof globalThis.RUN_STATE === 'undefined') {
  const source = fs.readFileSync(path.join(__dirname, 'fixtures', 'run-state.js'), 'utf8');
  globalThis.RUN_STATE = vm.runInThisContext(`${source}\nRUN_STATE;`);
}
