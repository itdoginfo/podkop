import { describe, it, expect } from 'vitest';
import { validateIP, validateIPV4, validateIPV6 } from '../validateIp';

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

export const validIPv6 = [
  ['Loopback', '::1'],
  ['Compressed', '2001:db8::1'],
  ['Full form', '2001:0db8:85a3:0000:0000:8a2e:0370:7334'],
  ['Bracketed', '[2001:db8::1]'],
  ['Unspecified', '::'],
  ['Compressed middle', '2001:db8:0:0:1::1'],
  ['IPv4-mapped', '::ffff:192.168.1.1'],
  ['IPv4-embedded', '2001:db8::192.168.1.1'],
];

export const invalidIPv6 = [
  ['Invalid hex', '2001:db8::zzzz'],
  ['Group too long', '12345::1'],
  ['Too many groups', '2001:db8:85a3:0:0:8a2e:370:7334:1234'],
  ['Triple colon only', ':::'],
  ['Colon run inside', '1:2:::3'],
  ['Multiple compressions', '1::2::3'],
  ['Incomplete (7 groups, no ::)', '1:2:3:4:5:6:7'],
  ['Bad hex group', 'gggg::1'],
  ['Too many groups (9)', '1:2:3:4:5:6:7:8:9'],
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

describe('validateIPV6', () => {
  describe.each(validIPv6)('Valid IPv6: %s', (_desc, ip) => {
    it(`returns {valid:true} for "${ip}"`, () => {
      const res = validateIPV6(ip);
      expect(res.valid).toBe(true);
    });
  });

  describe.each([...invalidIPv6, ['IPv4 address', '192.168.1.1']])(
    'Invalid IPv6: %s',
    (_desc, ip) => {
      it(`returns {valid:false} for "${ip}"`, () => {
        const res = validateIPV6(ip);
        expect(res.valid).toBe(false);
      });
    },
  );
});

describe('validateIP', () => {
  describe.each([...validIPs, ...validIPv6])('Valid IP: %s', (_desc, ip) => {
    it(`returns {valid:true} for "${ip}"`, () => {
      const res = validateIP(ip);
      expect(res.valid).toBe(true);
    });
  });

  describe.each([...invalidIPs, ...invalidIPv6])(
    'Invalid IP: %s',
    (_desc, ip) => {
      it(`returns {valid:false} for "${ip}"`, () => {
        const res = validateIP(ip);
        expect(res.valid).toBe(false);
      });
    },
  );
});
