import { describe, expect, it } from 'vitest';
import { validateDNS } from '../validateDns.js';
import { invalidIPs, validIPs } from './validateIp.test';
import { invalidDomains, validDomains } from './validateDomain.test';

const validDns = [...validIPs, ...validDomains];

const invalidDns = [...invalidIPs, ...invalidDomains];

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
