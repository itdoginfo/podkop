import { describe, expect, it } from 'vitest';
import { maskIP } from '../maskIP';

export const validIPs = [
  ['Standard private IP', '192.168.0.1', 'XX.XX.XX.1'],
  ['Public IP', '8.8.8.8', 'XX.XX.XX.8'],
  ['Mixed digits', '10.0.255.99', 'XX.XX.XX.99'],
  ['Edge values', '255.255.255.255', 'XX.XX.XX.255'],
  ['Zeros', '0.0.0.0', 'XX.XX.XX.0'],
];

export const invalidIPs = [
  ['Empty string', '', ''],
  ['Missing octets', '192.168.1', '192.168.1'],
  ['Extra octets', '1.2.3.4.5', '1.2.3.4.5'],
  ['Letters inside', 'abc.def.ghi.jkl', 'abc.def.ghi.jkl'],
  ['Spaces inside', '1. 2.3.4', '1. 2.3.4'],
  ['Just dots', '...', '...'],
  ['IP with port', '127.0.0.1:8080', '127.0.0.1:8080'],
  ['IP with text', 'ip=192.168.0.1', 'ip=192.168.0.1'],
];

describe('maskIP', () => {
  describe.each(validIPs)('Valid IPv4: %s', (_desc, ip, expected) => {
    it(`masks "${ip}" → "${expected}"`, () => {
      expect(maskIP(ip)).toBe(expected);
    });
  });

  describe.each(invalidIPs)(
    'Invalid or malformed IP: %s',
    (_desc, ip, expected) => {
      it(`returns original string for "${ip}"`, () => {
        expect(maskIP(ip)).toBe(expected);
      });
    },
  );

  it('defaults to empty string if no param passed', () => {
    expect(maskIP()).toBe('');
  });
});
