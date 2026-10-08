import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, describe, expect, it } from 'vitest';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const callsFile = path.join(root, 'locales/calls.json');
const original = readFileSync(callsFile, 'utf8');

function extract() {
  execFileSync('node', ['extract-calls.js'], { cwd: root, stdio: 'ignore' });

  return readFileSync(callsFile, 'utf8');
}

describe('extract-calls', () => {
  afterAll(() => {
    writeFileSync(callsFile, original);
  });

  // each run parses every source file: more than the default 5 s on a busy runner
  it('gives the same catalogue on every run', { timeout: 60000 }, () => {
    const first = extract();

    for (let run = 0; run < 5; run++) {
      expect(extract()).toBe(first);
    }
  });
});
