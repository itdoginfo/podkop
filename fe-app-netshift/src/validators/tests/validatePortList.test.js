import { describe, expect, it } from 'vitest';
import { validatePortList } from '../validatePortList';

describe('validatePortList', () => {
  it.each([
    ['empty', ''],
    ['one port', '443'],
    ['several', '80,443'],
    ['spaces and commas', '80, 443 8080'],
    ['a range with a dash', '1000-2000'],
    ['a range with a colon', '5000:5100'],
    ['mixed', '80,443,1000-2000'],
    ['the edges', '1,65535,1-65535'],
  ])('accepts: %s', (_name, value) => {
    expect(validatePortList(value).valid).toBe(true);
  });

  it.each([
    ['zero', '0'],
    ['too big', '65536'],
    ['text', 'abc'],
    ['range backwards', '2000-1000'],
    ['open range', '1000-'],
    ['negative', '-5'],
    ['range to zero', '0-10'],
    ['range past the top', '60000-70000'],
    ['one bad among good', '80,x,443'],
  ])('rejects: %s', (_name, value) => {
    expect(validatePortList(value).valid).toBe(false);
  });
});
