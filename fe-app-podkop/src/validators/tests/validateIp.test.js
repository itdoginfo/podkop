import { describe, it, expect } from 'vitest';
import { validateIPV4, validateIPV6 } from '../validateIp';

export const validIPs = [
  ['Private LAN', '192.168.1.1'],
  ['All zeros', '0.0.0.0'],
  ['Broadcast', '255.255.255.255'],
  ['Simple', '1.2.3.4'],
  ['Loopback', '127.0.0.1'],
];

export const invalidIPs = [
  ['Octet too large', '256.0.0.1'],
  ['Too few octets', '192.168.1'],
  ['Too many octets', '1.2.3.4.5'],
  ['Leading zero (1st octet)', '01.2.3.4'],
  ['Leading zero (2nd octet)', '1.02.3.4'],
  ['Leading zero (3rd octet)', '1.2.003.4'],
  ['Leading zero (4th octet)', '1.2.3.004'],
  ['Four digits in octet', '1.2.3.0004'],
  ['Trailing dot', '1.2.3.'],
];

describe('validateIPV4', () => {
  describe.each(validIPs)('Valid IP: %s', (_desc, ip) => {
    it(`returns {valid:true} for "${ip}"`, () => {
      const res = validateIPV4(ip);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidIPs)('Invalid IP: %s', (_desc, ip) => {
    it(`returns {valid:false} for "${ip}"`, () => {
      const res = validateIPV4(ip);
      expect(res.valid).toBe(false);
    });
  });
});

export const validIPv6 = [
  ['Full form', '2001:0db8:0000:0000:0000:0000:0000:0001'],
  ['Compressed', '2001:db8::1'],
  ['Loopback', '::1'],
  ['Unspecified', '::'],
  ['Leading compression', '::ffff:1'],
  ['Trailing compression', '2001:db8::'],
  ['Link-local', 'fe80::1'],
  ['IPv4-mapped', '::ffff:192.168.1.1'],
  ['Real-world address', '2a0c:16c0:510:eac::e52c'],
];

export const invalidIPv6 = [
  ['IPv4 address', '192.168.1.1'],
  ['Domain', 'example.com'],
  ['Empty string', ''],
  ['Double compression', '2001::db8::1'],
  ['Group too long', '20011:db8::1'],
  ['Non-hex characters', '2001:zzzz::1'],
  ['Still bracketed', '[2001:db8::1]'],
  ['Zone index', 'fe80::1%eth0'],
];

describe('validateIPV6', () => {
  describe.each(validIPv6)('Valid IPv6: %s', (_desc, ip) => {
    it(`returns {valid:true} for "${ip}"`, () => {
      const res = validateIPV6(ip);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidIPv6)('Invalid IPv6: %s', (_desc, ip) => {
    it(`returns {valid:false} for "${ip}"`, () => {
      const res = validateIPV6(ip);
      expect(res.valid).toBe(false);
    });
  });
});
