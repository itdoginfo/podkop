import { describe, expect, it } from 'vitest';
import { validateDomain, validateDomainRule } from '../validateDomain';

export const validDomains = [
  ['Simple domain', 'example.com'],
  ['Subdomain', 'sub.example.com'],
  ['With dash', 'my-site.org'],
  ['With numbers', 'site123.net'],
  ['Deep subdomain', 'a.b.c.example.co.uk'],
  ['With path', 'example.com/path/to/resource'],
  ['Punycode RU', 'xn--d1acufc.xn--p1ai'],
  ['Adguard dns', 'dns.adguard-dns.com'],
  ['Nextdns dns', 'dns.nextdns.io/xxxxxxx'],
  ['Long domain (63 chars in label)', 'a'.repeat(63) + '.com'],
  ['I2P domain (numeric TLD)', 'tracker2.postman.i2p'],
];

export const invalidDomains = [
  ['No TLD', 'localhost'],
  ['Only TLD', '.com'],
  ['Double dot', 'example..com'],
  ['Illegal chars', 'exa!mple.com'],
  ['Space inside', 'exa mple.com'],
  ['Ending with dash', 'example-.com'],
  ['Starting with dash', '-example.com'],
  ['Trailing dot', 'example.com.'],
  ['Too short TLD', 'example.c'],
  ['All-numeric TLD', 'example.123'],
  ['With protocol (not allowed)', 'http://example.com'],
  ['Too long label (>63 chars)', 'a'.repeat(64) + '.com'],
  ['Too long domain (>253 chars)', Array(40).fill('abcdef').join('.') + '.com'],
];

export const dotTLDTests = [
  ['Dot TLD allowed (.net)', '.net', true, true],
  ['Dot TLD not allowed (.net)', '.net', false, false],
  ['Invalid with double dot', '..net', true, false],
  ['Invalid single word TLD (net)', 'net', true, false],
  ['Dot TLD with digit (.i2p)', '.i2p', true, true],
  ['Dot TLD with digit not allowed (.i2p)', '.i2p', false, false],
];

describe('validateDomain', () => {
  describe.each(validDomains)('Valid domain: %s', (_desc, domain) => {
    it(`returns valid=true for "${domain}"`, () => {
      const res = validateDomain(domain);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidDomains)('Invalid domain: %s', (_desc, domain) => {
    it(`returns valid=false for "${domain}"`, () => {
      const res = validateDomain(domain);
      expect(res.valid).toBe(false);
    });
  });

  describe.each(dotTLDTests)(
    'Dot TLD toggle: %s',
    (_desc, domain, allowDotTLD, expected) => {
      it(`"${domain}" with allowDotTLD=${allowDotTLD} → valid=${expected}`, () => {
        const res = validateDomain(domain, allowDotTLD);
        expect(res.valid).toBe(expected);
      });
    },
  );
});

// Domain-rule fields (Custom domains in the section form) go through
// validateDomainRule, which forbids a URL path: the backend rule matches a
// host only, so "example.com/path" must not be accepted by the UI.
export const domainRuleTests = [
  ['Lowercase', 'example.com', true],
  ['Uppercase', 'Example.COM', true],
  ['Uppercase subdomain', 'Sub.Example.COM', true],
  ['Punycode', 'xn--d1acufc.xn--p1ai', true],
  ['With path', 'example.com/path', false],
  ['With deep path', 'example.com/path/to/resource', false],
  ['With protocol', 'http://example.com', false],
  ['No TLD', 'localhost', false],
  ['I2P domain (numeric TLD)', 'tracker2.postman.i2p', true],
];

describe('validateDomainRule', () => {
  describe.each(domainRuleTests)(
    'Domain rule: %s',
    (_desc, domain, expected) => {
      it(`"${domain}" → valid=${expected}`, () => {
        const res = validateDomainRule(domain, true);
        expect(res.valid).toBe(expected);
      });
    },
  );

  it('rejects a path that validateDomain accepts', () => {
    expect(validateDomain('example.com/path').valid).toBe(true);
    expect(validateDomainRule('example.com/path').valid).toBe(false);
  });

  it('keeps the dot-TLD form allowed when allowDotTLD=true', () => {
    expect(validateDomainRule('.net', true).valid).toBe(true);
    expect(validateDomainRule('.net', false).valid).toBe(false);
  });
});

describe('validateDomainRule prefixes', () => {
  it.each([
    ['full:example.com'],
    ['FULL:Sub.Example.com'],
    ['keyword:tracker'],
    ['keyword:my-ads_1.v2'],
    ['regex:^ads[0-9]+\\.example\\.com$'],
    ['regexp:\\d+\\.cdn\\.net'],
  ])('accepts %s', (entry) => {
    expect(validateDomainRule(entry, true).valid).toBe(true);
  });

  it.each([
    ['full:'],
    ['full:not_a_host'],
    ['full:example.com/path'],
    ['keyword:'],
    ['keyword:a b'],
    ['keyword:bad!kw'],
    ['regex:'],
    ['regex:(unclosed'],
    ['regex:a,b'],
    ['regex:' + 'a'.repeat(257)],
  ])('rejects %s', (entry) => {
    expect(validateDomainRule(entry, true).valid).toBe(false);
  });

  it('still rejects an unprefixed entry with a colon', () => {
    expect(validateDomainRule('foo:bar.com', true).valid).toBe(false);
  });
});
