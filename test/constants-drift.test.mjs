import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const lua = fs.readFileSync(new URL('../contracts/constants.lua', import.meta.url), 'utf8');
const provenance = JSON.parse(fs.readFileSync(
  new URL('../provenance/orderbook-settings.json', import.meta.url), 'utf8',
));

test('the focused Lua constants match the split-provenance snapshot', () => {
  assert.equal(provenance.sourceCommit, 'e1dc6602f7603d6ca86f67ad1d30bd6fc5979630');
  for (const [name, value] of Object.entries(provenance.settings)) {
    if (name === 'intraday') continue;
    assert.match(lua, new RegExp(`\\b${name}\\s*=\\s*${value}\\b`), `${name} drifted`);
  }
  for (const { seconds, bars } of provenance.settings.intraday) {
    assert.match(
      lua,
      new RegExp(`\\{\\s*seconds\\s*=\\s*${seconds}\\s*,\\s*bars\\s*=\\s*${bars}\\s*\\}`),
      `intraday ${seconds}s drifted`,
    );
  }
});
