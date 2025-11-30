import { describe, it, expect } from 'vitest';
import { validateHysteria2Url } from '../validateHysteriaUrl.js';

const validUrls = [
  // Basic password-only
  ['password basic', 'hysteria2://pass@example.com:443/#hy2-basic'],

  // insecure=1
  [
    'insecure allowed',
    'hysteria2://pass@example.com:443/?insecure=1#hy2-insecure',
  ],

  // SNI
  ['SNI param', 'hysteria2://pass@example.com:443/?sni=google.com#hy2-sni'],

  // Obfuscation
  [
    'Obfs + password',
    'hysteria2://mypassword@1.1.1.1:8443/?obfs=salamander&obfs-password=abc123#hy2-obfs',
  ],

  // All params
  [
    'All options combined',
    'hysteria2://pw@8.8.8.8:8443/?sni=example.com&obfs=salamander&obfs-password=hello&insecure=1#hy2-full',
  ],

  // Explicit obfs=none (valid)
  ['obfs none = ok', 'hysteria2://pw@example.com:443/?obfs=none#hy2-none'],
];

const invalidUrls = [
  ['No prefix', 'pw@example.com:443'],
  ['Missing password', 'hysteria2://@example.com:443/'],
  ['Missing host', 'hysteria2://pw@:443/'],
  ['Missing port', 'hysteria2://pw@example.com/'],
  ['Non-numeric port', 'hysteria2://pw@example.com:port/'],
  ['Port out of range', 'hysteria2://pw@example.com:99999/'],

  // Obfuscation errors
  ['Unknown obfs type', 'hysteria2://pw@example.com:443/?obfs=weird'],
  [
    'obfs without obfs-password',
    'hysteria2://pw@example.com:443/?obfs=salamander',
  ],

  // insecure only accepts 0/1
  ['invalid insecure', 'hysteria2://pw@example.com:443/?insecure=5'],

  // SNI empty
  ['empty sni', 'hysteria2://pw@example.com:443/?sni='],
];

describe('validateHysteria2Url', () => {
  describe.each(validUrls)('Valid HY2 URL: %s', (_desc, url) => {
    it(`returns valid=true for "${url}"`, () => {
      const res = validateHysteria2Url(url);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidUrls)('Invalid HY2 URL: %s', (_desc, url) => {
    it(`returns valid=false for "${url}"`, () => {
      const res = validateHysteria2Url(url);
      expect(res.valid).toBe(false);
    });
  });

  it('detects invalid port range', () => {
    const res = validateHysteria2Url('hysteria2://pw@example.com:70000/');
    expect(res.valid).toBe(false);
  });
});
