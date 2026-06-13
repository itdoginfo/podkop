import { describe, it, expect } from 'vitest';
import { validateUrl } from '../validateUrl';

const validUrls = [
  ['Simple HTTP', 'http://example.com'],
  ['Simple HTTPS', 'https://example.com'],
  ['With path', 'https://example.com/path/to/page'],
  ['With query', 'https://example.com/?q=test'],
  ['With port', 'http://example.com:8080'],
  ['With subdomain', 'https://sub.example.com'],
  ['IPv4 host with port and path', 'https://91.199.111.52:2096/sub/abc'],
  ['IPv4 host with path', 'http://10.0.0.1/x'],
  ['Bracketed IPv6 host with port and path', 'https://[2001:db8::1]:2096/sub'],
];

const invalidUrls = [
  ['Invalid format', 'not a url'],
  ['Missing protocol', 'example.com'],
  ['Unsupported protocol (ftp)', 'ftp://example.com'],
  ['Unsupported protocol (ws)', 'ws://example.com'],
  ['Empty string', ''],
  ['Without tld', 'https://google'],
  ['Bad IPv4 host', 'https://999.1.1.1/x'],
  ['Bad protocol with IP host', 'ftp://1.2.3.4'],
  ['No host', 'https://'],
];

describe('validateUrl', () => {
  describe.each(validUrls)('Valid URL: %s', (_desc, url) => {
    it(`returns valid=true for "${url}"`, () => {
      const res = validateUrl(url);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidUrls)('Invalid URL: %s', (_desc, url) => {
    it(`returns valid=false for "${url}"`, () => {
      const res = validateUrl(url);
      expect(res.valid).toBe(false);
    });
  });

  it('allows custom protocol list (ftp)', () => {
    const res = validateUrl('ftp://example.com', ['ftp:']);
    expect(res.valid).toBe(true);
  });
});
