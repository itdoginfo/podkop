import { describe, it, expect } from 'vitest';
import { validateSubnet } from '../validateSubnet';

export const validSubnets = [
  ['Simple IP', '192.168.1.1'],
  ['With CIDR /24', '192.168.1.1/24'],
  ['CIDR /0', '10.0.0.1/0'],
  ['CIDR /32', '172.16.0.1/32'],
  ['Loopback', '127.0.0.1'],
  ['Broadcast with mask', '255.255.255.255/32'],
];

export const invalidSubnets = [
  ['Empty string', ''],
  ['Bad format letters', 'abc.def.ghi.jkl'],
  ['Octet too large', '300.1.1.1'],
  ['Negative octet', '-1.2.3.4'],
  ['Too many octets', '1.2.3.4.5'],
  ['Not enough octets', '192.168.1'],
  ['Leading zero octet', '01.2.3.4'],
  ['Invalid CIDR (too high)', '192.168.1.1/33'],
  ['Invalid CIDR (negative)', '192.168.1.1/-1'],
  ['CIDR not number', '192.168.1.1/abc'],
  ['Forbidden 0.0.0.0', '0.0.0.0'],
];

describe('validateSubnet', () => {
  describe.each(validSubnets)('Valid subnet: %s', (_desc, subnet) => {
    it(`returns {valid:true} for "${subnet}"`, () => {
      const res = validateSubnet(subnet);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidSubnets)('Invalid subnet: %s', (_desc, subnet) => {
    it(`returns {valid:false} for "${subnet}"`, () => {
      const res = validateSubnet(subnet);
      expect(res.valid).toBe(false);
    });
  });
});
