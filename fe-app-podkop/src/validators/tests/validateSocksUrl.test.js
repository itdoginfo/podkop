import { describe, it, expect } from 'vitest';
import { validateSocksUrl } from '../validateSocksUrl';

const validUrls = [
  ['socks4 basic', 'socks4://127.0.0.1:1080'],
  ['socks4a basic', 'socks4a://127.0.0.1:1080'],
  ['socks5 basic', 'socks5://127.0.0.1:1080'],
  ['socks5 with username', 'socks5://user@127.0.0.1:1080'],
  ['socks5 with username/password', 'socks5://user:pass@127.0.0.1:1080'],
  ['socks5 with domain', 'socks5://user:pass@my.proxy.com:1080'],
  ['socks5 with dash in domain', 'socks5://user:pass@fast-proxy.net:8080'],
  ['socks5 with uppercase domain', 'socks5://USER:PASSWORD@Example.COM:1080'],
];

const invalidUrls = [
  ['no prefix', '127.0.0.1:1080'],
  ['wrong prefix', 'http://127.0.0.1:1080'],
  ['missing host', 'socks5://user:pass@:1080'],
  ['missing port', 'socks5://127.0.0.1'],
  ['invalid port (non-numeric)', 'socks5://127.0.0.1:abc'],
  ['invalid port (too high)', 'socks5://127.0.0.1:99999'],
  ['space in url', 'socks5://127.0. 0.1:1080'],
  ['missing username when auth provided', 'socks5://:pass@127.0.0.1:1080'],
  ['invalid domain chars', 'socks5://user:pass@exa_mple.com:1080'],
  ['extra symbol', 'socks5:///127.0.0.1:1080'],
];

describe('validateSocksUrl', () => {
  describe.each(validUrls)('Valid URL: %s', (_desc, url) => {
    it(`returns valid=true for "${url}"`, () => {
      const res = validateSocksUrl(url);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidUrls)('Invalid URL: %s', (_desc, url) => {
    it(`returns valid=false for "${url}"`, () => {
      const res = validateSocksUrl(url);
      expect(res.valid).toBe(false);
    });
  });

  it('detects invalid port range (0)', () => {
    const res = validateSocksUrl('socks5://127.0.0.1:0');
    expect(res.valid).toBe(false);
  });

  it('detects invalid port range (65536)', () => {
    const res = validateSocksUrl('socks5://127.0.0.1:65536');
    expect(res.valid).toBe(false);
  });
});
