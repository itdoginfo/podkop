import { describe, expect, it } from 'vitest';
import { isNaiveUrl, validateNaiveUrl } from '../validateNaiveUrl';
import { validateProxyUrl } from '../validateProxyUrl';

const valid = [
  ['plain https with a login', 'https://alex:qwerty123@hommie.mooo.com:443'],
  ['no port', 'naive+https://alex:qwerty123@hommie.mooo.com'],
  ['quic', 'naive+quic://u:p@example.com:8443'],
  ['an address', 'naive+https://u:p@203.0.113.9:443'],
  ['with a name', 'naive+https://u:p@example.com:443#My%20node'],
  ['an encoded login', 'https://al%40ex:p%3Ass@example.com:443'],
];

const invalid = [
  ['no login', 'naive+https://example.com:443'],
  ['no password', 'naive+https://alex@example.com:443'],
  ['empty login', 'naive+https://:pass@example.com:443'],
  ['port zero', 'naive+https://u:p@example.com:0'],
  ['port too big', 'naive+https://u:p@example.com:70000'],
  ['spaces', 'naive+https://u:p@exa mple.com:443'],
  ['bad host', 'naive+https://u:p@bad_host!:443'],
];

describe('validateNaiveUrl', () => {
  it.each(valid)('accepts: %s', (_n, url) => {
    expect(validateNaiveUrl(url).valid).toBe(true);
    expect(validateProxyUrl(url).valid).toBe(true);
  });

  it.each(invalid)('rejects: %s', (_n, url) => {
    expect(validateNaiveUrl(url).valid).toBe(false);
  });

  it('takes an https link only with a login', () => {
    expect(isNaiveUrl('https://example.com')).toBe(false);
    expect(isNaiveUrl('https://u:p@example.com')).toBe(true);
    expect(isNaiveUrl('naive+quic://u:p@example.com')).toBe(true);
    expect(isNaiveUrl('vless://u@example.com')).toBe(false);
  });
});
