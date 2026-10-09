import { describe, expect, it } from 'vitest';
import { splitDnsForward, validateDnsForward } from '../validateDnsForward';

const valid = [
  ['zone and server', 'ru 77.88.8.8'],
  ['dotted zone', '.ru 77.88.8.8'],
  ['dnsmasq form', '/ru/77.88.8.8'],
  ['dnsmasq form with a dot', '/.ru/77.88.8.8'],
  ['domain zone', 'corp.example.com 10.0.0.53'],
  ['port', 'example.com 1.1.1.1#5353'],
  ['IPv6', 'lan 2001:db8::1'],
  ['IPv6 with a port', 'lan 2001:db8::1#53'],
  ['uppercase zone', 'RU 77.88.8.8'],
  ['extra spaces', '  ru    77.88.8.8  '],
];

const invalid = [
  ['empty', ''],
  ['zone only', 'ru'],
  ['host name instead of an address', 'ru dns.yandex.ru'],
  ['bad IPv4', 'ru 999.1.1.1'],
  ['port zero', 'ru 77.88.8.8#0'],
  ['port too big', 'ru 77.88.8.8#70000'],
  ['port not a number', 'ru 77.88.8.8#abc'],
  ['two ports', 'ru 77.88.8.8#1#2'],
  ['bad zone', 'bad_zone! 77.88.8.8'],
  ['empty label', 'a..b 77.88.8.8'],
  ['label with a leading dash', '-a.ru 77.88.8.8'],
  ['dnsmasq form without a server', '/ru/'],
  ['bracketed IPv6', 'lan [2001:db8::1]'],
];

describe('validateDnsForward', () => {
  it.each(valid)('accepts: %s', (_name, value) => {
    expect(validateDnsForward(value).valid).toBe(true);
  });

  it.each(invalid)('rejects: %s', (_name, value) => {
    expect(validateDnsForward(value).valid).toBe(false);
  });

  it('splits both forms', () => {
    expect(splitDnsForward('ru 77.88.8.8')).toEqual({
      zone: 'ru',
      server: '77.88.8.8',
    });
    expect(splitDnsForward('/.ru/77.88.8.8')).toEqual({
      zone: '.ru',
      server: '77.88.8.8',
    });
    expect(splitDnsForward('ru')).toBeNull();
  });
});
