import { describe, expect, it } from 'vitest';
import { validateDNS } from '../validateDns.js';
import { invalidIPs, validIPs } from './validateIp.test';
import { invalidDomains, validDomains } from './validateDomain.test';

export const additionalValidDns = [
  ['Google DNS (port 53)', '8.8.8.8:53'],
  ['Google DNS (port 5353)', '8.8.8.8:5353'],
  ['Cloudflare DNS (port 853)', '1.1.1.1:853'],
  ['Cloudflare domain (port 853)', 'cloudflare-dns.com:853'],
  ['DoH IP', '1.1.1.1/dns-query'],
  ['DoH IP with port 443', '1.1.1.1:443/dns-query'],
  ['DoH domain', 'cloudflare-dns.com/dns-query'],
  ['DoH domain with port 443', 'cloudflare-dns.com:443/dns-query'],
  ['IPv6 address', '2001:db8::1'],
  ['Bracketed IPv6', '[2001:db8::1]'],
  ['Bracketed IPv6 with port', '[2001:db8::1]:853'],
  ['IPv6 DoH path', '2001:db8::1/dns-query'],
  ['Bracketed IPv6 DoH path with port', '[2001:db8::1]:443/dns-query'],
];

export const additionalInvalidDns = [
  ['IPv6 invalid hex', '2001:db8::zzzz'],
  ['IPv6 group too long', '12345::1'],
  ['IPv6 triple colon only', ':::'],
  ['IPv6 multiple compressions', '1::2::3'],
];

const validDns = [...validIPs, ...validDomains, ...additionalValidDns];

const invalidDns = [...invalidIPs, ...invalidDomains, ...additionalInvalidDns];

describe('validateDns', () => {
  describe.each(validDns)('Valid dns: %s', (_desc, domain) => {
    it(`returns valid=true for "${domain}"`, () => {
      const res = validateDNS(domain);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidDns)('Invalid dns: %s', (_desc, domain) => {
    it(`returns valid=false for "${domain}"`, () => {
      const res = validateDNS(domain);
      expect(res.valid).toBe(false);
    });
  });
});
